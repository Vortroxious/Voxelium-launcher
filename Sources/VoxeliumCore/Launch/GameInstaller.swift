import Foundation

/// Installs a vanilla version: manifest → version JSON → client, libraries,
/// asset index → asset objects. Each file is hash-verified by DownloadManager.
public struct GameInstaller: Sendable {
    public let paths: AppPaths
    public let downloader: DownloadManager
    public let planner: GameFilePlanner
    public var manifestURL = VersionManifest.officialURL
    public var assetBase = AssetIndex.resourceBase

    public init(paths: AppPaths, downloader: DownloadManager = DownloadManager(), platform: RulePlatform = .iOSDefault) {
        self.paths = paths
        self.downloader = downloader
        self.planner = GameFilePlanner(paths: paths, platform: platform)
    }

    /// Always re-fetches the manifest (it has no hash of its own) and caches it.
    public func fetchManifest() async throws -> VersionManifest {
        let cache = paths.configDir.appendingPathComponent("version_manifest_v2.json")
        try? FileManager.default.removeItem(at: cache)
        _ = try await downloader.ensure(DownloadItem(url: manifestURL, destination: cache, sha1: nil, size: nil))
        return try VersionManifest.decode(Data(contentsOf: cache))
    }

    public func fetchVersion(_ entry: VersionManifest.Entry) async throws -> VersionInfo {
        let dest = try paths.versionJSON(entry.id)
        _ = try await downloader.ensure(DownloadItem(url: entry.url, destination: dest, sha1: entry.sha1, size: nil))
        return try VersionInfo.decode(Data(contentsOf: dest))
    }

    public enum Stage: Sendable, Equatable { case gameFiles, assets }

    /// Marker written only after every file of a version downloaded and
    /// verified. A version JSON alone does not mean the install finished
    /// (the app can be killed or suspended mid-download).
    public func completionMarker(_ id: String) throws -> URL {
        try paths.versionDir(id).appendingPathComponent(".voxelium-install-complete")
    }

    public func isInstalled(_ id: String) -> Bool {
        (try? completionMarker(id)).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    /// Downloads everything; files that are already valid are skipped, so
    /// re-running resumes an interrupted install.
    @discardableResult
    public func install(
        _ version: VersionInfo,
        concurrency: Int = 8,
        progress: (@Sendable (Stage, DownloadProgress) -> Void)? = nil
    ) async throws -> DownloadReport {
        let marker = try completionMarker(version.id)
        try? FileManager.default.removeItem(at: marker)
        let base = try planner.installItems(for: version)
        var report = try await downloader.run(base, concurrency: concurrency) { progress?(.gameFiles, $0) }
        guard report.succeeded, let idx = version.assetIndex else { return report }

        let index = try AssetIndex.decode(Data(contentsOf: try paths.assetIndex(idx.id)))
        let assets = try await downloader.run(try planner.assetItems(for: index, base: assetBase), concurrency: concurrency) { progress?(.assets, $0) }
        report.outcomes.merge(assets.outcomes) { $1 }
        report.failures.merge(assets.failures) { $1 }
        if report.succeeded {
            try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: marker)
        }
        return report
    }

    /// Installs a Fabric or Quilt build: the vanilla base version first (if it is
    /// not installed yet), then the loader profile, then the merged version, whose
    /// already-present files are verified and skipped. Returns the new version id;
    /// the report is the base install's if that failed, else the loader's.
    public func installLoader(
        _ loader: ModLoader, minecraft: String, version: String,
        meta: ModLoaderMeta = ModLoaderMeta(), concurrency: Int = 8,
        progress: (@Sendable (Stage, DownloadProgress) -> Void)? = nil
    ) async throws -> (id: String, report: DownloadReport) {
        if !isInstalled(minecraft) {
            let manifest = try await fetchManifest()
            guard let entry = manifest.entry(id: minecraft) else { throw ModLoaderError.badProfile("unknown Minecraft version \(minecraft)") }
            let base = try await install(try await fetchVersion(entry), concurrency: concurrency, progress: progress)
            if !base.succeeded { return (minecraft, base) }
        }
        let profile = try await ModLoaderInstaller(paths: paths, meta: meta).installProfile(loader, minecraft: minecraft, version: version)
        let resolved = try VersionResolver(paths: paths).resolve(profile.id)
        return (profile.id, try await install(resolved.info, concurrency: concurrency, progress: progress))
    }
}
