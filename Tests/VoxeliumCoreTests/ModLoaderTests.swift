import Foundation
import Testing
@testable import VoxeliumCore

@Suite struct ModLoaderTests {
    /// The real Fabric 0.20.0 profile, re-pointed at the 1.20.1 fixture so it can be
    /// merged against a vanilla version JSON we have on disk.
    func fabricProfileOn1201() throws -> Data {
        var json = try #require(JSONSerialization.jsonObject(with: Fixture.data("fabric-profile-0.20.0-1.21.11")) as? [String: Any])
        json["inheritsFrom"] = "1.20.1"
        json["id"] = "fabric-loader-0.20.0-1.20.1"
        return try JSONSerialization.data(withJSONObject: json)
    }

    func install(_ data: Data, as id: String, in paths: AppPaths) throws {
        let url = try paths.versionJSON(id)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    @Test func mergesFabricOntoVanilla() throws {
        let tmp = try TempDir()
        try install(Fixture.data("1.20.1"), as: "1.20.1", in: tmp.paths)
        try install(fabricProfileOn1201(), as: "fabric-loader-0.20.0-1.20.1", in: tmp.paths)

        let r = try VersionResolver(paths: tmp.paths).resolve("fabric-loader-0.20.0-1.20.1")
        #expect(r.chain == ["fabric-loader-0.20.0-1.20.1", "1.20.1"])
        #expect(r.isModded && r.baseVersionID == "1.20.1")
        let v = r.info
        #expect(v.inheritsFrom == nil)
        #expect(v.id == "fabric-loader-0.20.0-1.20.1")
        #expect(v.mainClass == "net.fabricmc.loader.impl.launch.knot.KnotClient")
        #expect(v.clientJarID == "1.20.1")
        #expect(v.assetIndex?.id == "5" && v.javaVersion?.majorVersion == 17)
        #expect(v.downloads?.client != nil)

        // Libraries: vanilla first, then Fabric's; the planner keeps one per artifact.
        let fabricLoader = try #require(v.libraries.first { $0.name.hasPrefix("net.fabricmc:fabric-loader:") })
        #expect(fabricLoader.artifact?.url.absoluteString.hasPrefix("https://maven.fabricmc.net/net/fabricmc/fabric-loader/") == true)
        let asm = try #require(v.libraries.first { $0.name == "org.ow2.asm:asm:9.11" })
        #expect(asm.artifact?.sha1 == "2a2c870691d2220eb93492c88fdcd3711ab0fadb" && asm.artifact?.size == 131056)
        let cp = GameFilePlanner(paths: tmp.paths).classpathLibraries(of: v).map(\.name)
        #expect(cp.contains { $0.hasPrefix("net.fabricmc:fabric-loader:") })
        #expect(Set(cp.compactMap { MavenCoordinate($0)?.key }).count == cp.count)

        // Launch plan: Knot main class, vanilla client jar, parent + child JVM arguments,
        // and the modded version's own game folder.
        let instance = try tmp.paths.instanceDir(v.id)
        let plan = try LaunchPlanner(paths: tmp.paths).plan(version: v, identity: OfflineIdentity.identity(for: "Steve"), gameDirectory: instance)
        #expect(plan.mainClass == "net.fabricmc.loader.impl.launch.knot.KnotClient")
        #expect(plan.classpath.last?.path.hasSuffix("versions/1.20.1/1.20.1.jar") == true)
        #expect(plan.jvmArguments.contains { $0.hasPrefix("-DFabricMcEmu=") })
        #expect(plan.jvmArguments.contains("-cp"))
        let gameDir = try #require(plan.gameArguments.firstIndex(of: "--gameDir")).advanced(by: 1)
        #expect(plan.gameArguments[gameDir] == instance.path)
    }

    @Test func resolverErrors() throws {
        let tmp = try TempDir()
        try install(fabricProfileOn1201(), as: "fabric-loader-0.20.0-1.20.1", in: tmp.paths)
        #expect(throws: VersionResolveError.parentMissing(child: "fabric-loader-0.20.0-1.20.1", parent: "1.20.1")) {
            try VersionResolver(paths: tmp.paths).resolve("fabric-loader-0.20.0-1.20.1")
        }
        try install(Data(#"{"id":"a","inheritsFrom":"b","mainClass":"M","libraries":[]}"#.utf8), as: "a", in: tmp.paths)
        try install(Data(#"{"id":"b","inheritsFrom":"a","mainClass":"M","libraries":[]}"#.utf8), as: "b", in: tmp.paths)
        #expect(throws: VersionResolveError.cycle("a")) { try VersionResolver(paths: tmp.paths).resolve("a") }

        // Vanilla versions resolve to themselves.
        try install(Fixture.data("1.20.1"), as: "1.20.1", in: tmp.paths)
        let vanilla = try VersionResolver(paths: tmp.paths).resolve("1.20.1")
        #expect(!vanilla.isModded && vanilla.info.clientJarID == "1.20.1")
    }

    @Test func loaderVersionLists() async throws {
        let http = MockHTTP()
        let fabric = try JSONSerialization.jsonObject(with: Fixture.data("fabric-loaders-1.21.11"))
        let quilt = try JSONSerialization.jsonObject(with: Fixture.data("quilt-loaders-1.21.11"))
        http.on("https://meta.fabricmc.net/v2/versions/loader/1.21.11", 200, fabric)
        http.on("https://meta.quiltmc.org/v3/versions/loader/1.21.11", 200, quilt)
        let meta = ModLoaderMeta(http: http)

        let f = try await meta.versions(for: .fabric, minecraft: "1.21.11")
        #expect(f.map(\.version) == ["0.20.0", "0.19.5", "0.19.4"])
        #expect(f.map(\.stable) == [false, true, false])
        #expect(ModLoaderMeta.recommended(f)?.version == "0.19.5")

        let q = try await meta.versions(for: .quilt, minecraft: "1.21.11")
        #expect(q.first?.version == "0.20.0-beta.9" && q.allSatisfy { !$0.stable })
        #expect(ModLoaderMeta.recommended(q)?.version == "0.20.0-beta.9")   // only betas: newest

        let ua = http.requests.first?.value(forHTTPHeaderField: "User-Agent") ?? ""
        #expect(ua.hasPrefix("Voxelium/"))
        await #expect(throws: ModLoaderError.unsupported(.forge)) { try await meta.versions(for: .forge, minecraft: "1.21.11") }
    }

    @Test func fillsInMissingChecksumsFromMaven() async throws {
        let tmp = try TempDir()
        let http = MockHTTP()
        let profile = try JSONSerialization.jsonObject(with: Fixture.data("fabric-profile-0.20.0-1.21.11"))
        http.on("https://meta.fabricmc.net/v2/versions/loader/1.21.11/0.20.0/profile/json", 200, profile)
        // Only the loader jar's .sha1 is served; intermediary's lookup fails and is skipped.
        let loaderSHA1 = "https://maven.fabricmc.net/net/fabricmc/fabric-loader/0.20.0/fabric-loader-0.20.0.jar.sha1"
        http.onRaw(loaderSHA1, 200, Data("7a3a8ce24fa0150aba52f3e1f7cde5ba17195fcf\n".utf8))
        let v = try await ModLoaderInstaller(paths: tmp.paths, meta: ModLoaderMeta(http: http))
            .installProfile(.fabric, minecraft: "1.21.11", version: "0.20.0")
        let loader = try #require(v.libraries.first { $0.name == "net.fabricmc:fabric-loader:0.20.0" })
        #expect(loader.artifact?.sha1 == "7a3a8ce24fa0150aba52f3e1f7cde5ba17195fcf")
        #expect(v.libraries.first { $0.name.hasPrefix("net.fabricmc:intermediary:") }?.artifact?.sha1 == nil)
        #expect(v.libraries.first { $0.name == "org.ow2.asm:asm:9.11" }?.artifact?.sha1 == "2a2c870691d2220eb93492c88fdcd3711ab0fadb")
        // The saved profile carries the filled-in checksum.
        let saved = try VersionInfo.decode(Data(contentsOf: try tmp.paths.versionJSON(v.id)))
        #expect(saved.libraries.first { $0.name == "net.fabricmc:fabric-loader:0.20.0" }?.sha1 == "7a3a8ce24fa0150aba52f3e1f7cde5ba17195fcf")
    }

    @Test func installsProfileAndChecksTheBaseVersion() async throws {
        let tmp = try TempDir()
        let http = MockHTTP()
        let profile = try JSONSerialization.jsonObject(with: Fixture.data("quilt-profile-1.21.11"))
        let id = try #require((profile as? [String: Any])?["id"] as? String)
        let ver = String(id.dropFirst("quilt-loader-".count).dropLast("-1.21.11".count))
        http.on("https://meta.quiltmc.org/v3/versions/loader/1.21.11/\(ver)/profile/json", 200, profile)
        let installer = ModLoaderInstaller(paths: tmp.paths, meta: ModLoaderMeta(http: http))

        let written = try await installer.installProfile(.quilt, minecraft: "1.21.11", version: ver)
        #expect(written.id == id && written.inheritsFrom == "1.21.11")
        #expect(FileManager.default.fileExists(atPath: try tmp.paths.versionJSON(id).path))

        // A profile built on a different Minecraft version is refused.
        http.on("https://meta.quiltmc.org/v3/versions/loader/1.20.1/\(ver)/profile/json", 200, profile)
        await #expect(throws: ModLoaderError.badProfile("it builds on 1.21.11, not 1.20.1")) {
            try await installer.installProfile(.quilt, minecraft: "1.20.1", version: ver)
        }
    }
}
