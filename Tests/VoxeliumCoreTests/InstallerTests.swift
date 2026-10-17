import Foundation
import Testing
@testable import VoxeliumCore

@Suite struct InstallerTests {
    let host = "https://example.invalid"
    let client = Data("client-jar".utf8)
    let lib = Data("library-jar".utf8)
    let assetA = Data("asset-a".utf8)
    let assetB = Data("asset-b".utf8)

    var indexData: Data {
        let a = FileHash.sha1(of: assetA), b = FileHash.sha1(of: assetB)
        return Data(#"{"objects":{"a.png":{"hash":"\#(a)","size":\#(assetA.count)},"b.ogg":{"hash":"\#(b)","size":\#(assetB.count)}}}"#.utf8)
    }

    func version() throws -> VersionInfo {
        let json = """
        {"id":"t1","mainClass":"M",
         "assetIndex":{"id":"t","sha1":"\(FileHash.sha1(of: indexData))","size":\(indexData.count),"url":"\(host)/index.json"},
         "downloads":{"client":{"sha1":"\(FileHash.sha1(of: client))","size":\(client.count),"url":"\(host)/client.jar"}},
         "libraries":[{"name":"a:b:1","downloads":{"artifact":{"path":"a/b/1/b-1.jar","sha1":"\(FileHash.sha1(of: lib))","size":\(lib.count),"url":"\(host)/b-1.jar"}}}]}
        """
        return try VersionInfo.decode(Data(json.utf8))
    }

    func assetURL(_ d: Data) -> URL {
        let h = FileHash.sha1(of: d)
        return URL(string: "\(host)/res/\(h.prefix(2))/\(h)")!
    }

    func installer(_ paths: AppPaths, _ t: MockTransport) -> GameInstaller {
        var i = GameInstaller(paths: paths, downloader: DownloadManager(transport: t, retry: RetryPolicy(maxAttempts: 2, baseDelay: .zero), log: Logger(), sleep: { _ in }))
        i.assetBase = URL(string: "\(host)/res/")!
        return i
    }

    func enqueueGameFiles(_ t: MockTransport) {
        t.enqueue(URL(string: "\(host)/client.jar")!, .ok(client))
        t.enqueue(URL(string: "\(host)/b-1.jar")!, .ok(lib))
        t.enqueue(URL(string: "\(host)/index.json")!, .ok(indexData))
    }

    @Test func interruptedInstallIsNotMarkedAndResumes() async throws {
        let tmp = try TempDir()
        let v = try version()

        // First run: asset B keeps failing, like an install cut short.
        let t1 = MockTransport()
        enqueueGameFiles(t1)
        t1.enqueue(assetURL(assetA), .ok(assetA))
        t1.enqueue(assetURL(assetB), .status(503))
        let i1 = installer(tmp.paths, t1)
        let r1 = try await i1.install(v, concurrency: 2)
        #expect(!r1.succeeded)
        #expect(!i1.isInstalled("t1"))
        // Game files are on disk, but without the marker it is not "installed".
        #expect(FileManager.default.fileExists(atPath: try tmp.paths.clientJar("t1").path))

        // Second run: only the missing asset is fetched.
        let t2 = MockTransport()
        t2.enqueue(assetURL(assetB), .ok(assetB))
        let i2 = installer(tmp.paths, t2)
        let r2 = try await i2.install(v, concurrency: 2)
        #expect(r2.succeeded)
        #expect(i2.isInstalled("t1"))
        #expect(t2.requests == [assetURL(assetB)])
        #expect(r2.outcomes.values.filter { $0 == .alreadyValid }.count == 4)
    }

    @Test func reinstallClearsMarkerUntilFinished() async throws {
        let tmp = try TempDir()
        let v = try version()
        let t = MockTransport()
        enqueueGameFiles(t)
        t.enqueue(assetURL(assetA), .ok(assetA))
        t.enqueue(assetURL(assetB), .ok(assetB))
        let i = installer(tmp.paths, t)
        #expect(try await i.install(v).succeeded)
        #expect(i.isInstalled("t1"))

        // Corrupt a library; the repair run fails, so the marker must go away.
        try Data("bad".utf8).write(to: try tmp.paths.library("a/b/1/b-1.jar"))
        let broken = MockTransport()
        broken.enqueue(URL(string: "\(host)/b-1.jar")!, .status(500))
        #expect(try await installer(tmp.paths, broken).install(v).succeeded == false)
        #expect(!i.isInstalled("t1"))
    }
}
