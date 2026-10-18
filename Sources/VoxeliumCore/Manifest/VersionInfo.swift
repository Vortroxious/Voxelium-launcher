import Foundation

/// A single file that can be downloaded and checked: `{sha1, size, url}`
/// (plus `path` for library artifacts, `id` for asset index/logging files).
public struct RemoteFile: Codable, Sendable, Equatable {
    public let sha1: String?
    public let size: Int64?
    public let url: URL
    public let path: String?
    public let id: String?
}

/// A version JSON such as `1.20.1.json`.
public struct VersionInfo: Codable, Sendable, Equatable {
    public struct AssetIndexRef: Codable, Sendable, Equatable {
        public let id: String
        public let sha1: String
        public let size: Int64
        public let totalSize: Int64?
        public let url: URL
    }

    public struct JavaVersion: Codable, Sendable, Equatable {
        public let component: String
        public let majorVersion: Int
    }

    public struct Downloads: Codable, Sendable, Equatable {
        public let client: RemoteFile?
        public let server: RemoteFile?
    }

    public struct Arguments: Codable, Sendable, Equatable {
        public let game: [Argument]?
        public let jvm: [Argument]?
    }

    public struct Logging: Codable, Sendable, Equatable {
        public struct Config: Codable, Sendable, Equatable {
            public let argument: String
            public let file: RemoteFile
            public let type: String
        }
        public let client: Config?
    }

    public let id: String
    public let type: VersionType?
    public let mainClass: String
    /// Set by mod loader profiles: the vanilla (or other) version this one builds on.
    /// `VersionResolver` merges the parent in (`merged(onto:)`) before planning.
    public let inheritsFrom: String?
    /// Which version's client jar to run (`versions/<jar>/<jar>.jar`); set when merging.
    public let jar: String?
    public let assets: String?
    public let assetIndex: AssetIndexRef?
    public let downloads: Downloads?
    public let libraries: [Library]
    public let javaVersion: JavaVersion?
    /// Modern (1.13+) argument format.
    public let arguments: Arguments?
    /// Legacy (<1.13) single-string game arguments.
    public let minecraftArguments: String?
    public let logging: Logging?
    public let releaseTime: Date?

    public static func decode(_ data: Data) throws -> VersionInfo {
        try MojangJSON.decoder().decode(VersionInfo.self, from: data)
    }

    /// The version whose client jar is launched: `jar`, else this version's own id.
    public var clientJarID: String { jar ?? id }

    /// This profile with its parent merged in, following the vanilla launcher's
    /// inheritance rules: the child's id, main class and type win; the parent's
    /// libraries come first and the child's after them, so the child's newer copy
    /// wins the planner's later-entry de-duplication (e.g. Fabric's ASM); argument
    /// lists are concatenated parent-first; everything else falls back to the parent,
    /// including the client jar.
    public func merged(onto parent: VersionInfo) -> VersionInfo {
        var args: Arguments?
        if arguments != nil || parent.arguments != nil {
            func join(_ a: [Argument]?, _ b: [Argument]?) -> [Argument]? {
                a == nil && b == nil ? nil : (a ?? []) + (b ?? [])
            }
            args = Arguments(game: join(parent.arguments?.game, arguments?.game),
                             jvm: join(parent.arguments?.jvm, arguments?.jvm))
        }
        return VersionInfo(id: id, type: type ?? parent.type, mainClass: mainClass,
                           inheritsFrom: parent.inheritsFrom, jar: jar ?? parent.clientJarID,
                           assets: assets ?? parent.assets, assetIndex: assetIndex ?? parent.assetIndex,
                           downloads: downloads ?? parent.downloads, libraries: parent.libraries + libraries,
                           javaVersion: javaVersion ?? parent.javaVersion, arguments: args,
                           minecraftArguments: minecraftArguments ?? parent.minecraftArguments,
                           logging: logging ?? parent.logging, releaseTime: releaseTime ?? parent.releaseTime)
    }
}

/// An argument entry: either a plain string or `{rules, value}` where value
/// is a string or an array of strings.
public enum Argument: Codable, Sendable, Equatable {
    case plain(String)
    case conditional(rules: [Rule], values: [String])

    private enum Keys: String, CodingKey { case rules, value }

    public init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            self = .plain(s)
            return
        }
        let c = try decoder.container(keyedBy: Keys.self)
        let rules = try c.decodeIfPresent([Rule].self, forKey: .rules) ?? []
        if let one = try? c.decode(String.self, forKey: .value) {
            self = .conditional(rules: rules, values: [one])
        } else {
            self = .conditional(rules: rules, values: try c.decode([String].self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .plain(let s):
            var c = encoder.singleValueContainer()
            try c.encode(s)
        case .conditional(let rules, let values):
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(rules, forKey: .rules)
            try c.encode(values, forKey: .value)
        }
    }

    public func resolve(on platform: RulePlatform) -> [String] {
        switch self {
        case .plain(let s): [s]
        case .conditional(let rules, let values): RuleEvaluator.allows(rules, on: platform) ? values : []
        }
    }
}

public struct Library: Codable, Sendable, Equatable {
    public struct Downloads: Codable, Sendable, Equatable {
        public let artifact: RemoteFile?
        public let classifiers: [String: RemoteFile]?
    }

    public struct Extract: Codable, Sendable, Equatable {
        public let exclude: [String]?
    }

    /// Maven coordinate, e.g. `com.mojang:brigadier:1.1.8`.
    public let name: String
    public let downloads: Downloads?
    /// Maven repository base used by mod loader libraries without `downloads`.
    public let url: URL?
    /// Checksum and size that mod loader metadata (Fabric, Quilt) gives next to `url`.
    public let sha1: String?
    public let size: Int64?
    /// OS name → classifier (legacy natives format, may contain `${arch}`).
    public let natives: [String: String]?
    public let rules: [Rule]?
    public let extract: Extract?

    public var coordinate: MavenCoordinate? { MavenCoordinate(name) }

    /// True for legacy natives entries (`natives` map) and for 1.19+
    /// `...:natives-<os>` coordinates.
    public var isNative: Bool {
        natives != nil || (coordinate?.classifier?.hasPrefix("natives-") ?? false)
    }

    /// The main artifact file, falling back to deriving it from the Maven
    /// coordinate and `url` (or libraries.minecraft.net) when `downloads` is absent.
    public var artifact: RemoteFile? {
        if let a = downloads?.artifact { return a }
        guard downloads == nil, let coord = coordinate else { return nil }
        let base = url ?? URL(string: "https://libraries.minecraft.net/")!
        return RemoteFile(sha1: sha1, size: size, url: base.appendingPathComponent(coord.path), path: coord.path, id: nil)
    }
}

/// `group:artifact:version[:classifier][@ext]`
public struct MavenCoordinate: Sendable, Equatable, Hashable {
    public let group: String
    public let artifact: String
    public let version: String
    public let classifier: String?
    public let ext: String

    public init?(_ name: String) {
        var body = name
        var ext = "jar"
        if let at = name.lastIndex(of: "@") {
            ext = String(name[name.index(after: at)...])
            body = String(name[..<at])
        }
        let parts = body.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 || parts.count == 4, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        group = parts[0]
        artifact = parts[1]
        version = parts[2]
        classifier = parts.count == 4 ? parts[3] : nil
        self.ext = ext
    }

    /// Identity used for de-duplication: same group/artifact/classifier.
    public var key: String { "\(group):\(artifact)\(classifier.map { ":\($0)" } ?? "")" }

    public var path: String {
        let file = "\(artifact)-\(version)\(classifier.map { "-\($0)" } ?? "").\(ext)"
        return "\(group.replacingOccurrences(of: ".", with: "/"))/\(artifact)/\(version)/\(file)"
    }
}
