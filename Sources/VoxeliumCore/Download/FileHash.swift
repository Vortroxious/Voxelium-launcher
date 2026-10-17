import CryptoKit
import Foundation

public enum FileHash {
    /// Streams the file through SHA-1 (Mojang's integrity hash) in 1 MiB chunks.
    public static func sha1(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.SHA1()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    public static func sha1(of data: Data) -> String { hex(Insecure.SHA1.hash(data: data)) }

    public static func sha256(of data: Data) -> String { hex(SHA256.hash(data: data)) }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Checks size (cheap) before hash. A nil expectation is not checked.
    public static func verify(_ url: URL, sha1 expected: String?, size: Int64?) -> IntegrityResult {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let actualSize = (attrs[.size] as? NSNumber)?.int64Value
        else { return .missing }
        if let size, size != actualSize { return .sizeMismatch(expected: size, actual: actualSize) }
        guard let expected else { return .unverified }
        guard let actual = try? sha1(of: url) else { return .missing }
        return actual.caseInsensitiveCompare(expected) == .orderedSame ? .valid : .hashMismatch(expected: expected, actual: actual)
    }
}

public enum IntegrityResult: Sendable, Equatable {
    case valid
    /// File exists and matches size, but no hash was available to check.
    case unverified
    case missing
    case sizeMismatch(expected: Int64, actual: Int64)
    case hashMismatch(expected: String, actual: String)

    public var isAcceptable: Bool { self == .valid || self == .unverified }
}
