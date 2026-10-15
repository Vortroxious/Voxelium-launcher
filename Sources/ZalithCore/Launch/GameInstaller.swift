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

    /// Downloads everything. `dryRun` returns the planned items without downloading.
    @discardableResult
    public func install(
        _ version: VersionInfo,
        concurrency: Int = 8,
        progress: (@Sendable (Stage, DownloadProgress) -> Void)? = nil
    ) async throws -> DownloadReport {
        let base = try planner.installItems(for: version)
        var report = try await downloader.run(base, concurrency: concurrency) { progress?(.gameFiles, $0) }
        guard report.succeeded, let idx = version.assetIndex else { return report }

        let index = try AssetIndex.decode(Data(contentsOf: try paths.assetIndex(idx.id)))
        let assets = try await downloader.run(try planner.assetItems(for: index, base: assetBase), concurrency: concurrency) { progress?(.assets, $0) }
        report.outcomes.merge(assets.outcomes) { $1 }
        report.failures.merge(assets.failures) { $1 }
        return report
    }
}
