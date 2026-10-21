import Foundation
import Testing
@testable import VoxeliumCore

@Suite struct ForgeTests {
    @Test func neoForgeBuildNumbersFollowMinecraft() throws {
        #expect(ForgeMeta.neoForgePrefix(minecraft: "1.21.1") == "21.1.")
        #expect(ForgeMeta.neoForgePrefix(minecraft: "1.21") == "21.0.")
        #expect(ForgeMeta.neoForgePrefix(minecraft: "1.20.2") == "20.2.")
        #expect(ForgeMeta.neoForgePrefix(minecraft: "26.1") == "26.1.0.")
        #expect(ForgeMeta.neoForgePrefix(minecraft: "26.1.2") == "26.1.2.")
        // 1.20.1's NeoForge used Forge's installer; older versions have none.
        #expect(ForgeMeta.neoForgePrefix(minecraft: "1.20.1") == nil)
        #expect(ForgeMeta.neoForgePrefix(minecraft: "1.19.2") == nil)
        #expect(ForgeMeta.neoForgePrefix(minecraft: "25w14craftmine") == nil)

        let list = Data(#"{"isSnapshot":false,"versions":["21.0.167","21.1.9","21.1.99","21.1.100","21.1.101-beta","21.10.1","0.25w14craftmine.3-beta"]}"#.utf8)
        let builds = try ForgeMeta.neoForgeBuilds(list, minecraft: "1.21.1")
        #expect(builds.map(\.version) == ["21.1.101-beta", "21.1.100", "21.1.99", "21.1.9"])
        #expect(builds.map(\.stable) == [false, true, true, true])
        #expect(ModLoaderMeta.recommended(builds)?.version == "21.1.100")
    }

    @Test func forgeBuildsAndTheRecommendedOne() async throws {
        let xml = Data("""
            <metadata><versioning><versions>
            <version>1.7.10-10.13.4.1614-1.7.10</version><version>1.20.1-47.4.9</version>
            <version>1.20.1-47.4.10</version><version>1.20.1-47.4.28</version><version>1.20.10-1.0</version>
            </versions></versioning></metadata>
            """.utf8)
        let http = MockHTTP()
        http.onRaw("https://maven.minecraftforge.net/net/minecraftforge/forge/maven-metadata.xml", 200, xml)
        http.on("https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json", 200,
                ["promos": ["1.20.1-recommended": "47.4.10", "1.20.1-latest": "47.4.28"]])
        let builds = try await ModLoaderMeta(http: http).versions(for: .forge, minecraft: "1.20.1")
        #expect(builds.map(\.version) == ["47.4.28", "47.4.10", "47.4.9"])
        #expect(ModLoaderMeta.recommended(builds)?.version == "47.4.10")
        // Without promotions the newest build is offered.
        #expect(ModLoaderMeta.recommended(ForgeMeta.forgeBuilds(xml, promotions: nil, minecraft: "1.20.1"))?.version == "47.4.28")
        await #expect(throws: ModLoaderError.noBuilds(.forge, "1.99")) { try await ModLoaderMeta(http: http).versions(for: .forge, minecraft: "1.99") }
    }

    @Test func emptyDownloadURLsMeanTheInstallerMakesTheFile() throws {
        let lib = try JSONDecoder().decode(Library.self, from: Data("""
            {"name":"net.minecraftforge:forge:1.21.11-61.2.0:client","downloads":{"artifact":
             {"path":"net/minecraftforge/forge/1.21.11-61.2.0/forge-1.21.11-61.2.0-client.jar","url":"","sha1":"","size":0}}}
            """.utf8))
        #expect(lib.artifact?.isProducedByInstaller == true)
        // It round-trips as an empty URL.
        let again = try JSONDecoder().decode(Library.self, from: try JSONEncoder().encode(lib))
        #expect(again == lib)
    }

    @Test func moduleOptionsInTheFormJNIAccepts() {
        let args = ["-DlibraryDirectory=/l", "-p", "/a.jar:/b.jar", "--add-modules", "ALL-MODULE-PATH",
                    "--add-opens", "java.base/java.util.jar=cpw.mods.securejarhandler",
                    "--add-exports", "jdk.naming.dns/com.sun.jndi.dns=java.naming", "-DignoreList=client-extra,x.jar"]
        #expect(ForgeLaunch.jniOptions(args) == [
            "-DlibraryDirectory=/l", "--module-path=/a.jar:/b.jar", "--add-modules=ALL-MODULE-PATH",
            "--add-opens=java.base/java.util.jar=cpw.mods.securejarhandler",
            "--add-exports=jdk.naming.dns/com.sun.jndi.dns=java.naming", "-DignoreList=client-extra,x.jar",
        ])
        #expect(ForgeLaunch.extendIgnoreList(args, with: ["voxelium-boot.jar"]).last == "-DignoreList=client-extra,x.jar,voxelium-boot.jar")
        #expect(ForgeLaunch.jniOptions(["-Xmx1G", "--add-opens"]) == ["-Xmx1G", "--add-opens"])
    }

    @Test func turnsOffTheEarlyLoadingWindow() throws {
        let tmp = try TempDir()
        let file = tmp.url.appendingPathComponent("config/fml.toml")
        try ForgeLaunch.disableEarlyWindow(gameDirectory: tmp.url)
        #expect(try String(contentsOf: file, encoding: .utf8) == "earlyWindowControl = false\n")

        try "#Shows an early loading screen\nearlyWindowControl = true\nmaxThreads = -1\n".write(to: file, atomically: true, encoding: .utf8)
        try ForgeLaunch.disableEarlyWindow(gameDirectory: tmp.url)
        #expect(try String(contentsOf: file, encoding: .utf8) == "#Shows an early loading screen\nearlyWindowControl = false\nmaxThreads = -1\n")
    }

    // MARK: Installing from an installer jar

    /// Zips the files under `dir` with /usr/bin/zip.
    func zip(_ dir: URL, to out: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = dir
        p.arguments = ["-qr", out.path, "."]
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
    }

    func write(_ text: String, _ path: String, in dir: URL) throws {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func installsFromAnInstallerAndWritesTheProcessorPlan() async throws {
        let tmp = try TempDir()
        let paths = tmp.paths
        let tool = Data("tool jar".utf8)
        let universal = "universal jar"
        let src = tmp.url.appendingPathComponent("installer-src")
        try write("""
            {"spec":1,"version":"neoforge-20.4.1","minecraft":"1.20.1","json":"/version.json",
             "data":{"BINPATCH":{"client":"/data/client.lzma","server":"/data/server.lzma"},
                     "PATCHED":{"client":"[net.neoforged:minecraft-client-patched:20.4.1]","server":"[x:y:1]"},
                     "PATCHED_SHA":{"client":"'0123456789abcdef0123456789abcdef01234567'","server":"''"},
                     "MCP_VERSION":{"client":"'1.20.1-2023'","server":"'1'"}},
             "processors":[
               {"sides":["server"],"jar":"net.neoforged.installertools:installertools:1.0:fatjar","args":["--task","EXTRACT_FILES"]},
               {"jar":"net.neoforged.installertools:installertools:1.0:fatjar",
                "classpath":["net.neoforged.installertools:installertools:1.0:fatjar"],
                "args":["--task","PROCESS_MINECRAFT_JAR","--side","{SIDE}","--input","{MINECRAFT_JAR}",
                        "--output","{PATCHED}","--apply-patches","{BINPATCH}","--libs","{ROOT}/libraries/",
                        "--neoform","[net.neoforged:neoform:1.20.1-2023:mappings@tsrg.lzma]","--mcp","{MCP_VERSION}"],
                "outputs":{"{PATCHED}":"{PATCHED_SHA}"}}],
             "libraries":[
               {"name":"net.neoforged.installertools:installertools:1.0:fatjar","downloads":{"artifact":{
                 "path":"net/neoforged/installertools/installertools/1.0/installertools-1.0-fatjar.jar",
                 "url":"https://maven.neoforged.net/releases/net/neoforged/installertools/installertools/1.0/installertools-1.0-fatjar.jar",
                 "sha1":"\(FileHash.sha1(of: tool))","size":\(tool.count)}}},
               {"name":"net.neoforged:neoforge:20.4.1:universal","downloads":{"artifact":{
                 "path":"net/neoforged/neoforge/20.4.1/neoforge-20.4.1-universal.jar","url":"",
                 "sha1":"\(FileHash.sha1(of: Data(universal.utf8)))","size":\(universal.count)}}}]}
            """, "install_profile.json", in: src)
        try write("""
            {"id":"neoforge-20.4.1","inheritsFrom":"1.20.1","type":"release","mainClass":"net.neoforged.fml.startup.Client",
             "releaseTime":"2026-10-15T01:40:32.034268352",
             "arguments":{"game":["--fml.neoForgeVersion","20.4.1"],"jvm":["-DlibraryDirectory=${library_directory}"]},
             "libraries":[
               {"name":"net.neoforged:neoforge:20.4.1:universal","downloads":{"artifact":{
                 "path":"net/neoforged/neoforge/20.4.1/neoforge-20.4.1-universal.jar","url":"","sha1":"","size":0}}},
               {"name":"net.neoforged:minecraft-client-patched:20.4.1","downloads":{"artifact":{
                 "path":"net/neoforged/minecraft-client-patched/20.4.1/minecraft-client-patched-20.4.1.jar","url":"","sha1":"","size":0}}}]}
            """, "version.json", in: src)
        try write("patches", "data/client.lzma", in: src)
        try write(universal, "maven/net/neoforged/neoforge/20.4.1/neoforge-20.4.1-universal.jar", in: src)
        let jar = tmp.url.appendingPathComponent("installer.jar")
        try zip(src, to: jar)
        let jarData = try Data(contentsOf: jar)

        // NeoForge-shaped files from Forge's Maven: NeoForge is not offered for 1.20.1, and
        // the installer format is the same.
        let installerURL = "https://maven.minecraftforge.net/net/minecraftforge/forge/1.20.1-20.4.1/forge-1.20.1-20.4.1-installer.jar"
        let http = MockHTTP()
        http.onRaw(installerURL + ".sha1", 200, Data((FileHash.sha1(of: jarData) + "\n").utf8))
        let transport = MockTransport()
        transport.enqueue(URL(string: installerURL)!, .ok(jarData))
        transport.enqueue(URL(string: "https://maven.neoforged.net/releases/net/neoforged/installertools/installertools/1.0/installertools-1.0-fatjar.jar")!, .ok(tool))
        let installer = ForgeInstaller(paths: paths, downloader: DownloadManager(transport: transport), http: http)

        let (id, report) = try await installer.installProfile(.forge, minecraft: "1.20.1", build: "20.4.1")
        #expect(id == "neoforge-20.4.1" && report.succeeded)
        let lib = paths.librariesDir
        #expect(try String(contentsOf: lib.appendingPathComponent("net/neoforged/neoforge/20.4.1/neoforge-20.4.1-universal.jar"), encoding: .utf8) == universal)
        #expect(try Data(contentsOf: lib.appendingPathComponent("net/neoforged/installertools/installertools/1.0/installertools-1.0-fatjar.jar")) == tool)
        #expect(FileManager.default.fileExists(atPath: try paths.versionJSON(id).path))

        let planURL = try #require(ForgeInstaller.processorPlan(id, paths: paths))
        #expect(!ForgeInstaller.processorsDone(planURL))
        let toolPath = lib.appendingPathComponent("net/neoforged/installertools/installertools/1.0/installertools-1.0-fatjar.jar").path
        let patched = lib.appendingPathComponent("net/neoforged/minecraft-client-patched/20.4.1/minecraft-client-patched-20.4.1.jar").path
        let patches = try paths.versionDir(id).appendingPathComponent("installer-data/data/client.lzma")
        #expect(try String(contentsOf: patches, encoding: .utf8) == "patches")
        // The server-only processor is left out; tokens, [artifacts] and 'literals' are resolved.
        #expect(try String(contentsOf: planURL, encoding: .utf8) == """
            processor installertools PROCESS_MINECRAFT_JAR
            jar \(toolPath)
            cp \(toolPath)
            arg --task
            arg PROCESS_MINECRAFT_JAR
            arg --side
            arg client
            arg --input
            arg \(try paths.clientJar("1.20.1").path)
            arg --output
            arg \(patched)
            arg --apply-patches
            arg \(patches.path)
            arg --libs
            arg \(paths.gameDir.path)/libraries/
            arg --neoform
            arg \(lib.path)/net/neoforged/neoform/1.20.1-2023/neoform-1.20.1-2023-mappings.tsrg.lzma
            arg --mcp
            arg 1.20.1-2023
            out \(patched) 0123456789abcdef0123456789abcdef01234567
            end

            """)

        // The launch plan: the patched jar is not "missing" before the first launch, and
        // Forge versions leave the vanilla client jar off the classpath.
        try FileManager.default.createDirectory(at: try paths.versionDir("1.20.1"), withIntermediateDirectories: true)
        try Fixture.data("1.20.1").write(to: try paths.versionJSON("1.20.1"))
        let resolved = try VersionResolver(paths: paths).resolve(id)
        #expect(ForgeLaunch.processorPlan(for: resolved, paths: paths) == planURL)
        let plan = try LaunchPlanner(paths: paths).plan(version: resolved.info, identity: OfflineIdentity.identity(for: "Steve"),
                                                        includeClientJar: false)
        #expect(plan.classpath.contains { $0.path == patched })
        #expect(!plan.missingFiles.contains { $0.path == patched })
        #expect(!plan.classpath.contains { $0.lastPathComponent == "1.20.1.jar" })
        // GameInstaller does not try to download it either.
        #expect(!(try GameFilePlanner(paths: paths).installItems(for: resolved.info)).contains { $0.destination.path == patched })
    }

    @Test func forgeOnlyFrom117() async throws {
        #expect(ModLoader.forge.isAvailable(minecraft: "1.17.1"))
        #expect(ModLoader.forge.isAvailable(minecraft: "1.20.1"))
        #expect(ModLoader.forge.isAvailable(minecraft: "26.1.2"))
        #expect(!ModLoader.forge.isAvailable(minecraft: "1.16.5"))
        #expect(!ModLoader.forge.isAvailable(minecraft: "1.12.2"))
        #expect(!ModLoader.neoforge.isAvailable(minecraft: "1.20.1"))
        #expect(ModLoader.fabric.isAvailable(minecraft: "1.16.5"))

        // Nothing is fetched or downloaded for a version Forge is not offered for
        // (this is also the path modpacks take).
        let tmp = try TempDir()
        let http = MockHTTP()
        let transport = MockTransport()
        let installer = ForgeInstaller(paths: tmp.paths, downloader: DownloadManager(transport: transport), http: http)
        await #expect(throws: ModLoaderError.notOffered(.forge, "1.16.5")) {
            try await installer.installProfile(.forge, minecraft: "1.16.5", build: "36.2.34")
        }
        await #expect(throws: ModLoaderError.notOffered(.forge, "1.16.5")) {
            try await ModLoaderMeta(http: http).versions(for: .forge, minecraft: "1.16.5")
        }
        #expect(http.requests.isEmpty && transport.requests.isEmpty)
        #expect(ModLoaderError.notOffered(.forge, "1.16.5").description == "Voxelium offers Forge for Minecraft 1.17 and newer, not 1.16.5.")
    }
}
