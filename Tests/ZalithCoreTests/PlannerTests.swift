import Foundation
import Testing
@testable import ZalithCore

@Suite struct PlannerTests {
    // Expected counts were computed independently with a Python script over
    // the same fixtures (see docs/ENGINEERING_LOG.md, 2026-10-15).
    @Test func classpathLibrariesForModernVersion() throws {
        let tmp = try TempDir()
        let v = try VersionInfo.decode(Fixture.data("1.20.1"))
        let libs = GameFilePlanner(paths: tmp.paths).classpathLibraries(of: v)
        #expect(libs.count == 38)
        #expect(libs.allSatisfy { !$0.name.contains("org.lwjgl") && !$0.isNative })
        #expect(libs.first?.name == "com.github.oshi:oshi-core:6.2.2")
    }

    @Test func classpathLibrariesForLegacyVersion() throws {
        let tmp = try TempDir()
        let v = try VersionInfo.decode(Fixture.data("1.12.2"))
        #expect(GameFilePlanner(paths: tmp.paths).classpathLibraries(of: v).count == 29)
    }

    @Test func laterDuplicateLibraryWins() throws {
        let tmp = try TempDir()
        let json = #"{"id":"x","mainClass":"M","libraries":[{"name":"a:b:1"},{"name":"c:d:1"},{"name":"a:b:2"}]}"#
        let v = try VersionInfo.decode(Data(json.utf8))
        let names = GameFilePlanner(paths: tmp.paths).classpathLibraries(of: v).map(\.name)
        #expect(names == ["a:b:2", "c:d:1"])
    }

    @Test func libraryWithoutDownloadsDerivesURLFromMavenRepo() throws {
        let json = #"{"name":"net.fabricmc:fabric-loader:0.16.0","url":"https://maven.fabricmc.net/"}"#
        let lib = try JSONDecoder().decode(Library.self, from: Data(json.utf8))
        #expect(lib.artifact?.url.absoluteString == "https://maven.fabricmc.net/net/fabricmc/fabric-loader/0.16.0/fabric-loader-0.16.0.jar")
        #expect(lib.artifact?.sha1 == nil)
    }

    @Test func installItemsIncludeClientIndexAndLogging() throws {
        let tmp = try TempDir()
        let v = try VersionInfo.decode(Fixture.data("1.20.1"))
        let items = try GameFilePlanner(paths: tmp.paths).installItems(for: v)
        #expect(items.count == 38 + 3)
        let client = try #require(items.first { $0.destination.lastPathComponent == "1.20.1.jar" })
        #expect(client.sha1 == "0c3ec587af28e5a785c0b4a7b8a30f9a8f78f838")
        #expect(items.contains { $0.destination.path.hasSuffix("assets/indexes/5.json") })
        #expect(items.allSatisfy { $0.destination.path.hasPrefix(tmp.paths.root.path) })
    }

    @Test func assetItemsUseHashLayout() throws {
        let tmp = try TempDir()
        let idx = try AssetIndex.decode(Fixture.data("assetindex-5"))
        let items = try GameFilePlanner(paths: tmp.paths).assetItems(for: idx)
        #expect(items.count == 3575)
        let one = try #require(items.first)
        let hash = try #require(one.sha1)
        #expect(one.destination.path.hasSuffix("assets/objects/\(hash.prefix(2))/\(hash)"))
    }

    @Test func launchPlanModern() throws {
        let tmp = try TempDir()
        let v = try VersionInfo.decode(Fixture.data("1.20.1"))
        let plan = try LaunchPlanner(paths: tmp.paths).plan(version: v, identity: OfflineIdentity.identity(for: "Steve"))
        #expect(plan.mainClass == "net.minecraft.client.main.Main")
        #expect(plan.requiredJavaMajor == 17)
        #expect(plan.classpath.count == 39)
        #expect(plan.missingFiles.count == 39)
        #expect(!plan.jvmArguments.contains("-XstartOnFirstThread"))
        let joined = (plan.jvmArguments + plan.gameArguments).joined(separator: " ")
        #expect(!joined.contains("${"))
        #expect(plan.gameArguments.contains("Steve"))
        #expect(!plan.gameArguments.contains("--demo"))
        #expect(!plan.gameArguments.contains("--width"))
        #expect(plan.jvmArguments.contains { $0.hasPrefix("-Dlog4j.configurationFile=") })
    }

    @Test func launchPlanCustomResolution() throws {
        let tmp = try TempDir()
        let v = try VersionInfo.decode(Fixture.data("1.20.1"))
        let plan = try LaunchPlanner(paths: tmp.paths).plan(version: v, identity: OfflineIdentity.identity(for: "Steve"), resolution: (1280, 720))
        let i = try #require(plan.gameArguments.firstIndex(of: "--width"))
        #expect(plan.gameArguments[i + 1] == "1280")
    }

    @Test func launchPlanLegacy() throws {
        let tmp = try TempDir()
        let v = try VersionInfo.decode(Fixture.data("1.12.2"))
        let plan = try LaunchPlanner(paths: tmp.paths).plan(version: v, identity: OfflineIdentity.identity(for: "Steve"))
        #expect(plan.requiredJavaMajor == 8)
        #expect(plan.jvmArguments.contains("-cp"))
        #expect(!plan.gameArguments.joined().contains("${"))
    }

    @Test func modLoaderProfilesAreRejectedExplicitly() throws {
        let tmp = try TempDir()
        let v = try VersionInfo.decode(Data(#"{"id":"fabric","inheritsFrom":"1.20.1","mainClass":"M","libraries":[]}"#.utf8))
        #expect(throws: LaunchPlanError.inheritanceNotSupported("fabric")) {
            try LaunchPlanner(paths: tmp.paths).plan(version: v, identity: OfflineIdentity.identity(for: "Steve"))
        }
    }

    @Test func substitutionKeepsUnknownPlaceholders() {
        #expect(LaunchPlanner.substitute("a${x}b${y}c", ["x": "1"]) == "a1b${y}c")
        #expect(LaunchPlanner.substitute("${unterminated", [:]) == "${unterminated")
        #expect(LaunchPlanner.substitute("plain", [:]) == "plain")
    }
}

@Suite struct IdentityTests {
    // Vectors computed with java.util.UUID.nameUUIDFromBytes (JDK 26) — the
    // same function vanilla Minecraft uses for offline UUIDs.
    @Test func offlineUUIDMatchesJava() {
        #expect(OfflineIdentity.uuid(for: "Notch").uuidString.lowercased() == "b50ad385-829d-3141-a216-7e7d7539ba7f")
        #expect(OfflineIdentity.uuid(for: "Player").uuidString.lowercased() == "a01e3843-e521-3998-958a-f459800e4d11")
    }

    @Test func nameValidation() {
        #expect(OfflineIdentity.isValidName("Steve_01"))
        #expect(!OfflineIdentity.isValidName("ab"))
        #expect(!OfflineIdentity.isValidName("has space"))
        #expect(!OfflineIdentity.isValidName("ñame"))
        #expect(!OfflineIdentity.isValidName(String(repeating: "a", count: 17)))
    }
}
