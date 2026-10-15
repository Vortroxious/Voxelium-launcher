import Foundation
import Testing
@testable import ZalithCore

// Fixtures were downloaded from piston-meta.mojang.com on 2026-10-15 and their
// SHA-1s match the hashes published in version_manifest_v2.json.
@Suite struct ManifestTests {
    @Test func parsesRealVersionManifest() throws {
        let m = try VersionManifest.decode(Fixture.data("version_manifest_v2"))
        #expect(m.versions.count == 919)
        #expect(m.latest.release == "26.3")
        let v = try #require(m.entry(id: "1.20.1"))
        #expect(v.type == .release)
        #expect(v.sha1 == "a5cf661d31d9dfcd3d1645be80f43954f63f63b0")
        #expect(m.versions(of: [.oldAlpha]).allSatisfy { $0.type == .oldAlpha })
        #expect(!m.versions(of: [.oldAlpha]).isEmpty)
    }

    @Test func fixtureHashesMatchManifest() throws {
        let m = try VersionManifest.decode(Fixture.data("version_manifest_v2"))
        for id in ["1.20.1", "1.12.2"] {
            #expect(FileHash.sha1(of: try Fixture.data(id)) == m.entry(id: id)?.sha1)
        }
    }

    @Test func parsesModernVersionJSON() throws {
        let v = try VersionInfo.decode(Fixture.data("1.20.1"))
        #expect(v.id == "1.20.1")
        #expect(v.mainClass == "net.minecraft.client.main.Main")
        #expect(v.javaVersion == .init(component: "java-runtime-gamma", majorVersion: 17))
        #expect(v.assetIndex?.id == "5")
        #expect(v.assetIndex?.sha1 == "50ce48459eb9e29836662862273d7b15d41c2c33")
        #expect(v.libraries.count == 88)
        #expect(v.downloads?.client?.sha1 == "0c3ec587af28e5a785c0b4a7b8a30f9a8f78f838")
        #expect(v.downloads?.client?.size == 23_028_853)
        #expect(v.arguments?.game?.isEmpty == false)
        #expect(v.minecraftArguments == nil)
        #expect(v.logging?.client?.file.id == "client-1.12.xml")
    }

    @Test func parsesLegacyVersionJSON() throws {
        let v = try VersionInfo.decode(Fixture.data("1.12.2"))
        #expect(v.arguments == nil)
        #expect(v.minecraftArguments?.hasPrefix("--username ${auth_player_name}") == true)
        let natives = v.libraries.filter(\.isNative)
        #expect(!natives.isEmpty)
        #expect(natives.allSatisfy { $0.natives != nil })
    }

    @Test func conditionalArgumentsDecodeBothValueShapes() throws {
        let json = #"[ "--a", {"rules":[{"action":"allow","os":{"name":"osx"}}],"value":["-XstartOnFirstThread"]}, {"rules":[{"action":"allow","os":{"arch":"x86"}}],"value":"-Xss1M"} ]"#
        let args = try JSONDecoder().decode([Argument].self, from: Data(json.utf8))
        #expect(args.count == 3)
        let linux = RulePlatform(osName: "linux", osArch: "aarch64")
        #expect(args.flatMap { $0.resolve(on: linux) } == ["--a"])
        let mac = RulePlatform(osName: "osx", osArch: "x86")
        #expect(args.flatMap { $0.resolve(on: mac) } == ["--a", "-XstartOnFirstThread", "-Xss1M"])
    }

    @Test func parsesAssetIndex() throws {
        let idx = try AssetIndex.decode(Fixture.data("assetindex-5"))
        #expect(idx.objects.count == 3598)
        #expect(idx.uniqueObjects.count == 3575)
        #expect(idx.totalSize == 651_432_558)
        let icon = try #require(idx.objects["icons/icon_128x128.png"])
        #expect(AssetIndex.url(for: icon).absoluteString == "https://resources.download.minecraft.net/b6/b62ca8ec10d07e6bf5ac8dae0c8c1d2e6a1e3356")
    }

    @Test func rejectsMalformedJSON() {
        #expect(throws: DecodingError.self) { try VersionInfo.decode(Data("{\"id\": 1}".utf8)) }
        #expect(throws: (any Error).self) { try VersionManifest.decode(Data("not json".utf8)) }
    }

    @Test(arguments: [
        ("com.mojang:brigadier:1.1.8", "com/mojang/brigadier/1.1.8/brigadier-1.1.8.jar"),
        ("org.lwjgl:lwjgl:3.3.1:natives-macos-arm64", "org/lwjgl/lwjgl/3.3.1/lwjgl-3.3.1-natives-macos-arm64.jar"),
        ("de.oceanlabs.mcp:mcp_config:1.20.1@zip", "de/oceanlabs/mcp/mcp_config/1.20.1/mcp_config-1.20.1.zip"),
    ])
    func mavenPaths(name: String, path: String) throws {
        #expect(try #require(MavenCoordinate(name)).path == path)
    }

    @Test func invalidMavenCoordinates() {
        #expect(MavenCoordinate("nope") == nil)
        #expect(MavenCoordinate("a::c") == nil)
    }
}

@Suite struct RuleTests {
    let linux = RulePlatform.iOSDefault

    @Test func noRulesAllows() { #expect(RuleEvaluator.allows(nil, on: linux)) }

    @Test func lastMatchingRuleWins() {
        let rules = [Rule(action: .allow, os: nil, features: nil), Rule(action: .disallow, os: .init(name: "osx", arch: nil, version: nil), features: nil)]
        #expect(RuleEvaluator.allows(rules, on: linux))
        #expect(!RuleEvaluator.allows(rules, on: RulePlatform(osName: "osx", osArch: "arm64")))
    }

    @Test func osOnlyAllowExcludesOthers() {
        let rules = [Rule(action: .allow, os: .init(name: "osx", arch: nil, version: nil), features: nil)]
        #expect(!RuleEvaluator.allows(rules, on: linux))
    }

    @Test func featuresMustMatch() {
        let rules = [Rule(action: .allow, os: nil, features: ["is_demo_user": true])]
        #expect(!RuleEvaluator.allows(rules, on: linux))
        var demo = linux
        demo.features["is_demo_user"] = true
        #expect(RuleEvaluator.allows(rules, on: demo))
    }

    @Test func versionRegex() {
        let rules = [Rule(action: .allow, os: .init(name: "linux", arch: nil, version: "^6\\."), features: nil)]
        #expect(!RuleEvaluator.allows(rules, on: linux))
        var p = linux
        p.osVersion = "6.1.0"
        #expect(RuleEvaluator.allows(rules, on: p))
    }
}
