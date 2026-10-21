import Foundation

public enum VersionDeleteError: Error, Equatable, CustomStringConvertible {
    case neededBy(String, [String])
    case notInstalled(String)

    public var description: String {
        switch self {
        case .neededBy(let id, let others):
            "\(id) can't be deleted while \(others.joined(separator: ", ")) \(others.count == 1 ? "builds" : "build") on it. Delete \(others.count == 1 ? "that" : "those") first."
        case .notInstalled(let id): "\(id) is not installed."
        }
    }
}

/// Deletes an installed version: its `versions/<id>/` folder. For a modded version or
/// modpack that folder is also its game folder (worlds, mods, config, options), so all
/// of that goes with it; vanilla versions share `minecraft/` (worlds in
/// `minecraft/saves`), which is left alone. Libraries and assets are shared between
/// versions and stay, so reinstalling is quick.
public struct VersionDeleter: Sendable {
    public let paths: AppPaths

    public init(paths: AppPaths) { self.paths = paths }

    /// Other versions whose inheritance chain includes `id` (a loader on its Minecraft
    /// version, a modpack on its loader), sorted.
    public func dependents(of id: String) -> [String] {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: paths.versionsDir.path)) ?? []
        let resolver = VersionResolver(paths: paths)
        return ids.filter { other in
            other != id && ((try? resolver.resolve(other))?.chain.dropFirst().contains(id) ?? false)
        }.sorted()
    }

    /// What would be lost with a modded version: its worlds (folders with a level.dat).
    public func worldCount(of id: String) -> Int {
        guard let r = try? VersionResolver(paths: paths).resolve(id), r.isModded,
              let dir = try? paths.instanceDir(id) else { return 0 }
        return WorldManager(gameDirectory: dir).list().count
    }

    /// Refuses while another version builds on `id`. The install marker goes first, so
    /// an interrupted delete never leaves a half-deleted version listed as installed.
    public func delete(_ id: String) throws {
        let dir = try paths.versionDir(id)   // rejects ids that escape versions/
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { throw VersionDeleteError.notInstalled(id) }
        let others = dependents(of: id)
        guard others.isEmpty else { throw VersionDeleteError.neededBy(id, others) }
        try? fm.removeItem(at: dir.appendingPathComponent(".voxelium-install-complete"))
        try fm.removeItem(at: dir)
    }
}
