import Foundation
import Testing
@testable import VoxeliumCore

@Suite struct AppPathsMigrationTests {
    let fm = FileManager.default

    func write(_ text: String, _ path: String, in base: URL) throws {
        let url = base.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ path: String, in base: URL) throws -> String {
        String(decoding: try Data(contentsOf: base.appendingPathComponent(path)), as: UTF8.self)
    }

    @Test func movesEverythingAndRemovesTheOldRoot() throws {
        let tmp = try TempDir()
        let old = tmp.url.appendingPathComponent("Library/Application Support/Voxelium")
        let new = tmp.url.appendingPathComponent("Documents")
        try write("version", "minecraft/versions/1.21.11/1.21.11.json", in: old)
        try write("world", "minecraft/saves/My World/level.dat", in: old)
        try write("log", "logs/launcher.log", in: old)
        try write("{}", "config/settings.json", in: old)
        try write("[]", "controls/layout.json", in: old)
        try fm.createDirectory(at: old.appendingPathComponent("runtimes/jre21"), withIntermediateDirectories: true)

        let report = try AppPaths.migrateIfNeeded(from: old, to: new)
        #expect(report.moved == ["config", "controls", "logs", "minecraft", "runtimes"])
        #expect(report.kept.isEmpty && report.removedOldRoot)
        #expect(!fm.fileExists(atPath: old.path))
        #expect(try read("minecraft/saves/My World/level.dat", in: new) == "world")
        #expect(try read("minecraft/versions/1.21.11/1.21.11.json", in: new) == "version")
        #expect(fm.fileExists(atPath: new.appendingPathComponent("runtimes/jre21").path))
    }

    @Test func mergesIntoExistingFoldersWithoutOverwriting() throws {
        let tmp = try TempDir()
        let old = tmp.url.appendingPathComponent("old"), new = tmp.url.appendingPathComponent("new")
        try write("old log", "logs/launcher.log", in: old)
        try write("old jvm", "logs/jvm.log", in: old)
        try write("old options", "minecraft/options.txt", in: old)
        try write("mod", "minecraft/versions/fabric/mods/a.jar", in: old)
        // Already in Documents (for example dropped in through Files, or a run cut short).
        try write("new log", "logs/launcher.log", in: new)
        try write("new mod", "minecraft/versions/fabric/mods/b.jar", in: new)
        try write("script", "UniversalJIT26.js", in: new)

        let report = try AppPaths.migrateIfNeeded(from: old, to: new)
        #expect(report.moved == ["logs/jvm.log", "minecraft/options.txt", "minecraft/versions/fabric/mods/a.jar"])
        #expect(report.kept == ["logs/launcher.log"])
        #expect(!report.removedOldRoot)
        #expect(try read("logs/launcher.log", in: new) == "new log")
        #expect(try read("logs/launcher.log", in: old) == "old log")
        #expect(try read("logs/jvm.log", in: new) == "old jvm")
        #expect(try read("minecraft/versions/fabric/mods/a.jar", in: new) == "mod")
        #expect(try read("minecraft/versions/fabric/mods/b.jar", in: new) == "new mod")
        #expect(try read("UniversalJIT26.js", in: new) == "script")
        // Folders emptied by the move are gone; only the conflict is left behind.
        #expect(try fm.contentsOfDirectory(atPath: old.path) == ["logs"])
        #expect(try fm.contentsOfDirectory(atPath: old.appendingPathComponent("logs").path) == ["launcher.log"])
    }

    @Test func secondRunDoesNothing() throws {
        let tmp = try TempDir()
        let old = tmp.url.appendingPathComponent("old"), new = tmp.url.appendingPathComponent("new")
        try write("x", "minecraft/options.txt", in: old)
        #expect(try AppPaths.migrateIfNeeded(from: old, to: new).didAnything)
        let again = try AppPaths.migrateIfNeeded(from: old, to: new)
        #expect(!again.didAnything)
        #expect(try read("minecraft/options.txt", in: new) == "x")
        // Same folder on both sides (nothing to move).
        #expect(!(try AppPaths.migrateIfNeeded(from: new, to: new).didAnything))
    }

    @Test func applicationDefaultIsDocuments() throws {
        let docs = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        #expect(try AppPaths.applicationDefault().root == docs.standardizedFileURL)
        #expect(AppPaths.legacyRoot()?.lastPathComponent == "Voxelium")
    }
}
