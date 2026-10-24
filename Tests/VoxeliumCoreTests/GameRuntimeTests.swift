import Foundation
import Testing
@testable import VoxeliumCore

@Suite struct GameRuntimeTests {
    @Test func javaSelection() {
        #expect(GameRuntime.java(for: 8) == 8)
        #expect(GameRuntime.java(for: 16) == 17)   // 1.17
        #expect(GameRuntime.java(for: 17) == 17)
        #expect(GameRuntime.java(for: 21) == 21)   // 1.20.5 – 1.21.x
        #expect(GameRuntime.java(for: 25) == 25)   // 26.x
        #expect(GameRuntime.java(for: 26) == nil)
        #expect(GameRuntime.java(for: 21, available: [17]) == nil)
    }

    @Test func modernVersion() throws {
        let v = try VersionInfo.decode(Fixture.data("1.20.1"))
        #expect(GameRuntime.javaMajor(for: v) == 17)
        let lw = GameRuntime.lwjgl(for: v)
        #expect(lw == .init(3, 3, 1))
        #expect(GameRuntime.lwjglBuild(for: lw) == .v333 && !GameRuntime.needsLWJGL2Bridge(lw))
    }

    @Test func legacyVersionUsesJava8AndLWJGL2() throws {
        let v = try VersionInfo.decode(Fixture.data("1.12.2"))
        #expect(GameRuntime.javaMajor(for: v) == 8)
        let lw = GameRuntime.lwjgl(for: v)
        #expect(lw?.major == 2 && lw?.minor == 9)
        #expect(GameRuntime.needsLWJGL2Bridge(lw))
    }

    @Test func lwjgl34UsesTheNewBuild() {
        #expect(GameRuntime.lwjglBuild(for: .init(3, 4, 1)) == .v341)
        #expect(GameRuntime.lwjglBuild(for: .init(3, 4, 2)) == .v341)
        #expect(GameRuntime.lwjglBuild(for: .init(3, 4, 3)) == .v343)   // 26.3: SDL3 + Vulkan
        #expect(GameRuntime.lwjglBuild(for: .init(3, 5, 0)) == .v343)
        #expect(GameRuntime.lwjglBuild(for: .init(3, 3, 3)) == .v333)
        #expect(GameRuntime.lwjglBuild(for: nil) == .v333)
    }

    @Test func minecraft263UsesSDLAndVulkanModules() throws {
        let v = try VersionInfo.decode(Fixture.data("26.3"))
        #expect(GameRuntime.javaMajor(for: v) == 25)
        let lw = GameRuntime.lwjgl(for: v)
        #expect(lw == .init(3, 4, 3) && GameRuntime.lwjglBuild(for: lw) == .v343)
        // Exactly the LWJGL modules 26.3 lists, from the app's 3.4.3 build.
        let listed = Set(v.libraries.compactMap { lib -> String? in
            let c = lib.name.split(separator: ":")
            return c.count >= 3 && c[0] == "org.lwjgl" ? String(c[1]) : nil
        })
        #expect(Set(GameRuntime.sdlVulkanLWJGLModules) == listed)
        #expect(!listed.contains("lwjgl-glfw"))
    }

    @Test func rendererChoicePerVersion() throws {
        // 26.3: SDL3 + its own Vulkan renderer only.
        #expect(RendererChoice.of(try VersionInfo.decode(Fixture.data("26.3"))) == .vulkanOnly)
        // 1.20.1 (Java 17, LWJGL 3.3): MobileGlues or Vulkan through Zink.
        #expect(RendererChoice.of(try VersionInfo.decode(Fixture.data("1.20.1"))) == .mobileGluesOrVulkan)
        // 1.12.2 (Java 8): one launch, as before (gl4es).
        #expect(RendererChoice.of(try VersionInfo.decode(Fixture.data("1.12.2"))) == .single)
        // 26.2: lwjgl-vulkan without SDL, refused by the launcher; one launch with its reason.
        var json = try JSONSerialization.jsonObject(with: Fixture.data("26.3")) as! [String: Any]
        json["libraries"] = (json["libraries"] as! [[String: Any]]).filter { ($0["name"] as! String).hasPrefix("org.lwjgl:lwjgl-sdl:") == false }
        let v262 = try VersionInfo.decode(JSONSerialization.data(withJSONObject: json))
        #expect(GameRuntime.lwjglArtifacts(of: v262).contains("lwjgl-vulkan"))
        #expect(RendererChoice.of(v262) == .single)
    }
}
