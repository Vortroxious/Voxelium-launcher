import Foundation
import Testing
@testable import VoxeliumCore

@Suite struct ModrinthTests {
    static let api = "https://api.modrinth.com/v2"

    func json(_ name: String) throws -> Any {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/modrinth"))
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    }
    func decode<T: Decodable>(_ name: String, as: T.Type) throws -> T {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/modrinth"))
        return try ModrinthAPI.decoder().decode(T.self, from: Data(contentsOf: url))
    }

    @Test func searchBuildsFacetsAndDecodes() async throws {
        let http = MockHTTP()
        http.on("\(Self.api)/search", 200, try json("search-iris-fabric-1.21.11"))
        let page = try await ModrinthAPI(http: http).search("iris", kind: .mods, gameVersion: "1.21.11", gameLoader: "quilt")
        #expect(page.hits.first?.title == "Iris Shaders" && page.hits.first?.slug == "iris" && page.totalHits == 21)
        let url = try #require(http.requests.first?.url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let facets = try #require(items.first { $0.name == "facets" }?.value)
        // Quilt also runs Fabric mods.
        #expect(facets == #"[["project_type:mod"],["versions:1.21.11"],["categories:quilt","categories:fabric"]]"#)
        #expect(http.requests.first?.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Voxelium/") == true)

        // Shader packs ask for Iris-compatible ones; resource packs have no loader facet.
        #expect(ModrinthAPI.loaders(for: .shaderPacks, gameLoader: "fabric") == ["iris"])
        #expect(ModrinthAPI.loaders(for: .resourcePacks, gameLoader: "fabric") == ["minecraft"])
    }

    /// Iris 1.10.8 requires Sodium pinned to one build (0.8.14), although a newer
    /// beta (0.8.15-beta.1) exists: the pinned build must win.
    func irisHTTP() throws -> MockHTTP {
        let http = MockHTTP()
        http.on("\(Self.api)/version/rkdTcxoT", 200, try json("version-rkdTcxoT"))
        http.on("\(Self.api)/project/AANobbMI", 200, try json("project-sodium"))
        http.on("\(Self.api)/project/AANobbMI/version", 200, try json("dep-sodium-versions"))
        return http
    }

    @Test func plansPinnedRequiredDependencies() async throws {
        let iris = try #require(try decode("iris-versions-fabric-1.21.11", as: [ModrinthAPI.Version].self).first)
        #expect(iris.versionNumber == "1.10.8+1.21.11-fabric" && iris.primaryFile?.hashes.sha1 == "acfbe6d065b6c35d85c14da04d35e073363f3acf")
        let installer = ModrinthInstaller(api: ModrinthAPI(http: try irisHTTP()))
        let plan = try await installer.plan(iris, title: "Iris Shaders", kind: .mods, gameVersion: "1.21.11", gameLoader: "fabric", installed: [])
        #expect(plan.items.map(\.title) == ["Iris Shaders", "Sodium"])
        #expect(plan.items.map(\.isDependency) == [false, true])
        #expect(plan.items[1].version.versionNumber == "mc1.21.11-0.8.14-fabric")   // pinned, not the newer beta
        #expect(plan.alreadyInstalled.isEmpty && plan.unavailable.isEmpty && plan.conflicts.isEmpty)

        // Already-installed dependencies are skipped.
        let again = try await installer.plan(iris, title: "Iris Shaders", kind: .mods, gameVersion: "1.21.11", gameLoader: "fabric", installed: ["AANobbMI"])
        #expect(again.items.map(\.title) == ["Iris Shaders"] && again.alreadyInstalled == ["AANobbMI"])
        #expect(ModrinthAPI.preferred(try decode("dep-sodium-versions", as: [ModrinthAPI.Version].self))?.versionNumber == "mc1.21.11-0.8.14-fabric")
    }

    @Test func findsInstalledProjectsByHash() async throws {
        let tmp = try TempDir()
        let cm = ContentManager(gameDirectory: tmp.paths.root)
        let jar = try #require(Bundle.module.url(forResource: "fabric-example-1.2.3", withExtension: "jar", subdirectory: "Fixtures/content"))
        let installed = try cm.add(jar, as: .mods)
        let sha1 = try FileHash.sha1(of: installed.url)
        // The lookup answers only for known hashes; map ours to Iris's version.
        let iris = try #require((try json("version-files-lookup") as? [String: Any])?.values.first)
        let http = MockHTTP()
        http.on("\(Self.api)/version_files", 200, [sha1: iris])
        let found = try await ModrinthInstaller(api: ModrinthAPI(http: http)).installedProjects(cm, kind: .mods)
        #expect(found["YL57xq9U"]?.map(\.lastPathComponent) == ["fabric-example-1.2.3.jar"])
        let body = String(decoding: http.requests.first?.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains(sha1) && body.contains("\"algorithm\":\"sha1\""))
    }

    @Test func installsVerifiedFilesAndReplacesOldOnes() async throws {
        let tmp = try TempDir()
        let cm = ContentManager(gameDirectory: tmp.paths.root)
        let modBytes = Data("new mod".utf8), depBytes = Data("dependency".utf8), packBytes = Data("pack".utf8)
        func version(_ id: String, _ project: String, _ file: String, _ bytes: Data) -> ModrinthAPI.Version {
            .init(id: id, projectId: project, name: id, versionNumber: "1", versionType: "release",
                  files: [.init(url: URL(string: "https://cdn.example/\(file)")!, filename: file, primary: true,
                                size: Int64(bytes.count), hashes: .init(sha1: FileHash.sha1(of: bytes)))],
                  dependencies: [], loaders: ["iris"], gameVersions: ["1.21.11"])
        }
        // An older copy of the shader pack project is installed and must be replaced.
        let old = cm.folder(.shaderPacks).appendingPathComponent("old-pack.zip")
        try FileManager.default.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: old)

        let transport = MockTransport()
        transport.enqueue(URL(string: "https://cdn.example/new-pack.zip")!, .ok(packBytes))
        transport.enqueue(URL(string: "https://cdn.example/iris.jar")!, .ok(depBytes))
        var plan = ModrinthInstallPlan()
        plan.items = [.init(projectID: "PACK", title: "Pack", version: version("v1", "PACK", "new-pack.zip", packBytes), isDependency: false),
                      .init(projectID: "IRIS", title: "Iris", version: version("v2", "IRIS", "iris.jar", depBytes), isDependency: true)]
        let installer = ModrinthInstaller(api: ModrinthAPI(http: MockHTTP()), downloader: DownloadManager(transport: transport, retry: RetryPolicy(maxAttempts: 1)))
        let report = try await installer.install(plan, kind: .shaderPacks, into: cm, replacing: ["PACK": [old]])
        #expect(report.succeeded)
        #expect(try Data(contentsOf: cm.folder(.shaderPacks).appendingPathComponent("new-pack.zip")) == packBytes)
        #expect(try Data(contentsOf: cm.folder(.mods).appendingPathComponent("iris.jar")) == depBytes)   // dependency → mods/
        #expect(!FileManager.default.fileExists(atPath: old.path))

        // A bad checksum fails the install and keeps what was there.
        let keep = cm.folder(.mods).appendingPathComponent("keep.jar")
        try Data("keep".utf8).write(to: keep)
        let bad = MockTransport()
        bad.enqueue(URL(string: "https://cdn.example/mod.jar")!, .ok(Data("tampered".utf8)))
        var badPlan = ModrinthInstallPlan()
        badPlan.items = [.init(projectID: "MOD", title: "Mod", version: version("v3", "MOD", "mod.jar", modBytes), isDependency: false)]
        let failed = try await ModrinthInstaller(api: ModrinthAPI(http: MockHTTP()), downloader: DownloadManager(transport: bad, retry: RetryPolicy(maxAttempts: 1)))
            .install(badPlan, kind: .mods, into: cm, replacing: ["MOD": [keep]])
        #expect(!failed.succeeded && FileManager.default.fileExists(atPath: keep.path))
    }
}
