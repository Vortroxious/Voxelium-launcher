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
        #expect(GameRuntime.lwjglBuild(for: .init(3, 4, 3)) == .v341)
        #expect(GameRuntime.lwjglBuild(for: .init(3, 3, 3)) == .v333)
        #expect(GameRuntime.lwjglBuild(for: nil) == .v333)
    }
}
