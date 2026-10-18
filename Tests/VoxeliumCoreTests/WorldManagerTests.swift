import Foundation
import Testing
@testable import VoxeliumCore

@Suite struct WorldManagerTests {
    let fm = FileManager.default

    /// A small Java world: level.dat and one region file.
    func makeWorld(_ name: String, in base: URL, level: String = "level") throws -> URL {
        let world = base.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: world.appendingPathComponent("region"), withIntermediateDirectories: true)
        try Data(level.utf8).write(to: world.appendingPathComponent("level.dat"))
        try Data(repeating: 7, count: 10_000).write(to: world.appendingPathComponent("region/r.0.0.mca"))
        return world
    }

    /// Zips `items` (relative to `dir`) with /usr/bin/zip (deflated, with folder entries).
    func zip(_ items: [String], in dir: URL, to out: URL) throws -> URL {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = dir
        p.arguments = ["-qr", out.path] + items
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        return out
    }

    /// A stored (uncompressed) zip with arbitrary entry names, for paths `zip` won't write.
    func storedZip(_ entries: [(String, Data)], to out: URL) throws -> URL {
        var body = Data(), central = Data()
        func put(_ d: inout Data, _ values: [(Int, Int)]) {
            for (v, size) in values { for i in 0 ..< size { d.append(UInt8((v >> (8 * i)) & 0xFF)) } }
        }
        for (name, data) in entries {
            let n = Data(name.utf8), offset = body.count
            put(&body, [(0x04034b50, 4), (20, 2), (0, 2), (0, 2), (0, 2), (0, 2), (0, 4), (data.count, 4), (data.count, 4), (n.count, 2), (0, 2)])
            body.append(n)
            body.append(data)
            put(&central, [(0x02014b50, 4), (20, 2), (20, 2), (0, 2), (0, 2), (0, 2), (0, 2), (0, 4), (data.count, 4), (data.count, 4),
                           (n.count, 2), (0, 2), (0, 2), (0, 2), (0, 2), (0, 4), (offset, 4)])
            central.append(n)
        }
        var eocd = Data()
        put(&eocd, [(0x06054b50, 4), (0, 2), (0, 2), (entries.count, 2), (entries.count, 2), (central.count, 4), (body.count, 4), (0, 2)])
        try (body + central + eocd).write(to: out)
        return out
    }

    @Test func importsAFolder() throws {
        let tmp = try TempDir()
        let source = try makeWorld("Survival", in: tmp.url.appendingPathComponent("src"))
        let manager = WorldManager(gameDirectory: tmp.url.appendingPathComponent("game"))
        let world = try manager.importFolder(source)
        #expect(world.name == "Survival" && world.size == 10_005)
        #expect(fm.fileExists(atPath: manager.saves.appendingPathComponent("Survival/region/r.0.0.mca").path))
        #expect(fm.fileExists(atPath: source.path))
        #expect(manager.list().map(\.name) == ["Survival"])
        #expect(try fm.contentsOfDirectory(atPath: manager.saves.path) == ["Survival"])
    }

    @Test func importsZipsWithTheWorldAtTheTopOrInASubfolder() throws {
        let tmp = try TempDir()
        let src = tmp.url.appendingPathComponent("src")
        _ = try makeWorld("Creative", in: src, level: "creative")
        try fm.createDirectory(at: src.appendingPathComponent("Backups"), withIntermediateDirectories: true)
        _ = try makeWorld("Backups/Island", in: src, level: "island")
        try Data("readme".utf8).write(to: src.appendingPathComponent("Backups/README.txt"))
        let manager = WorldManager(gameDirectory: tmp.url.appendingPathComponent("game"))

        // level.dat at the top: the world is named after the zip.
        let top = try zip(["."], in: src.appendingPathComponent("Creative"), to: tmp.url.appendingPathComponent("My Creative.zip"))
        let a = try manager.importZip(top)
        #expect(a.name == "My Creative")
        #expect(try String(contentsOf: a.url.appendingPathComponent("level.dat"), encoding: .utf8) == "creative")
        #expect(try Data(contentsOf: a.url.appendingPathComponent("region/r.0.0.mca")) == Data(repeating: 7, count: 10_000))

        // Inside a subfolder: named after that folder, files beside it are left out.
        let nested = try zip(["Backups"], in: src, to: tmp.url.appendingPathComponent("backup.zip"))
        let b = try manager.importZip(nested)
        #expect(b.name == "Island")
        #expect(try String(contentsOf: b.url.appendingPathComponent("level.dat"), encoding: .utf8) == "island")
        #expect(!fm.fileExists(atPath: b.url.appendingPathComponent("README.txt").path))
        #expect(Set(manager.list().map(\.name)) == ["My Creative", "Island"])
    }

    @Test func nameClashGetsANumber() throws {
        let tmp = try TempDir()
        let source = try makeWorld("World", in: tmp.url.appendingPathComponent("src"))
        let manager = WorldManager(gameDirectory: tmp.url.appendingPathComponent("game"))
        let first = try manager.importFolder(source)
        try Data("played".utf8).write(to: first.url.appendingPathComponent("level.dat"))
        #expect(try manager.importFolder(source).name == "World (2)")
        #expect(try manager.importFolder(source).name == "World (3)")
        // The first copy was not touched.
        #expect(try String(contentsOf: first.url.appendingPathComponent("level.dat"), encoding: .utf8) == "played")
        #expect(manager.uniqueName(for: "../x") == "-x" && manager.uniqueName(for: " ") == "World (4)")
    }

    @Test func refusesNonWorldsAndUnsafeZips() throws {
        let tmp = try TempDir()
        let manager = WorldManager(gameDirectory: tmp.url.appendingPathComponent("game"))
        let noLevel = try storedZip([("World/region/r.0.0.mca", Data("x".utf8))], to: tmp.url.appendingPathComponent("a.zip"))
        #expect(throws: WorldError.notAJavaWorld("a.zip")) { try manager.importZip(noLevel) }

        let evil = try storedZip([("level.dat", Data("l".utf8)), ("../evil", Data("e".utf8))], to: tmp.url.appendingPathComponent("b.zip"))
        #expect(throws: WorldError.unsafePath("../evil")) { try manager.importZip(evil) }
        let absolute = try storedZip([("level.dat", Data("l".utf8)), ("/tmp/evil", Data("e".utf8))], to: tmp.url.appendingPathComponent("c.zip"))
        #expect(throws: WorldError.unsafePath("/tmp/evil")) { try manager.importZip(absolute) }
        #expect(!fm.fileExists(atPath: tmp.url.appendingPathComponent("evil").path))

        let bedrock = try storedZip([("level.dat", Data("l".utf8)), ("db/CURRENT", Data("c".utf8))], to: tmp.url.appendingPathComponent("d.zip"))
        #expect(throws: WorldError.bedrockWorld("d.zip")) { try manager.importZip(bedrock) }
        let notZip = tmp.url.appendingPathComponent("e.zip")
        try Data("not a zip".utf8).write(to: notZip)
        #expect(throws: WorldError.unsupportedZip("it is not a zip file")) { try manager.importZip(notZip) }

        let folder = tmp.url.appendingPathComponent("Empty")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(throws: WorldError.notAJavaWorld("Empty")) { try manager.importFolder(folder) }
        // Nothing half-imported is left behind.
        #expect(manager.list().isEmpty)
        #expect(((try? fm.contentsOfDirectory(atPath: manager.saves.path)) ?? []).isEmpty)
    }

    @Test func listsNewestFirstAndDeletes() throws {
        let tmp = try TempDir()
        let game = tmp.url.appendingPathComponent("game")
        let saves = game.appendingPathComponent("saves")
        for (name, age) in [("Old", 300.0), ("New", 10.0), ("Middle", 100.0)] {
            let w = try makeWorld(name, in: saves)
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: w.appendingPathComponent("level.dat").path)
        }
        try fm.createDirectory(at: saves.appendingPathComponent("NotAWorld"), withIntermediateDirectories: true)
        let manager = WorldManager(gameDirectory: game)
        let worlds = manager.list()
        #expect(worlds.map(\.name) == ["New", "Middle", "Old"])

        try manager.delete(worlds[1])
        #expect(manager.list().map(\.name) == ["New", "Old"])
        let outside = WorldItem(name: "x", url: tmp.url.appendingPathComponent("x"), lastPlayed: nil, size: 0)
        #expect(throws: WorldError.self) { try manager.delete(outside) }
    }
}
