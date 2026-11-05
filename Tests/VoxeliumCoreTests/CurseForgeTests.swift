import Foundation
import Testing
@testable import VoxeliumCore

@Suite struct CurseForgeTests {
    static let api = CurseForgeAPI.base
    static let key = "test-key-not-real"

    static func mod(_ id: Int, _ name: String, allow: Bool = true) -> [String: Any] {
        ["id": id, "name": name, "slug": name.lowercased(), "summary": "\(name) summary", "downloadCount": 1234567.0,
         "links": ["websiteUrl": "https://www.curseforge.com/minecraft/mc-mods/\(name.lowercased())"],
         "authors": [["name": "Author of \(name)"]], "logo": ["thumbnailUrl": "https://media.forgecdn.net/\(id).png"],
         "classId": 6, "allowModDistribution": allow]
    }

    static func file(_ id: Int, mod: Int, name: String, release: Int = 1, url: String? = "default",
                     deps: [(Int, Int)] = []) -> [String: Any] {
        var f: [String: Any] = [
            "id": id, "modId": mod, "displayName": name, "fileName": "\(name).jar", "releaseType": release,
            "fileLength": 2048, "hashes": [["value": "da39a3ee5e6b4b0d3255bfef95601890afd80709", "algo": 1], ["value": "x", "algo": 2]],
            "gameVersions": ["1.21.11", "Fabric"], "dependencies": deps.map { ["modId": $0.0, "relationType": $0.1] }]
        if let url { f["downloadUrl"] = url == "default" ? "https://edge.forgecdn.net/files/\(id)/\(name).jar" : url }
        return f
    }

    static func page(_ data: [[String: Any]], total: Int? = nil) -> [String: Any] {
        ["data": data, "pagination": ["index": 0, "pageSize": 20, "resultCount": data.count, "totalCount": total ?? data.count]]
    }

    @Test func searchSendsTheKeyAndFilters() async throws {
        let http = MockHTTP()
        http.on("\(Self.api)/mods/search", 200, Self.page([Self.mod(1001, "Sodium")], total: 57))
        let api = CurseForgeAPI(key: Self.key, http: http)
        let page = try await api.search("sodium", kind: .mods, gameVersion: "1.21.11", gameLoader: "quilt", sort: .downloads)
        #expect(page.mods.first?.name == "Sodium" && page.totalCount == 57)
        #expect(page.mods.first?.websiteURL?.host == "www.curseforge.com")

        let request = try #require(http.requests.first)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == Self.key)
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Voxelium/") == true)
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ n: String) -> String? { items.first { $0.name == n }?.value }
        #expect(q("gameId") == "432" && q("classId") == "6" && q("gameVersion") == "1.21.11")
        #expect(q("searchFilter") == "sodium" && q("sortField") == "6" && q("sortOrder") == "desc")
        // Quilt searches Fabric mods.
        #expect(q("modLoaderType") == "4")
    }

    @Test func classesAndLoaders() {
        #expect(CurseForgeAPI.classID(.mods) == 6)
        #expect(CurseForgeAPI.classID(.resourcePacks) == 12)
        #expect(CurseForgeAPI.classID(.shaderPacks) == 6552)
        #expect(CurseForgeAPI.loaderTypes(for: .mods, gameLoader: "forge") == [1])
        #expect(CurseForgeAPI.loaderTypes(for: .mods, gameLoader: "neoforge") == [6])
        #expect(CurseForgeAPI.loaderTypes(for: .mods, gameLoader: "quilt") == [5, 4])
        #expect(CurseForgeAPI.loaderTypes(for: .resourcePacks, gameLoader: "fabric") == [])
        #expect(CurseForgeAPI.loaderTypes(for: .shaderPacks, gameLoader: "fabric") == [])
    }

    @Test func rejectedKey() async throws {
        let http = MockHTTP()
        http.on("\(Self.api)/games/432", 403, ["error": "Forbidden"])
        await #expect(throws: CurseForgeError.invalidKey) { try await CurseForgeAPI(key: "wrong", http: http).checkKey() }
    }

    /// A key CurseForge accepts everywhere but search (403 on /mods/search only).
    @Test func searchRefusedForAWorkingKey() async throws {
        let http = MockHTTP()
        http.on("\(Self.api)/mods/search", 403, ["error": "Forbidden"])
        http.on("\(Self.api)/games/432", 200, ["data": ["id": 432, "name": "Minecraft"]])
        await #expect(throws: CurseForgeError.searchNotAllowed) {
            try await CurseForgeAPI(key: Self.key, http: http).search("", kind: .mods, gameVersion: "1.21.11", gameLoader: "fabric")
        }

        let wrong = MockHTTP()
        wrong.on("\(Self.api)/mods/search", 403, ["error": "Forbidden"])
        wrong.on("\(Self.api)/games/432", 403, ["error": "Forbidden"])
        await #expect(throws: CurseForgeError.invalidKey) {
            try await CurseForgeAPI(key: "wrong", http: wrong).search("", kind: .mods, gameVersion: "1.21.11", gameLoader: "fabric")
        }
    }

    @Test func filesNewestFirstAndPreferredRelease() async throws {
        let http = MockHTTP()
        http.on("\(Self.api)/mods/1001/files", 200, Self.page([
            Self.file(500, mod: 1001, name: "sodium-0.8.1"),
            Self.file(520, mod: 1001, name: "sodium-0.8.2-beta", release: 2),
            Self.file(510, mod: 1001, name: "sodium-0.8.2")]))
        let files = try await CurseForgeAPI(key: Self.key, http: http)
            .files(modID: 1001, kind: .mods, gameVersion: "1.21.11", gameLoader: "fabric")
        #expect(files.map(\.id) == [520, 510, 500])
        #expect(CurseForgeAPI.preferred(files)?.id == 510)
        #expect(files[1].sha1 == "da39a3ee5e6b4b0d3255bfef95601890afd80709")
    }

    /// A mod needing Fabric API (required) and incompatible with an installed mod, with
    /// one dependency whose author blocks downloads in other apps.
    @Test func planFollowsDependenciesAndKeepsBlockedFilesOut() async throws {
        let http = MockHTTP()
        http.on("\(Self.api)/mods/2002", 200, ["data": Self.mod(2002, "FabricAPI")])
        http.on("\(Self.api)/mods/2002/files", 200, Self.page([Self.file(700, mod: 2002, name: "fabric-api-0.140")]))
        http.on("\(Self.api)/mods/3003", 200, ["data": Self.mod(3003, "Blocked", allow: false)])
        http.on("\(Self.api)/mods/3003/files", 200, Self.page([Self.file(800, mod: 3003, name: "blocked-lib", url: nil)]))
        http.on("\(Self.api)/mods/4004", 200, ["data": Self.mod(4004, "OldThing")])
        let api = CurseForgeAPI(key: Self.key, http: http)
        let root = try JSONDecoder().decode(CurseForgeAPI.Mod.self, from: JSONSerialization.data(withJSONObject: Self.mod(1001, "Cool")))
        let file = try JSONDecoder().decode(CurseForgeAPI.File.self, from: JSONSerialization.data(withJSONObject:
            Self.file(600, mod: 1001, name: "cool-1.0", deps: [(2002, 3), (3003, 3), (4004, 5), (5005, 2)])))

        let plan = try await CurseForgeInstaller(api: api)
            .plan(file, of: root, gameVersion: "1.21.11", gameLoader: "fabric", installed: [4004])
        #expect(plan.items.map(\.mod.name) == ["Cool", "FabricAPI", "Blocked"])
        #expect(plan.items.map(\.isDependency) == [false, true, true])
        #expect(plan.conflicts == ["OldThing"])
        #expect(plan.blocked.map(\.mod.name) == ["Blocked"])
        #expect(plan.downloadable.count == 2)
        // The optional dependency (5005) is not asked for.
        #expect(!http.requests.contains { $0.url?.path.contains("5005") == true })

        // A dependency installed from Modrinth or a file (its mod id matches the slug) is not planned again.
        let again = try await CurseForgeInstaller(api: api)
            .plan(file, of: root, gameVersion: "1.21.11", gameLoader: "fabric", installed: [4004], installedModIDs: ["fabricapi"])
        #expect(again.items.map(\.mod.name) == ["Cool", "Blocked"])
        #expect(again.alreadyInstalled == [2002])
    }

    @Test func installRecordsFilesAndReplacesOldOnes() async throws {
        let tmp = try TempDir()
        let manager = ContentManager(gameDirectory: tmp.url)
        let mods = manager.folder(.mods)
        try FileManager.default.createDirectory(at: mods, withIntermediateDirectories: true)
        // An older Cool from CurseForge, switched off.
        try Data("old".utf8).write(to: mods.appendingPathComponent("cool-0.9.jar.disabled"))
        var index = CurseForgeIndex()
        index.files["cool-0.9.jar"] = .init(modID: 1001, fileID: 590, kind: "mods")
        try index.save(manager)
        #expect(CurseForgeIndex.load(manager).installed(manager)[1001]?.count == 1)

        let body = Data("new jar".utf8)
        let transport = MockTransport()
        transport.enqueue(URL(string: "https://edge.forgecdn.net/files/600/cool-1.0.jar")!, .ok(body))
        var f = Self.file(600, mod: 1001, name: "cool-1.0")
        f["hashes"] = [["value": FileHash.sha1(of: body), "algo": 1]]
        f["fileLength"] = body.count
        let file = try JSONDecoder().decode(CurseForgeAPI.File.self, from: JSONSerialization.data(withJSONObject: f))
        let root = try JSONDecoder().decode(CurseForgeAPI.Mod.self, from: JSONSerialization.data(withJSONObject: Self.mod(1001, "Cool")))
        var plan = CurseForgeInstallPlan()
        plan.items = [.init(mod: root, file: file, isDependency: false)]

        let installer = CurseForgeInstaller(api: CurseForgeAPI(key: Self.key, http: MockHTTP()),
                                            downloader: DownloadManager(transport: transport, retry: RetryPolicy(maxAttempts: 1, baseDelay: .zero),
                                                                        log: Logger(), sleep: { _ in }))
        let report = try await installer.install(plan, kind: .mods, into: manager)
        #expect(report.succeeded)
        #expect(FileManager.default.fileExists(atPath: mods.appendingPathComponent("cool-1.0.jar").path))
        #expect(!FileManager.default.fileExists(atPath: mods.appendingPathComponent("cool-0.9.jar.disabled").path))
        let saved = CurseForgeIndex.load(manager)
        #expect(saved.files.keys.sorted() == ["cool-1.0.jar"])
        #expect(saved.files["cool-1.0.jar"] == .init(modID: 1001, fileID: 600, kind: "mods"))
    }
}
