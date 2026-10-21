import Foundation
import Testing
@testable import VoxeliumCore

@Suite struct VersionDeleterTests {
    /// 1.20.1 (vanilla) ← loader ← pack, each marked installed; the loader has a world.
    func setUp(_ paths: AppPaths) throws {
        let fm = FileManager.default
        func version(_ id: String, _ json: Data) throws {
            try fm.createDirectory(at: try paths.versionDir(id), withIntermediateDirectories: true)
            try json.write(to: try paths.versionJSON(id))
            try Data().write(to: try paths.versionDir(id).appendingPathComponent(".voxelium-install-complete"))
        }
        func child(_ id: String, of parent: String) -> Data {
            Data(#"{"id":"\#(id)","inheritsFrom":"\#(parent)","mainClass":"x.Main","libraries":[]}"#.utf8)
        }
        try version("1.20.1", Fixture.data("1.20.1"))
        try version("1.20.1-forge-47.4.10", child("1.20.1-forge-47.4.10", of: "1.20.1"))
        try version("My Pack", child("My Pack", of: "1.20.1-forge-47.4.10"))
        let world = try paths.versionDir("1.20.1-forge-47.4.10").appendingPathComponent("saves/Base")
        try fm.createDirectory(at: world, withIntermediateDirectories: true)
        try Data("nbt".utf8).write(to: world.appendingPathComponent("level.dat"))
        // A vanilla world in the shared folder.
        let vanilla = paths.gameDir.appendingPathComponent("saves/Shared")
        try fm.createDirectory(at: vanilla, withIntermediateDirectories: true)
        try Data("nbt".utf8).write(to: vanilla.appendingPathComponent("level.dat"))
    }

    @Test func refusesWhileOthersBuildOnItThenDeletesInOrder() throws {
        let tmp = try TempDir()
        let paths = tmp.paths
        try setUp(paths)
        let deleter = VersionDeleter(paths: paths)
        let installer = GameInstaller(paths: paths)

        #expect(deleter.dependents(of: "1.20.1") == ["1.20.1-forge-47.4.10", "My Pack"])
        #expect(deleter.dependents(of: "1.20.1-forge-47.4.10") == ["My Pack"])
        #expect(deleter.worldCount(of: "1.20.1-forge-47.4.10") == 1)
        #expect(deleter.worldCount(of: "1.20.1") == 0)   // vanilla worlds are shared, not the version's

        #expect(throws: VersionDeleteError.neededBy("1.20.1", ["1.20.1-forge-47.4.10", "My Pack"])) { try deleter.delete("1.20.1") }
        #expect(installer.isInstalled("1.20.1"))

        try deleter.delete("My Pack")
        try deleter.delete("1.20.1-forge-47.4.10")
        #expect(!FileManager.default.fileExists(atPath: try paths.versionDir("1.20.1-forge-47.4.10").path))
        try deleter.delete("1.20.1")
        #expect(!installer.isInstalled("1.20.1"))
        // Shared vanilla worlds stay.
        #expect(FileManager.default.fileExists(atPath: paths.gameDir.appendingPathComponent("saves/Shared/level.dat").path))

        #expect(throws: VersionDeleteError.notInstalled("1.20.1")) { try deleter.delete("1.20.1") }
        #expect(throws: (any Error).self) { try deleter.delete("../config") }
        #expect(VersionDeleteError.neededBy("1.20.1", ["neoforge-21.1.264"]).description
                == "1.20.1 can't be deleted while neoforge-21.1.264 builds on it. Delete that first.")
    }
}
