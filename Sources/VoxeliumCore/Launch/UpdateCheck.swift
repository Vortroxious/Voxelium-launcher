import Foundation

/// Asks GitHub whether a newer Voxelium release exists. It only reads the public
/// releases API (no account, nothing about the player is sent) and never downloads:
/// players update by sideloading the new IPA.
public struct UpdateCheck: Sendable {
    public static let latestURL = URL(string: "https://api.github.com/repos/Vortroxious/Voxelium-launcher/releases/latest")!

    public struct Release: Codable, Sendable, Equatable {
        public let tagName: String
        public let name: String?
        public let htmlUrl: URL
        public let draft: Bool
        public let prerelease: Bool

        public init(tagName: String, name: String? = nil, htmlUrl: URL, draft: Bool = false, prerelease: Bool = false) {
            self.tagName = tagName
            self.name = name
            self.htmlUrl = htmlUrl
            self.draft = draft
            self.prerelease = prerelease
        }

        /// The version from the tag: "v2.4" → "2.4".
        public var version: String { UpdateCheck.trimmed(tagName) }
    }

    public enum Result: Sendable, Equatable {
        case upToDate(latest: String)
        case available(Release)
    }

    public enum CheckError: Error, Equatable, CustomStringConvertible {
        case http(Int)
        case badResponse

        public var description: String {
            switch self {
            case .http(let s): "GitHub answered with HTTP \(s)."
            case .badResponse: "Unexpected response from GitHub."
            }
        }
    }

    let http: HTTPClient

    public init(http: HTTPClient = URLSessionHTTPClient()) { self.http = http }

    /// The latest published release. GitHub's "latest" already leaves out drafts and
    /// pre-releases; they are checked again in case that changes.
    public func latest() async throws -> Release {
        let r = try await http.get(Self.latestURL)
        guard r.status == 200 else { throw CheckError.http(r.status) }
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        guard let release = try? d.decode(Release.self, from: r.data), !release.draft, !release.prerelease else {
            throw CheckError.badResponse
        }
        return release
    }

    /// Compares the latest release with the running version.
    public func check(current: String) async throws -> Result {
        let release = try await latest()
        return Self.isNewer(release.version, than: current) ? .available(release) : .upToDate(latest: release.version)
    }

    /// Whether `version` is newer than `current`, numerically by part: 2.10 > 2.9,
    /// 2.4 > 2.3.1, and 2.4 equals 2.4.0. A leading "v" is ignored.
    public static func isNewer(_ version: String, than current: String) -> Bool {
        let a = parts(version), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func trimmed(_ tag: String) -> String {
        tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
    }

    /// The numeric parts; anything after the numbers ("2.4-beta") is ignored.
    static func parts(_ version: String) -> [Int] {
        trimmed(version).split(separator: ".").map { part in Int(part.prefix { $0.isNumber }) ?? 0 }
    }
}
