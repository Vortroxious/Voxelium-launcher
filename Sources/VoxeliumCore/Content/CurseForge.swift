import Foundation

/// CurseForge's API for third parties (https://docs.curseforge.com/rest-api/), with the
/// player's own API key from console.curseforge.com. The key goes in the `x-api-key`
/// header and nowhere else.
///
/// Authors can turn off downloads in other apps: those files come without a
/// `downloadUrl`, and Voxelium then only links to the file's CurseForge page.
public struct CurseForgeAPI: Sendable {
    let http: HTTPClient
    let key: String
    public static let base = "https://api.curseforge.com/v1"
    /// CurseForge's game id for Minecraft.
    public static let minecraft = 432

    public init(key: String, http: HTTPClient = URLSessionHTTPClient()) {
        self.key = key
        self.http = http
    }

    // MARK: Models

    public struct Links: Codable, Sendable, Equatable {
        public let websiteUrl: String?
    }
    public struct Author: Codable, Sendable, Equatable {
        public let name: String
    }
    public struct Logo: Codable, Sendable, Equatable {
        public let thumbnailUrl: String?
    }

    public struct Mod: Codable, Sendable, Equatable, Identifiable {
        public let id: Int
        public let name: String
        public let slug: String
        public let summary: String
        public let downloadCount: Double
        public let links: Links?
        public let authors: [Author]?
        public let logo: Logo?
        public let classId: Int?
        /// False when the author doesn't allow downloads outside CurseForge.
        public let allowModDistribution: Bool?

        public init(id: Int, name: String, slug: String, summary: String, downloadCount: Double = 0, links: Links? = nil,
                    authors: [Author]? = nil, logo: Logo? = nil, classId: Int? = nil, allowModDistribution: Bool? = nil) {
            self.id = id
            self.name = name
            self.slug = slug
            self.summary = summary
            self.downloadCount = downloadCount
            self.links = links
            self.authors = authors
            self.logo = logo
            self.classId = classId
            self.allowModDistribution = allowModDistribution
        }

        public var websiteURL: URL? { links?.websiteUrl.flatMap(URL.init(string:)) }
    }

    public struct File: Codable, Sendable, Equatable, Identifiable {
        public struct Hash: Codable, Sendable, Equatable {
            public let value: String
            /// 1 SHA-1, 2 MD5.
            public let algo: Int
        }
        public struct Dependency: Codable, Sendable, Equatable {
            public let modId: Int
            /// 3 required, 5 incompatible (1 embedded, 2 optional, 4 tool, 6 include).
            public let relationType: Int
        }
        public let id: Int
        public let modId: Int
        public let displayName: String
        public let fileName: String
        /// 1 release, 2 beta, 3 alpha.
        public let releaseType: Int
        public let fileLength: Int64
        /// nil when the author doesn't allow downloads outside CurseForge.
        public let downloadUrl: String?
        public let hashes: [Hash]
        public let gameVersions: [String]
        public let dependencies: [Dependency]

        public var sha1: String? { hashes.first { $0.algo == 1 }?.value }
        public var downloadURL: URL? { downloadUrl.flatMap(URL.init(string:)) }
        public var releaseName: String { [1: "release", 2: "beta", 3: "alpha"][releaseType] ?? "release" }
    }

    struct Page<T: Decodable>: Decodable {
        struct Pagination: Decodable {
            let index: Int
            let resultCount: Int
            let totalCount: Int
        }
        let data: [T]
        let pagination: Pagination?
    }
    struct One<T: Decodable>: Decodable { let data: T }

    public struct SearchPage: Sendable, Equatable {
        public let mods: [Mod]
        public let index: Int
        public let totalCount: Int
    }

    /// CurseForge's sort fields (ModsSearchSortField).
    public enum Sort: Int, Sendable, CaseIterable {
        case popularity = 2, updated = 3, name = 4, downloads = 6

        public var title: String {
            switch self {
            case .popularity: "Popular"
            case .updated: "Updated"
            case .name: "Name"
            case .downloads: "Downloads"
            }
        }
    }

    // MARK: Filters

    /// CurseForge's class (category group) for a kind of content.
    public static func classID(_ kind: ContentKind) -> Int {
        switch kind {
        case .mods: 6
        case .resourcePacks: 12
        case .shaderPacks: 6552
        }
    }

    /// CurseForge's loader types for mods on a game loader, in order of preference:
    /// Quilt also runs Fabric mods. Resource and shader packs have no loader.
    public static func loaderTypes(for kind: ContentKind, gameLoader: String?) -> [Int] {
        guard kind == .mods, let gameLoader else { return [] }
        switch gameLoader {
        case "forge": return [1]
        case "fabric": return [4]
        case "quilt": return [5, 4]
        case "neoforge": return [6]
        default: return []
        }
    }

    // MARK: Requests

    /// One page of mods for this game version and loader. For Quilt, Fabric mods are
    /// searched (most Quilt players run them).
    public func search(_ query: String, kind: ContentKind, gameVersion: String, gameLoader: String?,
                       sort: Sort = .popularity, index: Int = 0, pageSize: Int = 20) async throws -> SearchPage {
        var items = [URLQueryItem(name: "gameId", value: "\(Self.minecraft)"),
                     URLQueryItem(name: "classId", value: "\(Self.classID(kind))"),
                     URLQueryItem(name: "gameVersion", value: gameVersion),
                     URLQueryItem(name: "sortField", value: "\(sort.rawValue)"),
                     URLQueryItem(name: "sortOrder", value: sort == .name ? "asc" : "desc"),
                     URLQueryItem(name: "index", value: "\(index)"),
                     URLQueryItem(name: "pageSize", value: "\(pageSize)")]
        if !query.isEmpty { items.append(URLQueryItem(name: "searchFilter", value: query)) }
        if let loader = Self.loaderTypes(for: kind, gameLoader: gameLoader).last {
            items.append(URLQueryItem(name: "modLoaderType", value: "\(loader)"))
        }
        let page: Page<Mod>
        do {
            page = try await get("/mods/search", items, "CurseForge search")
        } catch CurseForgeError.invalidKey {
            // Some keys work everywhere except search (seen 2026-11-01: 403 "API Key missing
            // or invalid" on /mods/search only). Tell that apart from a key that's simply wrong.
            if (try? await checkKey()) != nil { throw CurseForgeError.searchNotAllowed }
            throw CurseForgeError.invalidKey
        }
        return SearchPage(mods: page.data, index: page.pagination?.index ?? index, totalCount: page.pagination?.totalCount ?? page.data.count)
    }

    /// A mod's files for this game version and loader, newest first. With several loader
    /// types (Quilt), files for the first come first.
    public func files(modID: Int, kind: ContentKind, gameVersion: String, gameLoader: String?) async throws -> [File] {
        let loaders = Self.loaderTypes(for: kind, gameLoader: gameLoader)
        var out: [File] = []
        for loader in loaders.isEmpty ? [nil] : loaders.map(Optional.some) {
            var items = [URLQueryItem(name: "gameVersion", value: gameVersion), URLQueryItem(name: "pageSize", value: "50")]
            if let loader { items.append(URLQueryItem(name: "modLoaderType", value: "\(loader)")) }
            let page: Page<File> = try await get("/mods/\(modID)/files", items, "CurseForge files")
            out += page.data.filter { f in !out.contains { $0.id == f.id } }.sorted { $0.id > $1.id }
        }
        return out
    }

    public func mod(id: Int) async throws -> Mod {
        let one: One<Mod> = try await get("/mods/\(id)", [], "CurseForge mod")
        return one.data
    }

    /// Checks the key with one cheap request (the Minecraft game entry).
    public func checkKey() async throws {
        struct Game: Decodable { let id: Int }
        let _: One<Game> = try await get("/games/\(Self.minecraft)", [], "CurseForge")
    }

    func get<T: Decodable>(_ path: String, _ items: [URLQueryItem], _ what: String) async throws -> T {
        var c = URLComponents(string: Self.base + path)!
        if !items.isEmpty { c.queryItems = items }
        var r = URLRequest(url: c.url!)
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue(HTTPHeaders.userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue(key, forHTTPHeaderField: "x-api-key")
        let response = try await http.send(r)
        switch response.status {
        case 200: break
        case 401, 403: throw CurseForgeError.invalidKey
        default: throw CurseForgeError.http(what, response.status)
        }
        do { return try JSONDecoder().decode(T.self, from: response.data) } catch { throw CurseForgeError.badResponse(what) }
    }

    /// The file to install: the newest release, else the newest of any type.
    public static func preferred(_ files: [File]) -> File? {
        files.first { $0.releaseType == 1 } ?? files.first
    }
}

public enum CurseForgeError: Error, Equatable, CustomStringConvertible {
    case invalidKey
    /// The key works, but CurseForge doesn't let it search.
    case searchNotAllowed
    case http(String, Int)
    case badResponse(String)

    public var description: String {
        switch self {
        case .invalidKey: "CurseForge didn't accept the API key. Check it on console.curseforge.com and enter it again."
        case .searchNotAllowed: "CurseForge accepts the API key but doesn't let it search. On console.curseforge.com, ask CurseForge for search access or create a new key."
        case .http(let what, let s): "\(what) failed (HTTP \(s))."
        case .badResponse(let what): "Unexpected response from \(what)."
        }
    }
}

/// What installing one CurseForge file brings in: the file plus its required
/// dependencies, minus what the game folder already has from CurseForge.
public struct CurseForgeInstallPlan: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public let mod: CurseForgeAPI.Mod
        public let file: CurseForgeAPI.File
        public let isDependency: Bool
    }
    public var items: [Item] = []
    /// Required dependencies already installed from CurseForge (mod ids).
    public var alreadyInstalled: [Int] = []
    /// Required dependencies with no file for this game version and loader (names).
    public var unavailable: [String] = []
    /// Installed mods the new file declares incompatible (names).
    public var conflicts: [String] = []

    /// Items whose author doesn't allow downloads in other apps: shown with a link, never fetched.
    public var blocked: [Item] { items.filter { $0.file.downloadURL == nil } }
    public var downloadable: [Item] { items.filter { $0.file.downloadURL != nil } }
}

/// Which files in a game folder came from CurseForge (mod and file ids), kept in
/// `.voxelium-curseforge.json`. CurseForge files can't be matched by SHA-1 lookup the
/// way Modrinth's can, so Voxelium remembers what it installed.
public struct CurseForgeIndex: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public let modID: Int
        public let fileID: Int
        public let kind: String
    }
    /// By file name, without ".disabled".
    public var files: [String: Entry] = [:]

    public init() {}

    static func url(_ manager: ContentManager) -> URL {
        manager.gameDirectory.appendingPathComponent(".voxelium-curseforge.json")
    }

    public static func load(_ manager: ContentManager) -> CurseForgeIndex {
        (try? Data(contentsOf: url(manager))).flatMap { try? JSONDecoder().decode(CurseForgeIndex.self, from: $0) } ?? CurseForgeIndex()
    }

    public func save(_ manager: ContentManager) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: Self.url(manager), options: .atomic)
    }

    /// Mod ids still on disk (switched on or off), mapped to their files.
    public func installed(_ manager: ContentManager) -> [Int: [URL]] {
        var out: [Int: [URL]] = [:]
        for kind in ContentKind.allCases {
            for item in manager.list(kind) {
                guard let entry = files[item.id], entry.kind == kind.rawValue else { continue }
                out[entry.modID, default: []].append(item.url)
            }
        }
        return out
    }
}

/// Plans and installs CurseForge content into a game folder.
public struct CurseForgeInstaller: Sendable {
    public let api: CurseForgeAPI
    public let downloader: DownloadManager

    public init(api: CurseForgeAPI, downloader: DownloadManager = DownloadManager()) {
        self.api = api
        self.downloader = downloader
    }

    /// The chosen file plus every required dependency (recursively), each the preferred
    /// file for this game version and loader. Dependencies are mods.
    public func plan(_ file: CurseForgeAPI.File, of mod: CurseForgeAPI.Mod, gameVersion: String,
                     gameLoader: String?, installed: Set<Int>) async throws -> CurseForgeInstallPlan {
        var plan = CurseForgeInstallPlan()
        var seen: Set<Int> = [mod.id]
        var queue: [(CurseForgeAPI.Mod, CurseForgeAPI.File, Bool)] = [(mod, file, false)]
        while !queue.isEmpty {
            let (m, f, isDep) = queue.removeFirst()
            plan.items.append(.init(mod: m, file: f, isDependency: isDep))
            for dep in f.dependencies where dep.relationType == 3 || dep.relationType == 5 {
                if dep.relationType == 5 {
                    if installed.contains(dep.modId) { plan.conflicts.append((try? await api.mod(id: dep.modId))?.name ?? "mod \(dep.modId)") }
                    continue
                }
                guard !seen.contains(dep.modId) else { continue }
                seen.insert(dep.modId)
                if installed.contains(dep.modId) { plan.alreadyInstalled.append(dep.modId); continue }
                guard let depMod = try? await api.mod(id: dep.modId) else { plan.unavailable.append("mod \(dep.modId)"); continue }
                let list = (try? await api.files(modID: dep.modId, kind: .mods, gameVersion: gameVersion, gameLoader: gameLoader)) ?? []
                guard let chosen = CurseForgeAPI.preferred(list) else { plan.unavailable.append(depMod.name); continue }
                queue.append((depMod, chosen, true))
            }
        }
        return plan
    }

    /// Downloads every downloadable planned file into the folder of its kind (the chosen
    /// item into `kind`, dependencies into mods/), verifying SHA-1s, and records them in
    /// the index. Blocked files are skipped. An older file of the same mod is replaced.
    public func install(_ plan: CurseForgeInstallPlan, kind: ContentKind, into manager: ContentManager,
                        progress: (@Sendable (DownloadProgress) -> Void)? = nil) async throws -> DownloadReport {
        var index = CurseForgeIndex.load(manager)
        let installed = index.installed(manager)
        var items: [DownloadItem] = []
        var replaced: [URL] = []
        var added: [(String, CurseForgeIndex.Entry)] = []
        for entry in plan.downloadable {
            guard let url = entry.file.downloadURL else { continue }
            let itemKind: ContentKind = entry.isDependency ? .mods : kind
            let folder = manager.folder(itemKind)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = entry.file.fileName.replacingOccurrences(of: "/", with: "_")
            let dest = folder.appendingPathComponent(name)
            items.append(DownloadItem(url: url, destination: dest, sha1: entry.file.sha1, size: entry.file.fileLength))
            replaced += (installed[entry.mod.id] ?? []).filter { $0.standardizedFileURL != dest.standardizedFileURL }
            added.append((name, .init(modID: entry.mod.id, fileID: entry.file.id, kind: itemKind.rawValue)))
        }
        let report = try await downloader.run(items, concurrency: 4, progress: progress)
        if report.succeeded {
            for old in replaced {
                index.files[ContentManager.baseName(old.lastPathComponent)] = nil
                try? FileManager.default.removeItem(at: old)
            }
            for (name, entry) in added { index.files[name] = entry }
            try index.save(manager)
        }
        return report
    }
}
