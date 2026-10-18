import Foundation

/// Iris's `config/iris.properties` in a game folder: which shader pack is active
/// and whether shaders are on. Lets the launcher switch shaders off when a pack
/// leaves the game unusable (e.g. a black screen), without opening the game.
public struct IrisSettings: Sendable, Equatable {
    public let file: URL
    /// `enableShaders`; Iris defaults to on when the file says nothing.
    public var shadersEnabled: Bool
    /// `shaderPack`, the active pack's file or folder name.
    public var shaderPack: String?

    public init(gameDirectory: URL) {
        file = gameDirectory.appendingPathComponent("config/iris.properties")
        let values = Self.parse((try? String(contentsOf: file, encoding: .utf8)) ?? "")
        shadersEnabled = values["enableShaders"].map { $0.lowercased() == "true" } ?? true
        shaderPack = values["shaderPack"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Whether Iris has written its settings yet (it does on first start).
    public var exists: Bool { FileManager.default.fileExists(atPath: file.path) }

    /// Writes `enableShaders`, keeping every other line as Iris wrote it.
    public mutating func setShadersEnabled(_ on: Bool) throws {
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let entry = "enableShaders=\(on)"
        if let i = lines.firstIndex(where: { Self.key(of: $0) == "enableShaders" }) {
            lines[i] = entry
        } else {
            lines.append(entry)
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        shadersEnabled = on
    }

    static func key(of line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.hasPrefix("#"), !t.hasPrefix("!") else { return nil }
        guard let sep = t.firstIndex(where: { $0 == "=" || $0 == ":" }) else { return t }
        return t[..<sep].trimmingCharacters(in: .whitespaces)
    }

    /// Java properties, enough for Iris's file: `key=value` lines, comments, and
    /// backslash escapes in values (`\:`, `\=`, `\\`).
    static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            guard let k = key(of: line) else { continue }
            let t = line.trimmingCharacters(in: .whitespaces)
            var value = ""
            if let sep = t.firstIndex(where: { $0 == "=" || $0 == ":" }) {
                var escaped = false
                for c in t[t.index(after: sep)...].drop(while: { $0 == " " }) {
                    if escaped { value.append(c); escaped = false } else if c == "\\" { escaped = true } else { value.append(c) }
                }
            }
            out[k] = value
        }
        return out
    }
}
