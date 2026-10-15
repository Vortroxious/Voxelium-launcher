import Foundation

/// An asset index such as `indexes/5.json`.
public struct AssetIndex: Codable, Sendable, Equatable {
    public struct Object: Codable, Sendable, Equatable {
        public let hash: String
        public let size: Int64
    }

    public let objects: [String: Object]
    /// Pre-1.7 indexes: objects are also copied to `assets/virtual/legacy`.
    public let virtual: Bool?
    /// Very old indexes: objects are copied into `<gameDir>/resources`.
    public let mapToResources: Bool?

    public static func decode(_ data: Data) throws -> AssetIndex {
        try JSONDecoder().decode(AssetIndex.self, from: data)
    }

    public static let resourceBase = URL(string: "https://resources.download.minecraft.net/")!

    /// Download URL for an object: `<base>/<hash[0..2]>/<hash>`.
    public static func url(for object: Object, base: URL = resourceBase) -> URL {
        base.appendingPathComponent(String(object.hash.prefix(2))).appendingPathComponent(object.hash)
    }

    /// Unique objects by hash (several names can share one blob).
    public var uniqueObjects: [Object] {
        var seen = Set<String>()
        return objects.values.sorted { $0.hash < $1.hash }.filter { seen.insert($0.hash).inserted }
    }

    public var totalSize: Int64 { uniqueObjects.reduce(0) { $0 + $1.size } }
}
