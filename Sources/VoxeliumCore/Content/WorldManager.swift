import Foundation

/// One Java Edition world: a folder in `saves` holding `level.dat`.
public struct WorldItem: Sendable, Equatable, Identifiable {
    public var id: String { url.path }
    /// The folder name, which Minecraft shows under the world's title.
    public let name: String
    public let url: URL
    /// When `level.dat` was last written (Minecraft saves it on every exit).
    public let lastPlayed: Date?
    public let size: Int64
}

public enum WorldError: Error, Equatable, CustomStringConvertible {
    case notAJavaWorld(String)
    case bedrockWorld(String)
    case unsafePath(String)
    case unsupportedZip(String)

    public var description: String {
        switch self {
        case .notAJavaWorld(let name):
            "\(name) is not a Minecraft Java world (there is no level.dat in it)."
        case .bedrockWorld(let name):
            "\(name) is a Bedrock Edition world. Voxelium runs Java Edition, which can't open Bedrock worlds."
        case .unsafePath(let entry):
            "The zip was refused because one of its files points outside the world folder (\(entry))."
        case .unsupportedZip(let why):
            "This zip can't be read: \(why). Unzip it in Files and import the folder instead."
        }
    }
}

/// The worlds of one game folder (`minecraft/` for vanilla, `minecraft/versions/<id>/`
/// for a modded version): list, import a folder or a .zip, delete. Imports never
/// overwrite: a clashing name gets " (2)", " (3)" …
public struct WorldManager: Sendable {
    public let gameDirectory: URL
    public var saves: URL { gameDirectory.appendingPathComponent("saves", isDirectory: true) }

    /// Region files are a few MB; anything this large in one entry is not a world.
    static let entryLimit = 1 << 30

    public init(gameDirectory: URL) {
        self.gameDirectory = gameDirectory.standardizedFileURL
    }

    /// Worlds in `saves`, most recently played first.
    public func list(fileManager fm: FileManager = .default) -> [WorldItem] {
        let names = (try? fm.contentsOfDirectory(atPath: saves.path)) ?? []
        return names.compactMap { name -> WorldItem? in
            guard !name.hasPrefix(".") else { return nil }
            return item(at: saves.appendingPathComponent(name, isDirectory: true), fileManager: fm)
        }
        .sorted { a, b in
            switch (a.lastPlayed, b.lastPlayed) {
            case let (x?, y?) where x != y: x > y
            case (_?, nil): true
            case (nil, _?): false
            default: a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    /// Copies a world folder (the one holding `level.dat`) into `saves`.
    @discardableResult
    public func importFolder(_ url: URL, fileManager fm: FileManager = .default) throws -> WorldItem {
        let name = url.lastPathComponent
        if url.pathExtension.lowercased() == "mcworld" { throw WorldError.bedrockWorld(name) }
        guard fm.fileExists(atPath: url.appendingPathComponent("level.dat").path) else {
            throw WorldError.notAJavaWorld(name)
        }
        if Self.isBedrockLayout(fm.fileExists(atPath: url.appendingPathComponent("db").path),
                                hasRegion: fm.fileExists(atPath: url.appendingPathComponent("region").path)) {
            throw WorldError.bedrockWorld(name)
        }
        return try stage(fileManager: fm) { staging in
            try fm.copyItem(at: url, to: staging)
        } finish: { staging in
            try place(staging, as: name, fileManager: fm)
        }
    }

    /// Extracts the world in a .zip (at its top level or in a subfolder) into `saves`.
    /// Only entries below the shallowest `level.dat` are extracted; any entry with an
    /// absolute or `..` path makes the whole zip refused.
    @discardableResult
    public func importZip(_ url: URL, fileManager fm: FileManager = .default) throws -> WorldItem {
        let zipName = url.deletingPathExtension().lastPathComponent
        if url.pathExtension.lowercased() == "mcworld" { throw WorldError.bedrockWorld(url.lastPathComponent) }
        let reader: ZipReader
        do { reader = try ZipReader(url: url) } catch { throw Self.zipError(error) }

        let checker = AppPaths(root: saves)
        let probe = saves.appendingPathComponent("probe", isDirectory: true)
        for e in reader.entries {
            do { _ = try checker.resolve(e.name, in: probe) } catch { throw WorldError.unsafePath(e.name) }
        }

        let files = reader.entries.filter { !$0.name.hasSuffix("/") && !$0.name.hasPrefix("__MACOSX/") }
        guard let levelDat = files.filter({ $0.name == "level.dat" || $0.name.hasSuffix("/level.dat") })
            .min(by: { $0.name.split(separator: "/").count < $1.name.split(separator: "/").count }) else {
            throw WorldError.notAJavaWorld(url.lastPathComponent)
        }
        let prefix = String(levelDat.name.dropLast("level.dat".count))
        let world = files.filter { $0.name.hasPrefix(prefix) }
        let relative = world.map { String($0.name.dropFirst(prefix.count)) }
        if Self.isBedrockLayout(relative.contains { $0.hasPrefix("db/") }, hasRegion: relative.contains { $0.hasPrefix("region/") }) {
            throw WorldError.bedrockWorld(url.lastPathComponent)
        }
        let name = prefix.isEmpty ? zipName : String(prefix.dropLast().split(separator: "/").last ?? Substring(zipName))

        return try stage(fileManager: fm) { staging in
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            let writer = AppPaths(root: staging)
            for (entry, rel) in zip(world, relative) {
                let dest: URL
                do { dest = try writer.resolve(rel, in: staging) } catch { throw WorldError.unsafePath(entry.name) }
                let data: Data
                do {
                    guard let d = try read(entry.name, from: reader) else { throw WorldError.unsupportedZip("\(entry.name) is missing") }
                    data = d
                } catch let e as WorldError { throw e } catch { throw Self.zipError(error) }
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: dest)
            }
        } finish: { staging in
            try place(staging, as: name, fileManager: fm)
        }
    }

    /// Deletes a world folder (only ones directly inside `saves`).
    public func delete(_ world: WorldItem, fileManager fm: FileManager = .default) throws {
        guard world.url.standardizedFileURL.deletingLastPathComponent().path == saves.standardizedFileURL.path else {
            throw WorldError.unsafePath(world.url.path)
        }
        try fm.removeItem(at: world.url)
    }

    /// "World", or "World (2)", "World (3)" … if that name is taken in `saves`.
    public func uniqueName(for proposed: String, fileManager fm: FileManager = .default) -> String {
        var base = proposed.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasPrefix(".") { base.removeFirst() }
        if base.isEmpty { base = "World" }
        var candidate = base, n = 2
        while fm.fileExists(atPath: saves.appendingPathComponent(candidate).path) {
            candidate = "\(base) (\(n))"
            n += 1
        }
        return candidate
    }

    // MARK: - Helpers

    private func read(_ name: String, from reader: ZipReader) throws -> Data? {
        try autoreleasepool { try reader.read(name, limit: Self.entryLimit) }
    }

    /// Builds the world in a hidden folder inside `saves` first, so a failed import
    /// leaves nothing half-copied behind.
    private func stage(fileManager fm: FileManager, _ build: (URL) throws -> Void,
                       finish: (URL) throws -> WorldItem) throws -> WorldItem {
        try fm.createDirectory(at: saves, withIntermediateDirectories: true)
        let staging = saves.appendingPathComponent(".importing-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try build(staging)
        return try finish(staging)
    }

    private func place(_ staging: URL, as name: String, fileManager fm: FileManager) throws -> WorldItem {
        let dest = saves.appendingPathComponent(uniqueName(for: name, fileManager: fm), isDirectory: true)
        try fm.moveItem(at: staging, to: dest)
        guard let item = item(at: dest, fileManager: fm) else { throw WorldError.notAJavaWorld(name) }
        return item
    }

    private func item(at url: URL, fileManager fm: FileManager) -> WorldItem? {
        var dir: ObjCBool = false
        let level = url.appendingPathComponent("level.dat")
        guard fm.fileExists(atPath: url.path, isDirectory: &dir), dir.boolValue, fm.fileExists(atPath: level.path) else { return nil }
        let modified = (try? fm.attributesOfItem(atPath: level.path))?[.modificationDate] as? Date
        return WorldItem(name: url.lastPathComponent, url: url, lastPlayed: modified, size: Self.size(of: url, fileManager: fm))
    }

    static func size(of url: URL, fileManager fm: FileManager) -> Int64 {
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
        }
        return total
    }

    /// Bedrock worlds also have a level.dat, but keep chunks in a LevelDB `db/` folder.
    static func isBedrockLayout(_ hasDB: Bool, hasRegion: Bool) -> Bool { hasDB && !hasRegion }

    static func zipError(_ error: Error) -> WorldError {
        switch error as? ZipReader.ZipError {
        case .notAZip?: .unsupportedZip("it is not a zip file")
        case .unsupported(let what)? where what == "ZIP64": .unsupportedZip("it is over 4 GB or holds over 65,535 files (ZIP64)")
        case .unsupported(let what)?: .unsupportedZip(what)
        case .corrupt?: .unsupportedZip("it is damaged or password-protected")
        case nil: .unsupportedZip(String(describing: error))
        }
    }
}
