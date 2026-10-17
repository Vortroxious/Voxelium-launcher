import Foundation

/// Mojang's version list: https://piston-meta.mojang.com/mc/game/version_manifest_v2.json
public struct VersionManifest: Codable, Sendable, Equatable {
    public static let officialURL = URL(string: "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json")!

    public struct Latest: Codable, Sendable, Equatable {
        public let release: String
        public let snapshot: String
    }

    public struct Entry: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let type: VersionType
        public let url: URL
        public let time: Date
        public let releaseTime: Date
        /// SHA-1 of the version JSON (v2 manifest only).
        public let sha1: String?
        public let complianceLevel: Int?
    }

    public let latest: Latest
    public let versions: [Entry]

    public func entry(id: String) -> Entry? { versions.first { $0.id == id } }

    public func versions(of types: Set<VersionType>) -> [Entry] { versions.filter { types.contains($0.type) } }

    public static func decode(_ data: Data) throws -> VersionManifest {
        try MojangJSON.decoder().decode(VersionManifest.self, from: data)
    }
}

public enum VersionType: Codable, Sendable, Hashable {
    case release, snapshot, oldBeta, oldAlpha
    case other(String)

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "release": self = .release
        case "snapshot": self = .snapshot
        case "old_beta": self = .oldBeta
        case "old_alpha": self = .oldAlpha
        default: self = .other(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public var rawValue: String {
        switch self {
        case .release: "release"
        case .snapshot: "snapshot"
        case .oldBeta: "old_beta"
        case .oldAlpha: "old_alpha"
        case .other(let s): s
        }
    }
}

enum MojangJSON {
    /// Mojang timestamps look like `2023-06-12T13:25:51+00:00`.
    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            if let date = f.date(from: s) { return date }
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(s)"))
        }
        return d
    }
}
