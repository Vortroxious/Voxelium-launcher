import Foundation
import Testing
@testable import VoxeliumCore

@Suite struct ModpackTests {
    func fixture(_ file: String) throws -> URL {
        let name = (file as NSString).deletingPathExtension, ext = (file as NSString).pathExtension
        return try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/modpack"))
    }

    @Test func readsARealModrinthIndex() throws {
        // Fabulously Optimized 12.3.0's modrinth.index.json, trimmed to 3 files (2026-10-18).
        let index = try ModpackIndex.decode(Data(contentsOf: fixture("fabulously-optimized-12.3.0-index.json")))
        #expect(index.formatVersion == 1 && index.name == "Fabulously Optimized" && index.versionId == "12.3.0")
        #expect(index.minecraft == "1.21.11")
        #expect(index.loader?.loader == .fabric && index.loader?.version == "0.19.3")
        #expect(index.files.count == 3 && index.files.allSatisfy(\.isForClient))
        #expect(index.files[0].hashes["sha1"]?.count == 40 && index.files[0].downloads.first?.host == "cdn.modrinth.com")
        #expect(ModpackInstaller.versionID(for: index) == "Fabulously Optimized 12.3.0")
        #expect(index.clientModCount == 3)
    }

    @Test func refusesUnsafePathsAndHosts() throws {
        let tmp = try TempDir()
        let installer = ModpackInstaller(game: GameInstaller(paths: tmp.paths))
        let instance = try tmp.paths.instanceDir("Pack 1")
        func index(path: String, url: String, client: String = "required") -> ModpackIndex {
            .init(formatVersion: 1, game: "minecraft", versionId: "1", name: "Pack", summary: nil,
                  files: [.init(path: path, hashes: ["sha1": String(repeating: "a", count: 40)],
                                env: .init(client: client, server: "required"), downloads: [URL(string: url)!], fileSize: 1)],
                  dependencies: ["minecraft": "1.21.11"])
        }
        #expect(throws: ModpackError.unsafePath("../evil.jar")) {
            try installer.plannedDownloads(index(path: "../evil.jar", url: "https://cdn.modrinth.com/a.jar"), into: instance)
        }
        #expect(throws: ModpackError.unsafePath("/etc/evil")) {
            try installer.plannedDownloads(index(path: "/etc/evil", url: "https://cdn.modrinth.com/a.jar"), into: instance)
        }
        #expect(throws: ModpackError.untrustedDownload("evil.example")) {
            try installer.plannedDownloads(index(path: "mods/a.jar", url: "https://evil.example/a.jar"), into: instance)
        }
        // Server-only files are skipped; others land inside the instance.
        #expect(try installer.plannedDownloads(index(path: "mods/s.jar", url: "https://cdn.modrinth.com/s.jar", client: "unsupported"),
                                               into: instance).isEmpty)
        let ok = try installer.plannedDownloads(index(path: "mods/a.jar", url: "https://github.com/x/a.jar"), into: instance)
        #expect(ok.map(\.destination) == [instance.appendingPathComponent("mods/a.jar").standardizedFileURL])
        #expect(ModpackInstaller.versionID(for: index(path: "", url: "https://x")) == "Pack 1")
        // A name that already ends with the version is not repeated.
        let named = ModpackIndex(formatVersion: 1, game: "minecraft", versionId: "3.2", name: "Genesis 3.2", summary: nil,
                                 files: [], dependencies: ["minecraft": "1.20.1"])
        #expect(ModpackInstaller.versionID(for: named) == "Genesis 3.2")
    }

    @Test func installsAVanillaPackWithOverrides() async throws {
        let tmp = try TempDir()
        // Minecraft 1.21.11 is already installed: a minimal version whose only file (an
        // empty asset index) is present and valid, so nothing needs downloading.
        let assetIndex = Data(#"{"objects":{}}"#.utf8)
        let indexFile = try tmp.paths.assetIndex("29")
        try FileManager.default.createDirectory(at: indexFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try assetIndex.write(to: indexFile)
        let base = try tmp.paths.versionJSON("1.21.11")
        try FileManager.default.createDirectory(at: base.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
            {"id":"1.21.11","type":"release","mainClass":"net.minecraft.client.main.Main","libraries":[],"assets":"29",
             "assetIndex":{"id":"29","sha1":"\(FileHash.sha1(of: assetIndex))","size":\(assetIndex.count),"totalSize":0,
                           "url":"https://piston-meta.mojang.com/v1/packages/x/29.json"}}
            """.utf8).write(to: base)
        let transport = MockTransport()
        let game = GameInstaller(paths: tmp.paths, downloader: DownloadManager(transport: transport, retry: RetryPolicy(maxAttempts: 1)))
        try Data().write(to: try game.completionMarker("1.21.11"))
        transport.enqueue(URL(string: "https://cdn.modrinth.com/data/TEST/versions/1/test-pack.zip")!, .ok(Data("pack bytes".utf8)))

        let installer = ModpackInstaller(game: game)
        let (id, report) = try await installer.install(try fixture("test-vanilla.mrpack"), source: ("PROJ", "VER"))
        #expect(report.succeeded)
        #expect(id == "Test Pack- Vanilla+ 1.0.0")
        #expect(game.isInstalled(id))

        // Its own version, building on Minecraft, with its own game folder.
        let resolved = try VersionResolver(paths: tmp.paths).resolve(id)
        #expect(resolved.isModded && resolved.baseVersionID == "1.21.11" && resolved.info.mainClass == "net.minecraft.client.main.Main")
        let instance = try tmp.paths.instanceDir(id)
        #expect(try Data(contentsOf: instance.appendingPathComponent("resourcepacks/test-pack.zip")) == Data("pack bytes".utf8))
        #expect(!FileManager.default.fileExists(atPath: instance.appendingPathComponent("mods/server-only.jar").path))
        #expect(transport.requests.count == 1)   // the server-only file was not downloaded
        #expect(try String(contentsOf: instance.appendingPathComponent("config/test.txt"), encoding: .utf8) == "from overrides")
        #expect(try String(contentsOf: instance.appendingPathComponent("options.txt"), encoding: .utf8) == "lang:id_id\n")  // client-overrides win
        let record = try #require(ModpackInstaller.installedModpack(in: instance))
        #expect(record == InstalledModpack(name: "Test Pack: Vanilla+", versionNumber: "1.0.0", minecraft: "1.21.11",
                                           loader: nil, projectID: "PROJ", versionID: "VER"))

        // Installing the same pack again is refused rather than overwriting the instance.
        await #expect(throws: ModpackError.alreadyInstalled(id)) { try await installer.install(try fixture("test-vanilla.mrpack")) }
    }

    @Test func readsForgeAndNeoForgePacksAndRefusesOtherZips() async throws {
        let neo = try ModpackInstaller.read(try fixture("test-neoforge.mrpack")).index
        #expect(neo.loader?.loader == .neoforge)
        #expect(neo.loader?.version == "21.1.77")
        // Forge packs write the bare build or "<minecraft>-<build>".
        for raw in ["47.4.10", "1.20.1-47.4.10"] {
            let index = try ModpackIndex.decode(Data("""
                {"formatVersion":1,"game":"minecraft","versionId":"1","name":"F","files":[],
                 "dependencies":{"minecraft":"1.20.1","forge":"\(raw)"}}
                """.utf8))
            #expect(index.loader?.loader == .forge)
            #expect(index.loader?.version == "47.4.10")
        }
        #expect(throws: ModpackError.notAModpack) {
            try ModpackInstaller.read(try #require(Bundle.module.url(forResource: "gold-pack", withExtension: "zip", subdirectory: "Fixtures/content")))
        }
    }
}
