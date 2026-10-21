import Foundation

/// A Modrinth modpack (`.mrpack`, https://support.modrinth.com/en/articles/8802351):
/// a ZIP with `modrinth.index.json` (the files to download, with hashes, and the
/// Minecraft and loader versions it needs) plus `overrides/` and `client-overrides/`
/// folders copied over the game folder (configs, resource packs, options).
public struct ModpackIndex: Codable, Sendable, Equatable {
    public struct File: Codable, Sendable, Equatable {
        public struct Env: Codable, Sendable, Equatable {
            /// "required", "optional" or "unsupported".
            public let client: String?
            public let server: String?
        }
        public let path: String
        public let hashes: [String: String]
        public let env: Env?
        public let downloads: [URL]
        public let fileSize: Int64?

        /// Files marked unsupported on the client are for servers only.
        public var isForClient: Bool { env?.client != "unsupported" }
    }

    public let formatVersion: Int
    public let game: String
    public let versionId: String
    public let name: String
    public let summary: String?
    public let files: [File]
    /// "minecraft", and one of "fabric-loader", "quilt-loader", "forge", "neoforge".
    public let dependencies: [String: String]

    public var minecraft: String? { dependencies["minecraft"] }

    /// Mods the client gets (files under mods/).
    public var clientModCount: Int { files.filter { $0.isForClient && $0.path.hasPrefix("mods/") }.count }

    /// Packs this size did not fit in an iPhone's memory: 55 mods with a shader pack
    /// already reached the 3.4 GB limit, and a 507-mod pack was tried (2026-10-18).
    public static let largeModCount = 150

    /// The loader and its version; nil for a pack without one (vanilla).
    public var loader: (loader: ModLoader, version: String)? {
        if let v = dependencies["fabric-loader"] { return (.fabric, v) }
        if let v = dependencies["quilt-loader"] { return (.quilt, v) }
        if let v = dependencies["neoforge"] { return (.neoforge, v) }
        // Usually the Forge build ("47.4.10"); some packs write "1.20.1-47.4.10".
        if let v = dependencies["forge"] {
            if let mc = minecraft, v.hasPrefix(mc + "-") { return (.forge, String(v.dropFirst(mc.count + 1))) }
            return (.forge, v)
        }
        return nil
    }

    public static func decode(_ data: Data) throws -> ModpackIndex {
        do { return try JSONDecoder().decode(ModpackIndex.self, from: data) } catch {
            throw ModpackError.badIndex("\(error)")
        }
    }
}

public enum ModpackError: Error, Equatable, CustomStringConvertible {
    case notAModpack
    case badIndex(String)
    case unsupportedFormat(Int)
    case notMinecraft(String)
    case noMinecraftVersion
    case unsafePath(String)
    case untrustedDownload(String)
    case noDownload(String)
    case alreadyInstalled(String)

    public var description: String {
        switch self {
        case .notAModpack: "This file is not a Modrinth modpack (no modrinth.index.json)."
        case .badIndex(let why): "The modpack's index could not be read: \(why)"
        case .unsupportedFormat(let v): "Modpack format \(v) is not supported (only format 1)."
        case .notMinecraft(let game): "This modpack is for \(game), not Minecraft."
        case .noMinecraftVersion: "The modpack does not say which Minecraft version it needs."
        case .unsafePath(let p): "The modpack tries to write outside its folder (\(p)), so it was not installed."
        case .untrustedDownload(let host): "The modpack downloads from \(host), which Modrinth does not allow, so it was not installed."
        case .noDownload(let p): "The modpack lists \(p) without a download address."
        case .alreadyInstalled(let id): "\(id) is already installed."
        }
    }
}

/// What a modpack install left behind, kept in the instance (for updates later).
public struct InstalledModpack: Codable, Sendable, Equatable {
    public let name: String
    public let versionNumber: String
    public let minecraft: String
    public let loader: String?
    /// Modrinth ids when it came from Modrinth (nil for a file from Files).
    public let projectID: String?
    public let versionID: String?

    public static let fileName = ".voxelium-modpack.json"
}

/// Installs `.mrpack` files as their own versions: a small version JSON that builds on
/// the pack's Fabric/Quilt profile (or Minecraft itself), so the pack gets its own game
/// folder like any modded version, with the pack's files and overrides in it.
public struct ModpackInstaller: Sendable {
    public let game: GameInstaller
    public var meta = ModLoaderMeta()

    public init(game: GameInstaller) { self.game = game }

    /// Hosts the modpack format allows files to be downloaded from.
    public static let allowedHosts = ["cdn.modrinth.com", "github.com", "raw.githubusercontent.com", "gitlab.com"]

    public static func read(_ mrpack: URL) throws -> (index: ModpackIndex, zip: ZipReader) {
        let zip: ZipReader
        do { zip = try ZipReader(url: mrpack) } catch { throw ModpackError.notAModpack }
        guard let data = try zip.read("modrinth.index.json", limit: 32 << 20) else { throw ModpackError.notAModpack }
        let index = try ModpackIndex.decode(data)
        guard index.formatVersion == 1 else { throw ModpackError.unsupportedFormat(index.formatVersion) }
        guard index.game == "minecraft" else { throw ModpackError.notMinecraft(index.game) }
        guard index.minecraft != nil else { throw ModpackError.noMinecraftVersion }
        return (index, zip)
    }

    /// A version id for the pack: its name and version, with only characters that are
    /// safe in a folder name and on Minecraft's command line.
    public static func versionID(for index: ModpackIndex) -> String {
        // Some packs already put the version in the name ("Genesis 3.2" + "3.2").
        let raw = index.name.hasSuffix(index.versionId) ? index.name : "\(index.name) \(index.versionId)"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " .-_+"))
        let cleaned = String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
            .trimmingCharacters(in: .whitespaces)
        return String(cleaned.prefix(80)).isEmpty ? "Modpack" : String(cleaned.prefix(80))
    }

    /// Checks every file before anything is written: paths must stay inside the
    /// instance, downloads must come from allowed hosts. Returns the download items.
    public func plannedDownloads(_ index: ModpackIndex, into instance: URL) throws -> [DownloadItem] {
        try index.files.filter(\.isForClient).map { file in
            let dest: URL
            do { dest = try game.paths.resolve(file.path, in: instance) } catch { throw ModpackError.unsafePath(file.path) }
            guard let url = file.downloads.first(where: { Self.allowedHosts.contains($0.host?.lowercased() ?? "") }) else {
                if let other = file.downloads.first { throw ModpackError.untrustedDownload(other.host ?? other.absoluteString) }
                throw ModpackError.noDownload(file.path)
            }
            return DownloadItem(url: url, destination: dest, sha1: file.hashes["sha1"]?.lowercased(), size: file.fileSize)
        }
    }

    /// The override entries to copy (overrides/ then client-overrides/, which wins),
    /// as (entry name, destination), checked like the downloads.
    public func plannedOverrides(_ zip: ZipReader, into instance: URL) throws -> [(entry: String, destination: URL)] {
        var out: [(String, URL)] = []
        for prefix in ["overrides/", "client-overrides/"] {
            for e in zip.entries where e.name.hasPrefix(prefix) && !e.name.hasSuffix("/") {
                let relative = String(e.name.dropFirst(prefix.count))
                do { out.append((e.name, try game.paths.resolve(relative, in: instance))) } catch {
                    throw ModpackError.unsafePath(e.name)
                }
            }
        }
        return out
    }

    public enum Stage: Sendable, Equatable { case minecraft, loader, modpackFiles, overrides }

    /// Installs the pack as version `id` (default: name + version). Minecraft and the
    /// loader are installed first when missing. Returns the version id and the
    /// download report of the pack's own files; nothing is marked installed unless
    /// every file downloaded and verified.
    public func install(
        _ mrpack: URL, as id: String? = nil, source: (projectID: String, versionID: String)? = nil,
        progress: (@Sendable (Stage, DownloadProgress) -> Void)? = nil
    ) async throws -> (id: String, report: DownloadReport) {
        let (index, zip) = try Self.read(mrpack)
        let versionID = id ?? Self.versionID(for: index)
        guard !game.isInstalled(versionID) else { throw ModpackError.alreadyInstalled(versionID) }
        let minecraft = index.minecraft!
        let instance = try game.paths.instanceDir(versionID)

        // Check everything before downloading or writing anything.
        let downloads = try plannedDownloads(index, into: instance)
        let overrides = try plannedOverrides(zip, into: instance)

        // 1. Minecraft and the loader.
        let parentID: String
        if let loader = index.loader {
            let (loaderID, report) = try await game.installLoader(loader.loader, minecraft: minecraft, version: loader.version,
                                                                 meta: meta, progress: { _, p in progress?(.loader, p) })
            if !report.succeeded { return (versionID, report) }
            parentID = loaderID
        } else {
            if !game.isInstalled(minecraft) {
                let manifest = try await game.fetchManifest()
                guard let entry = manifest.entry(id: minecraft) else { throw ModLoaderError.badProfile("unknown Minecraft version \(minecraft)") }
                let report = try await game.install(try await game.fetchVersion(entry), progress: { _, p in progress?(.minecraft, p) })
                if !report.succeeded { return (versionID, report) }
            }
            parentID = minecraft
        }

        // 2. The pack's version JSON, building on the loader profile.
        let parent = try VersionResolver(paths: game.paths).resolve(parentID).info
        try FileManager.default.createDirectory(at: instance, withIntermediateDirectories: true)
        let json: [String: Any] = [
            "id": versionID, "inheritsFrom": parentID, "type": "release", "mainClass": parent.mainClass,
            "libraries": [Any](), "releaseTime": ISO8601DateFormatter().string(from: Date()),
        ]
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            .write(to: try game.paths.versionJSON(versionID))

        // 3. The pack's files (mods, resource packs, shaders), verified.
        let report = try await game.downloader.run(downloads, concurrency: 6) { progress?(.modpackFiles, $0) }
        guard report.succeeded else { return (versionID, report) }

        // 4. Overrides (configs, options, bundled packs).
        for (n, item) in overrides.enumerated() {
            guard let data = try zip.read(item.entry, limit: 512 << 20) else { continue }
            try FileManager.default.createDirectory(at: item.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: item.destination, options: .atomic)
            progress?(.overrides, DownloadProgress(completed: n + 1, total: overrides.count, failed: 0))
        }

        // 5. Remember where it came from, then mark the version installed.
        let record = InstalledModpack(name: index.name, versionNumber: index.versionId, minecraft: minecraft,
                                      loader: index.loader?.loader.displayName, projectID: source?.projectID,
                                      versionID: source?.versionID)
        try JSONEncoder().encode(record).write(to: instance.appendingPathComponent(InstalledModpack.fileName))
        let final = try await game.install(try VersionResolver(paths: game.paths).resolve(versionID).info)
        return (versionID, final)
    }

    /// The modpack an instance was installed from, if any.
    public static func installedModpack(in instance: URL) -> InstalledModpack? {
        guard let data = try? Data(contentsOf: instance.appendingPathComponent(InstalledModpack.fileName)) else { return nil }
        return try? JSONDecoder().decode(InstalledModpack.self, from: data)
    }
}

extension ModrinthAPI {
    /// Modrinth modpacks for a loader Voxelium can run (Fabric, Quilt, Forge, NeoForge), optionally
    /// for one Minecraft version.
    public func searchModpacks(_ query: String, gameVersion: String? = nil, sort: Sort = .relevance,
                               offset: Int = 0, limit: Int = 20) async throws -> SearchPage {
        var facets: [[String]] = [["project_type:modpack"], ["categories:fabric", "categories:quilt", "categories:forge", "categories:neoforge"]]
        if let gameVersion { facets.append(["versions:\(gameVersion)"]) }
        var c = URLComponents(string: "\(Self.base)/search")!
        c.queryItems = [
            .init(name: "query", value: query),
            .init(name: "facets", value: String(data: try JSONSerialization.data(withJSONObject: facets), encoding: .utf8)),
            .init(name: "index", value: sort.rawValue),
            .init(name: "offset", value: String(offset)),
            .init(name: "limit", value: String(limit)),
        ]
        return try await getDecoded(c.url!, "Modrinth search")
    }

    /// A modpack's versions for a loader Voxelium can run, newest first.
    public func modpackVersions(project: String) async throws -> [Version] {
        var c = URLComponents(string: "\(Self.base)/project/\(project)/version")!
        c.queryItems = [.init(name: "loaders", value: try Self.jsonArray(["fabric", "quilt", "forge", "neoforge"]))]
        return try await getDecoded(c.url!, "Modrinth versions")
    }
}
