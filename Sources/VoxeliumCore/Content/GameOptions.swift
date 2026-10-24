import Foundation

/// Minecraft's `options.txt` in a game folder (`key:value` lines). Only the values the
/// launcher needs are read or changed; every other line is kept as the game wrote it.
public struct GameOptions: Sendable, Equatable {
    public let file: URL
    public private(set) var values: [String: String]

    public init(gameDirectory: URL) {
        file = gameDirectory.appendingPathComponent("options.txt")
        values = Self.parse((try? String(contentsOf: file, encoding: .utf8)) ?? "")
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: file.path) }

    public func int(_ key: String) -> Int? { values[key].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }

    /// Sets `key` to `value`, keeping the rest of the file.
    public mutating func set(_ key: String, _ value: String) throws {
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        if let i = lines.firstIndex(where: { $0.hasPrefix(key + ":") }) {
            lines[i] = "\(key):\(value)"
        } else {
            lines.append("\(key):\(value)")
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        values[key] = value
    }

    /// For "Large interface": Minecraft's GUI Scale back to Auto (`guiScale:0`), so it uses
    /// the biggest interface the resolution allows. A fixed scale (e.g. `guiScale:2`, kept
    /// from 50%) stops the hotbar from growing (seen on the iPhone, 2026-10-24). Returns
    /// the scale that was replaced, or nil when it was already Auto or unset.
    @discardableResult
    public mutating func useAutoGUIScale() throws -> Int? {
        guard let old = int("guiScale"), old != 0 else { return nil }
        try set("guiScale", "0")
        return old
    }

    static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            out[String(line[..<colon])] = String(line[line.index(after: colon)...])
        }
        return out
    }
}

/// Advice before starting a version with a shader pack on: iPhones ran out of memory
/// with shaders at render distance 16 (killed at the 3376 MB limit) but were stable at
/// 8 (2.2 GB), measured 2026-10-18.
public struct ShaderLaunchAdvice: Sendable, Equatable {
    public let shaderPack: String
    public let renderDistance: Int
    public static let comfortableRenderDistance = 10
    public static let suggestedRenderDistance = 8

    /// Advice for a game folder, or nil when shaders are off or the distance is fine.
    public static func check(gameDirectory: URL) -> ShaderLaunchAdvice? {
        let iris = IrisSettings(gameDirectory: gameDirectory)
        guard iris.exists, iris.shadersEnabled, let pack = iris.shaderPack else { return nil }
        guard let distance = GameOptions(gameDirectory: gameDirectory).int("renderDistance"),
              distance > comfortableRenderDistance else { return nil }
        return ShaderLaunchAdvice(shaderPack: pack, renderDistance: distance)
    }

    /// Lowers the render distance to the suggested value (and the simulation distance
    /// with it when it is higher).
    public static func applySuggestion(gameDirectory: URL) throws {
        var options = GameOptions(gameDirectory: gameDirectory)
        try options.set("renderDistance", String(suggestedRenderDistance))
        if let sim = options.int("simulationDistance"), sim > suggestedRenderDistance {
            try options.set("simulationDistance", String(suggestedRenderDistance))
        }
    }
}
