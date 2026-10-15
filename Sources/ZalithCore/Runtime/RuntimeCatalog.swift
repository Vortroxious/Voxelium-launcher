import Foundation

/// A Java runtime found on disk, described by its `release` file.
public struct JavaRuntime: Sendable, Equatable {
    public let name: String
    public let home: URL
    public let javaVersion: String
    public let majorVersion: Int
    public let osName: String?
    public let osArch: String?
    /// `lib/server/libjvm.dylib` (macOS/iOS layout), if present.
    public let libjvm: URL?
}

/// Discovers runtimes under `AppPaths.runtimesDir`. Mirrors the idea of
/// ZalithLauncher2's `RuntimesManager` (one directory per runtime with a
/// `release` file), but does not unpack archives yet.
public struct RuntimeCatalog: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public func discover(fileManager: FileManager = .default) -> [JavaRuntime] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.sorted().compactMap { name in
            let home = directory.appendingPathComponent(name, isDirectory: true)
            guard let text = try? String(contentsOf: home.appendingPathComponent("release"), encoding: .utf8) else { return nil }
            let props = Self.parseRelease(text)
            guard let version = props["JAVA_VERSION"], let major = Self.majorVersion(version) else { return nil }
            let jvm = home.appendingPathComponent("lib/server/libjvm.dylib")
            return JavaRuntime(
                name: name, home: home, javaVersion: version, majorVersion: major,
                osName: props["OS_NAME"], osArch: props["OS_ARCH"],
                libjvm: fileManager.fileExists(atPath: jvm.path) ? jvm : nil
            )
        }
    }

    /// Picks the lowest runtime that satisfies `major` exactly, else the
    /// smallest newer one (newer JREs generally run older Minecraft, but
    /// that is a per-version assumption, not a guarantee).
    public func best(forMajor major: Int, in runtimes: [JavaRuntime]) -> JavaRuntime? {
        runtimes.first { $0.majorVersion == major }
            ?? runtimes.filter { $0.majorVersion > major }.min { $0.majorVersion < $1.majorVersion }
    }

    /// Parses `KEY="value"` lines from a JDK `release` file.
    public static func parseRelease(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            out[key] = value
        }
        return out
    }

    /// "1.8.0_402" → 8, "17.0.10" → 17, "21" → 21.
    public static func majorVersion(_ v: String) -> Int? {
        let parts = v.split(separator: ".")
        guard let first = parts.first.flatMap({ Int($0) }) else { return nil }
        if first == 1, parts.count > 1 { return Int(parts[1]) }
        return first
    }
}
