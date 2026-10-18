import Foundation

public enum PathError: Error, Equatable, CustomStringConvertible {
    /// A relative path from untrusted metadata tried to escape its base directory.
    case escapesBase(String)
    case empty

    public var description: String {
        switch self {
        case .escapesBase(let p): "Path escapes its base directory: \(p)"
        case .empty: "Empty relative path"
        }
    }
}

/// The launcher's on-disk layout. Everything lives below `root`, which on iOS
/// is the app's Documents directory (shown in Files → On My iPhone → Voxelium)
/// and in tests a temp directory.
///
/// Layout follows the vanilla `.minecraft` structure so version JSONs and
/// library paths from Mojang can be used unchanged:
///   root/minecraft/{versions,libraries,assets/{indexes,objects},saves,resourcepacks,…}
///   root/minecraft/versions/<id>/   (also the game folder of a modded version or modpack)
///   root/runtimes/<name>/   (Java runtimes)
///   root/logs/, root/config/, root/controls/
public struct AppPaths: Sendable, Equatable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// Default location for the running app: its Documents directory, so the
    /// Files app can reach worlds, mods, packs and logs.
    public static func applicationDefault(fileManager: FileManager = .default) throws -> AppPaths {
        AppPaths(root: try fileManager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
    }

    /// Where 0.1.0 kept its data (Application Support/Voxelium, hidden from Files);
    /// `migrateIfNeeded(from:to:)` moves it to `applicationDefault`.
    public static func legacyRoot(fileManager: FileManager = .default) -> URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Voxelium", isDirectory: true)
    }

    public var gameDir: URL { root.appendingPathComponent("minecraft", isDirectory: true) }
    public var versionsDir: URL { gameDir.appendingPathComponent("versions", isDirectory: true) }
    public var librariesDir: URL { gameDir.appendingPathComponent("libraries", isDirectory: true) }
    public var assetsDir: URL { gameDir.appendingPathComponent("assets", isDirectory: true) }
    public var assetIndexesDir: URL { assetsDir.appendingPathComponent("indexes", isDirectory: true) }
    public var assetObjectsDir: URL { assetsDir.appendingPathComponent("objects", isDirectory: true) }
    public var runtimesDir: URL { root.appendingPathComponent("runtimes", isDirectory: true) }
    public var logsDir: URL { root.appendingPathComponent("logs", isDirectory: true) }
    public var configDir: URL { root.appendingPathComponent("config", isDirectory: true) }
    /// On-screen control layouts (controls/layout.json).
    public var controlsDir: URL { root.appendingPathComponent("controls", isDirectory: true) }

    public func versionDir(_ id: String) throws -> URL { try resolve(id, in: versionsDir) }
    /// A modded version's own game folder (mods, config, saves, options), as
    /// ZalithLauncher2's version isolation does; vanilla versions share `gameDir`.
    public func instanceDir(_ id: String) throws -> URL { try versionDir(id) }
    public func versionJSON(_ id: String) throws -> URL { try versionDir(id).appendingPathComponent("\(id).json") }
    public func clientJar(_ id: String) throws -> URL { try versionDir(id).appendingPathComponent("\(id).jar") }
    public func nativesDir(_ id: String) throws -> URL { try versionDir(id).appendingPathComponent("natives", isDirectory: true) }
    public func library(_ relativePath: String) throws -> URL { try resolve(relativePath, in: librariesDir) }
    public func assetIndex(_ id: String) throws -> URL { try resolve("\(id).json", in: assetIndexesDir) }

    public func assetObject(hash: String) throws -> URL {
        guard hash.count >= 2 else { throw PathError.escapesBase(hash) }
        return try resolve("\(hash.prefix(2))/\(hash)", in: assetObjectsDir)
    }

    /// Creates every top-level directory of the layout.
    public func createLayout(fileManager: FileManager = .default) throws {
        for dir in [versionsDir, librariesDir, assetIndexesDir, assetObjectsDir, runtimesDir, logsDir, configDir] {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Joins a relative path that came from downloaded metadata onto `base`,
    /// rejecting absolute paths and `..` traversal.
    public func resolve(_ relative: String, in base: URL) throws -> URL {
        guard !relative.isEmpty else { throw PathError.empty }
        if relative.hasPrefix("/") || relative.hasPrefix("~") { throw PathError.escapesBase(relative) }
        let components = relative.split(separator: "/", omittingEmptySubsequences: true)
        if components.contains(where: { $0 == ".." || $0 == "." }) || relative.contains("\\") || relative.contains("\0") {
            throw PathError.escapesBase(relative)
        }
        let url = components.reduce(base) { $0.appendingPathComponent(String($1)) }.standardizedFileURL
        guard url.path.hasPrefix(base.standardizedFileURL.path + "/") else { throw PathError.escapesBase(relative) }
        return url
    }
}
