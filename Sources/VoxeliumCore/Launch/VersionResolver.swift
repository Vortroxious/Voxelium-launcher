import Foundation

/// A launchable version: its JSON with every `inheritsFrom` parent merged in.
public struct ResolvedVersion: Sendable, Equatable {
    /// The merged version (no `inheritsFrom` left).
    public let info: VersionInfo
    /// The ids from the requested version down to the root, e.g.
    /// `["fabric-loader-0.20.0-1.21.11", "1.21.11"]`.
    public let chain: [String]

    /// True for mod loader profiles (anything built on another version).
    public var isModded: Bool { chain.count > 1 }
    /// The vanilla version at the root of the chain.
    public var baseVersionID: String { chain.last ?? info.id }
}

public enum VersionResolveError: Error, Equatable, CustomStringConvertible {
    case parentMissing(child: String, parent: String)
    case cycle(String)
    case tooDeep(String)

    public var description: String {
        switch self {
        case .parentMissing(let c, let p): "\(c) builds on \(p), which is not installed. Install \(p) first."
        case .cycle(let id): "Version \(id) inherits from itself."
        case .tooDeep(let id): "Version \(id) has too many parent versions."
        }
    }
}

/// Loads `versions/<id>/<id>.json` and merges its parents, as the vanilla launcher does.
public struct VersionResolver: Sendable {
    public let paths: AppPaths

    public init(paths: AppPaths) { self.paths = paths }

    public func resolve(_ id: String) throws -> ResolvedVersion {
        var chain: [String] = []
        var versions: [VersionInfo] = []
        var next: String? = id
        while let current = next {
            if chain.contains(current) { throw VersionResolveError.cycle(current) }
            if chain.count >= 8 { throw VersionResolveError.tooDeep(id) }
            let url = try paths.versionJSON(current)
            guard FileManager.default.fileExists(atPath: url.path) else {
                if let child = chain.last { throw VersionResolveError.parentMissing(child: child, parent: current) }
                throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
            }
            let v = try VersionInfo.decode(Data(contentsOf: url))
            chain.append(current)
            versions.append(v)
            next = v.inheritsFrom
        }
        // Merge from the root up: root, then each child onto the result.
        var merged = versions.removeLast()
        while let child = versions.popLast() { merged = child.merged(onto: merged) }
        return ResolvedVersion(info: merged, chain: chain)
    }
}
