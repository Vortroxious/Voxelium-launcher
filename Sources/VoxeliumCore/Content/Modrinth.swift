import Foundation

/// Modrinth API v2 (https://docs.modrinth.com/api/), the open platform ZalithLauncher2
/// also browses. No key is needed; requests carry a Voxelium User-Agent.
public struct ModrinthAPI: Sendable {
    let http: HTTPClient
    public static let base = "https://api.modrinth.com/v2"

    public init(http: HTTPClient = URLSessionHTTPClient()) { self.http = http }

    // MARK: Models

    public struct SearchHit: Codable, Sendable, Equatable, Identifiable {
        public let projectId: String
        public let slug: String
        public let title: String
        public let description: String
        public let author: String?
        public let downloads: Int
        public let iconUrl: String?
        public let projectType: String
        public let categories: [String]?
        public var id: String { projectId }

        public init(projectId: String, slug: String, title: String, description: String, author: String? = nil,
                    downloads: Int = 0, iconUrl: String? = nil, projectType: String, categories: [String]? = nil) {
            self.projectId = projectId
            self.slug = slug
            self.title = title
            self.description = description
            self.author = author
            self.downloads = downloads
            self.iconUrl = iconUrl
            self.projectType = projectType
            self.categories = categories
        }
    }

    public struct SearchPage: Codable, Sendable, Equatable {
        public let hits: [SearchHit]
        public let offset: Int
        public let limit: Int
        public let totalHits: Int
    }

    public struct Project: Codable, Sendable, Equatable {
        public let id: String
        public let slug: String
        public let title: String
        public let projectType: String
        public let iconUrl: String?
    }

    public struct Version: Codable, Sendable, Equatable, Identifiable {
        public struct File: Codable, Sendable, Equatable {
            public struct Hashes: Codable, Sendable, Equatable {
                public let sha1: String?
            }
            public let url: URL
            public let filename: String
            public let primary: Bool
            public let size: Int64
            public let hashes: Hashes
        }
        public struct Dependency: Codable, Sendable, Equatable {
            public let projectId: String?
            public let versionId: String?
            /// "required", "optional", "incompatible", "embedded".
            public let dependencyType: String
        }
        public let id: String
        public let projectId: String
        public let name: String
        public let versionNumber: String
        /// "release", "beta", "alpha".
        public let versionType: String
        public let files: [File]
        public let dependencies: [Dependency]
        public let loaders: [String]
        public let gameVersions: [String]

        /// The file to install: the primary one, else the first.
        public var primaryFile: File? { files.first(where: \.primary) ?? files.first }
    }

    public enum Sort: String, Sendable, CaseIterable {
        case relevance, downloads, follows, newest, updated
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    // MARK: Filters

    /// Modrinth's project type for a kind of content.
    public static func projectType(_ kind: ContentKind) -> String {
        switch kind {
        case .mods: "mod"
        case .resourcePacks: "resourcepack"
        case .shaderPacks: "shader"
        }
    }

    /// The loaders a version of this kind must support on a game version's loader:
    /// mods match the loader (Quilt also runs Fabric mods); resource packs are
    /// "minecraft"; shader packs need Iris on Fabric/Quilt.
    public static func loaders(for kind: ContentKind, gameLoader: String?) -> [String] {
        switch kind {
        case .mods: gameLoader == "quilt" ? ["quilt", "fabric"] : gameLoader.map { [$0] } ?? []
        case .resourcePacks: ["minecraft"]
        case .shaderPacks: ["iris"]
        }
    }

    // MARK: Requests

    public func search(_ query: String, kind: ContentKind, gameVersion: String, gameLoader: String?,
                       sort: Sort = .relevance, offset: Int = 0, limit: Int = 20) async throws -> SearchPage {
        var facets: [[String]] = [["project_type:\(Self.projectType(kind))"], ["versions:\(gameVersion)"]]
        let loaders = Self.loaders(for: kind, gameLoader: gameLoader).filter { $0 != "minecraft" }
        if !loaders.isEmpty { facets.append(loaders.map { "categories:\($0)" }) }
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

    /// A project's versions for these loaders and game version, newest first.
    public func versions(project: String, loaders: [String], gameVersion: String) async throws -> [Version] {
        var c = URLComponents(string: "\(Self.base)/project/\(project)/version")!
        var items = [URLQueryItem(name: "game_versions", value: try Self.jsonArray([gameVersion]))]
        if !loaders.isEmpty { items.append(.init(name: "loaders", value: try Self.jsonArray(loaders))) }
        c.queryItems = items
        return try await getDecoded(c.url!, "Modrinth versions")
    }

    public func version(id: String) async throws -> Version {
        try await getDecoded(URL(string: "\(Self.base)/version/\(id)")!, "Modrinth version")
    }

    public func project(id: String) async throws -> Project {
        try await getDecoded(URL(string: "\(Self.base)/project/\(id)")!, "Modrinth project")
    }

    /// Which Modrinth versions these files (by SHA-1) are; unknown hashes are absent.
    public func versions(forSHA1 hashes: [String]) async throws -> [String: Version] {
        guard !hashes.isEmpty else { return [:] }
        let r = try await http.json(URL(string: "\(Self.base)/version_files")!, body: ["hashes": hashes, "algorithm": "sha1"])
        guard r.status == 200 else { throw ModrinthError.http("Modrinth file lookup", r.status) }
        return try Self.decoder().decode([String: Version].self, from: r.data)
    }

    /// The newest version of each file's project for these loaders and game version
    /// (POST /version_files/update), by SHA-1. Unknown hashes are absent. Modrinth
    /// answers with the newest of any type, betas included.
    public func latestVersions(forSHA1 hashes: [String], loaders: [String], gameVersion: String) async throws -> [String: Version] {
        guard !hashes.isEmpty else { return [:] }
        var body: [String: Any] = ["hashes": hashes, "algorithm": "sha1", "game_versions": [gameVersion]]
        if !loaders.isEmpty { body["loaders"] = loaders }
        let r = try await http.json(URL(string: "\(Self.base)/version_files/update")!, body: body)
        guard r.status == 200 else { throw ModrinthError.http("Modrinth update check", r.status) }
        do { return try Self.decoder().decode([String: Version].self, from: r.data) } catch {
            throw ModrinthError.badResponse("Modrinth update check")
        }
    }

    func getDecoded<T: Decodable>(_ url: URL, _ what: String) async throws -> T {
        let r = try await http.get(url)
        guard r.status == 200 else { throw ModrinthError.http(what, r.status) }
        do { return try Self.decoder().decode(T.self, from: r.data) } catch { throw ModrinthError.badResponse(what) }
    }

    static func jsonArray(_ a: [String]) throws -> String {
        String(data: try JSONSerialization.data(withJSONObject: a), encoding: .utf8)!
    }

    /// The version to install: the newest release, else the newest of any type.
    public static func preferred(_ versions: [Version]) -> Version? {
        versions.first { $0.versionType == "release" } ?? versions.first
    }
}

public enum ModrinthError: Error, Equatable, CustomStringConvertible {
    case http(String, Int)
    case badResponse(String)
    case noCompatibleVersion(String)

    public var description: String {
        switch self {
        case .http(let what, let s): "\(what) failed (HTTP \(s))."
        case .badResponse(let what): "Unexpected response from \(what)."
        case .noCompatibleVersion(let name): "\(name) has no version for this Minecraft version and loader."
        }
    }
}

/// What installing one Modrinth version brings in: the file itself plus its
/// required dependencies, minus what the game folder already has.
public struct ModrinthInstallPlan: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public let projectID: String
        public let title: String
        public let version: ModrinthAPI.Version
        public let isDependency: Bool
    }
    public var items: [Item] = []
    /// Required dependencies that are already installed (project ids).
    public var alreadyInstalled: [String] = []
    /// Required dependencies with no compatible version (titles).
    public var unavailable: [String] = []
    /// Installed projects the new version declares incompatible (titles).
    public var conflicts: [String] = []
}

/// Plans and installs Modrinth content into a game folder.
public struct ModrinthInstaller: Sendable {
    public let api: ModrinthAPI
    public let downloader: DownloadManager

    public init(api: ModrinthAPI = ModrinthAPI(), downloader: DownloadManager = DownloadManager()) {
        self.api = api
        self.downloader = downloader
    }

    /// Modrinth project ids of the files installed for `kind` (by SHA-1 lookup),
    /// mapped to the files on disk.
    public func installedProjects(_ manager: ContentManager, kind: ContentKind) async throws -> [String: [URL]] {
        let items = manager.list(kind).filter { !$0.isFolder }
        var byHash: [String: URL] = [:]
        for item in items { if let h = try? FileHash.sha1(of: item.url) { byHash[h] = item.url } }
        let found = try await api.versions(forSHA1: Array(byHash.keys))
        var out: [String: [URL]] = [:]
        for (hash, version) in found { if let url = byHash[hash] { out[version.projectId, default: []].append(url) } }
        return out
    }

    /// The chosen version plus every required dependency (recursively), using the
    /// exact dependency version when the author pinned one, else the preferred
    /// compatible version. Dependencies already installed are skipped.
    public func plan(_ version: ModrinthAPI.Version, title: String, kind: ContentKind, gameVersion: String,
                     gameLoader: String?, installed: Set<String>) async throws -> ModrinthInstallPlan {
        var plan = ModrinthInstallPlan()
        var seen: Set<String> = [version.projectId]
        var queue: [(ModrinthAPI.Version, String, Bool)] = [(version, title, false)]
        let depLoaders = ModrinthAPI.loaders(for: .mods, gameLoader: gameLoader)
        while !queue.isEmpty {
            let (v, t, isDep) = queue.removeFirst()
            plan.items.append(.init(projectID: v.projectId, title: t, version: v, isDependency: isDep))
            for dep in v.dependencies {
                guard dep.dependencyType == "required" || dep.dependencyType == "incompatible" else { continue }
                // A pinned dependency may give only a version id.
                var pinned: ModrinthAPI.Version?
                if let vid = dep.versionId { pinned = try? await api.version(id: vid) }
                guard let pid = dep.projectId ?? pinned?.projectId else { continue }
                if dep.dependencyType == "incompatible" {
                    if installed.contains(pid) { plan.conflicts.append(await projectTitle(pid)) }
                    continue
                }
                guard !seen.contains(pid) else { continue }
                seen.insert(pid)
                if installed.contains(pid) { plan.alreadyInstalled.append(pid); continue }
                let depTitle = await projectTitle(pid)
                // Shader packs and resource packs can depend on mods (e.g. Iris); those resolve as mods.
                var chosen = pinned
                if chosen == nil {
                    let list = (try? await api.versions(project: pid, loaders: depLoaders, gameVersion: gameVersion)) ?? []
                    chosen = ModrinthAPI.preferred(list)
                }
                guard let chosen else { plan.unavailable.append(depTitle); continue }
                queue.append((chosen, depTitle, true))
            }
        }
        return plan
    }

    /// Installed files of `kind` that have a newer Modrinth version for this game
    /// version and loader. Files are matched by SHA-1, so only files that came from
    /// Modrinth (any launcher) are checked; switched-off files are skipped. An installed
    /// release is only offered a newer release, never a beta.
    public func checkUpdates(_ manager: ContentManager, kind: ContentKind, gameVersion: String,
                             gameLoader: String?) async throws -> [ModUpdate] {
        let items = manager.list(kind).filter { !$0.isFolder && $0.isEnabled }
        var byHash: [String: ContentItem] = [:]
        for item in items { if let h = try? FileHash.sha1(of: item.url) { byHash[h] = item } }
        guard !byHash.isEmpty else { return [] }
        let hashes = Array(byHash.keys)
        let loaders = ModrinthAPI.loaders(for: kind, gameLoader: gameLoader)
        let current = try await api.versions(forSHA1: hashes)
        let latest = try await api.latestVersions(forSHA1: hashes, loaders: loaders, gameVersion: gameVersion)
        var updates: [ModUpdate] = []
        for (hash, item) in byHash {
            guard let now = current[hash], var newest = latest[hash], newest.id != now.id else { continue }
            if now.versionType == "release" && newest.versionType != "release" {
                let list = (try? await api.versions(project: now.projectId, loaders: loaders, gameVersion: gameVersion)) ?? []
                guard let release = list.first(where: { $0.versionType == "release" }), release.id != now.id,
                      let releaseIndex = list.firstIndex(where: { $0.id == release.id }),
                      list.firstIndex(where: { $0.id == now.id }).map({ releaseIndex < $0 }) ?? true
                else { continue }
                newest = release
            }
            updates.append(ModUpdate(projectID: now.projectId, name: item.name, file: item.url, current: now, latest: newest))
        }
        return updates.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func projectTitle(_ projectID: String) async -> String {
        (try? await api.project(id: projectID))?.title ?? projectID
    }

    /// Downloads every planned file into the folder of its kind (the chosen item
    /// into `kind`, dependencies, which are mods, into mods/), verifying SHA-1s.
    /// A project that is already installed in another version is replaced.
    public func install(_ plan: ModrinthInstallPlan, kind: ContentKind, into manager: ContentManager,
                        replacing installed: [String: [URL]] = [:],
                        progress: (@Sendable (DownloadProgress) -> Void)? = nil) async throws -> DownloadReport {
        var items: [DownloadItem] = []
        var replaced: [URL] = []
        for entry in plan.items {
            guard let file = entry.version.primaryFile else { continue }
            let folder = manager.folder(entry.isDependency ? .mods : kind)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = file.filename.replacingOccurrences(of: "/", with: "_")
            let dest = folder.appendingPathComponent(name)
            items.append(DownloadItem(url: file.url, destination: dest, sha1: file.hashes.sha1, size: file.size))
            replaced += (installed[entry.projectID] ?? []).filter { $0.standardizedFileURL != dest.standardizedFileURL }
        }
        let report = try await downloader.run(items, concurrency: 4, progress: progress)
        if report.succeeded { for old in replaced { try? FileManager.default.removeItem(at: old) } }
        return report
    }
}

/// A newer Modrinth version of an installed file.
public struct ModUpdate: Sendable, Equatable, Identifiable {
    public let projectID: String
    /// The installed item's name (from its metadata).
    public let name: String
    /// The installed file, removed once the update is in place.
    public let file: URL
    public let current: ModrinthAPI.Version
    public let latest: ModrinthAPI.Version
    public var id: String { projectID }
}
