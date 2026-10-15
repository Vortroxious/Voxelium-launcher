import Foundation

/// Launcher settings persisted as JSON. Never stores credentials; account
/// tokens belong in the Keychain (not implemented yet).
public struct LauncherSettings: Codable, Sendable, Equatable {
    public var selectedVersion: String?
    public var playerName: String
    public var maxMemoryMB: Int
    public var showSnapshots: Bool
    public var downloadConcurrency: Int

    public init(selectedVersion: String? = nil, playerName: String = "Player", maxMemoryMB: Int = 2048, showSnapshots: Bool = false, downloadConcurrency: Int = 8) {
        self.selectedVersion = selectedVersion
        self.playerName = playerName
        self.maxMemoryMB = maxMemoryMB
        self.showSnapshots = showSnapshots
        self.downloadConcurrency = downloadConcurrency
    }

    /// Tolerates missing keys so older files keep loading after new fields are added.
    public init(from decoder: Decoder) throws {
        let d = LauncherSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selectedVersion = try c.decodeIfPresent(String.self, forKey: .selectedVersion)
        playerName = try c.decodeIfPresent(String.self, forKey: .playerName) ?? d.playerName
        maxMemoryMB = try c.decodeIfPresent(Int.self, forKey: .maxMemoryMB) ?? d.maxMemoryMB
        showSnapshots = try c.decodeIfPresent(Bool.self, forKey: .showSnapshots) ?? d.showSnapshots
        downloadConcurrency = try c.decodeIfPresent(Int.self, forKey: .downloadConcurrency) ?? d.downloadConcurrency
    }
}

public struct SettingsStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }
    public init(paths: AppPaths) { self.url = paths.configDir.appendingPathComponent("settings.json") }

    /// Returns defaults when the file is missing. A corrupt file is moved
    /// aside (settings.json.corrupt) and defaults are returned.
    public func load(log: Logger = .shared) -> LauncherSettings {
        guard let data = try? Data(contentsOf: url) else { return LauncherSettings() }
        do {
            return try JSONDecoder().decode(LauncherSettings.self, from: data)
        } catch {
            log.error("settings", "Corrupt settings file, resetting: \(error)")
            let aside = url.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: url, to: aside)
            return LauncherSettings()
        }
    }

    public func save(_ settings: LauncherSettings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(settings).write(to: url, options: .atomic)
    }
}
