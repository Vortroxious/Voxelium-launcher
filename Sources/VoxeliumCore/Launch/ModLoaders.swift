import Foundation

/// The mod loaders the version installer offers (as ZalithLauncher2 does).
public enum ModLoader: String, CaseIterable, Codable, Sendable, Identifiable {
    case vanilla, fabric, quilt, forge, neoforge

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .vanilla: "Vanilla"
        case .fabric: "Fabric"
        case .quilt: "Quilt"
        case .forge: "Forge"
        case .neoforge: "NeoForge"
        }
    }

    /// Whether Voxelium offers this loader for a Minecraft version. Forge and NeoForge's
    /// installer processors run in the game's JVM on the first launch (ForgeInstaller,
    /// JavaRuntime/voxelium-boot); Forge is offered from 1.17 (older Forge is rarely
    /// played and is not tested), NeoForge from 1.20.2, its first own builds.
    public func isAvailable(minecraft: String) -> Bool {
        switch self {
        case .vanilla, .fabric, .quilt: true
        case .forge: ForgeMeta.offersForge(minecraft: minecraft)
        case .neoforge: ForgeMeta.neoForgePrefix(minecraft: minecraft) != nil
        }
    }

    /// Shown when `isAvailable(minecraft:)` is false.
    public var oldestMinecraft: String? {
        switch self {
        case .forge: "1.17"
        case .neoforge: "1.20.2"
        default: nil
        }
    }

    /// Forge and NeoForge (installer + processors) rather than a plain profile.
    public var usesForgeInstaller: Bool { self == .forge || self == .neoforge }
}

/// A loader build offered for one Minecraft version.
public struct LoaderVersion: Sendable, Equatable, Identifiable {
    public let version: String
    /// Fabric marks builds stable; Quilt has no flag, so non-beta/rc/pre builds count.
    public let stable: Bool
    /// Forge's promoted "recommended" build.
    public let recommended: Bool
    public var id: String { version }

    public init(version: String, stable: Bool, recommended: Bool = false) {
        self.version = version
        self.stable = stable
        self.recommended = recommended
    }
}

public enum ModLoaderError: Error, Equatable, CustomStringConvertible {
    case unsupported(ModLoader)
    case notOffered(ModLoader, String)
    case noBuilds(ModLoader, String)
    case http(String, Int)
    case badProfile(String)

    public var description: String {
        switch self {
        case .unsupported(let l): "\(l.displayName) is not supported yet."
        case .notOffered(let l, let mc): "Voxelium offers \(l.displayName) for Minecraft \(l.oldestMinecraft ?? "?") and newer, not \(mc)."
        case .noBuilds(let l, let mc): "\(l.displayName) has no builds for Minecraft \(mc)."
        case .http(let what, let status): "\(what) failed (HTTP \(status))."
        case .badProfile(let m): "The loader profile is not usable: \(m)"
        }
    }
}

/// Fabric and Quilt metadata: the loader builds for a Minecraft version, and the
/// launcher profile (a version JSON with `inheritsFrom`) for one build.
///   Fabric: https://meta.fabricmc.net/v2/versions/loader/<mc>[/<loader>/profile/json]
///   Quilt:  https://meta.quiltmc.org/v3/versions/loader/<mc>[/<loader>/profile/json]
public struct ModLoaderMeta: Sendable {
    let http: HTTPClient

    public init(http: HTTPClient = URLSessionHTTPClient()) { self.http = http }

    static func base(_ loader: ModLoader) throws -> String {
        switch loader {
        case .fabric: "https://meta.fabricmc.net/v2/versions/loader"
        case .quilt: "https://meta.quiltmc.org/v3/versions/loader"
        default: throw ModLoaderError.unsupported(loader)
        }
    }

    static func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? s
    }

    /// Loader builds for `minecraft`, newest first. Quilt's meta server doesn't list them
    /// in order (for 1.21.1 it starts with 0.20.0-beta.9), so they are sorted here.
    public func versions(for loader: ModLoader, minecraft: String) async throws -> [LoaderVersion] {
        if loader.usesForgeInstaller { return try await ForgeMeta(http: http).versions(for: loader, minecraft: minecraft) }
        let url = URL(string: "\(try Self.base(loader))/\(Self.escape(minecraft))")!
        let r = try await http.get(url)
        guard r.status == 200 else { throw ModLoaderError.http("\(loader.displayName) versions", r.status) }
        guard let list = (try? JSONSerialization.jsonObject(with: r.data)) as? [[String: Any]] else {
            throw ModLoaderError.badProfile("unexpected \(loader.displayName) version list")
        }
        let builds = list.compactMap { entry -> LoaderVersion? in
            guard let l = entry["loader"] as? [String: Any], let v = l["version"] as? String else { return nil }
            let stable = (l["stable"] as? Bool) ?? !["beta", "rc", "pre", "alpha"].contains { v.lowercased().contains($0) }
            return LoaderVersion(version: v, stable: stable)
        }
        if builds.isEmpty { throw ModLoaderError.noBuilds(loader, minecraft) }
        return builds.sorted { Self.compareVersions($0.version, $1.version) > 0 }
    }

    /// Orders loader versions like `0.30.2`, `0.30.0-beta.8`: numbers part by part, and a
    /// pre-release (`-beta.8`, `-rc.1`) before its release. Parts that aren't numbers compare as text.
    public static func compareVersions(_ a: String, _ b: String) -> Int {
        func split(_ v: String) -> (release: String, pre: String?) {
            let p = v.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            return (String(p[0]), p.count > 1 ? String(p[1]) : nil)
        }
        func parts(_ x: String, _ y: String) -> Int {
            let xs = x.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            let ys = y.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            for i in 0..<max(xs.count, ys.count) {
                guard i < xs.count else { return -1 }
                guard i < ys.count else { return 1 }
                let c: Int
                if let xn = Int64(xs[i]), let yn = Int64(ys[i]) {
                    c = xn < yn ? -1 : (xn > yn ? 1 : 0)
                } else {
                    c = xs[i] < ys[i] ? -1 : (xs[i] > ys[i] ? 1 : 0)
                }
                if c != 0 { return c }
            }
            return 0
        }
        let (releaseA, preA) = split(a), (releaseB, preB) = split(b)
        let c = parts(releaseA, releaseB)
        if c != 0 { return c }
        switch (preA, preB) {
        case (nil, nil): return 0
        case (nil, _): return 1
        case (_, nil): return -1
        case let (x?, y?): return parts(x, y)
        }
    }

    /// The default build to offer: the recommended one (Forge), else the first
    /// stable one, else the newest.
    public static func recommended(_ builds: [LoaderVersion]) -> LoaderVersion? {
        builds.first(where: \.recommended) ?? builds.first(where: \.stable) ?? builds.first
    }

    /// The raw profile JSON for one build.
    public func profile(for loader: ModLoader, minecraft: String, version: String) async throws -> Data {
        let url = URL(string: "\(try Self.base(loader))/\(Self.escape(minecraft))/\(Self.escape(version))/profile/json")!
        let r = try await http.get(url)
        guard r.status == 200 else { throw ModLoaderError.http("\(loader.displayName) profile", r.status) }
        return r.data
    }
}

/// Installs a Fabric or Quilt profile next to its Minecraft version. The base
/// version's files and the loader's libraries are then downloaded by
/// `GameInstaller` from the merged version (see `VersionResolver`).
public struct ModLoaderInstaller: Sendable {
    public let paths: AppPaths
    let meta: ModLoaderMeta

    public init(paths: AppPaths, meta: ModLoaderMeta = ModLoaderMeta()) {
        self.paths = paths
        self.meta = meta
    }

    /// Writes `versions/<id>/<id>.json` for the loader build and returns the
    /// profile (its id is e.g. `fabric-loader-0.19.5-1.21.11`).
    @discardableResult
    public func installProfile(_ loader: ModLoader, minecraft: String, version: String) async throws -> VersionInfo {
        guard loader == .fabric || loader == .quilt else { throw ModLoaderError.unsupported(loader) }
        let data = try await completeChecksums(try await meta.profile(for: loader, minecraft: minecraft, version: version))
        let profile: VersionInfo
        do { profile = try VersionInfo.decode(data) } catch { throw ModLoaderError.badProfile("\(error)") }
        guard profile.inheritsFrom == minecraft else {
            throw ModLoaderError.badProfile("it builds on \(profile.inheritsFrom ?? "nothing"), not \(minecraft)")
        }
        let url = try paths.versionJSON(profile.id)   // rejects ids that escape versions/
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return profile
    }
}

extension ModLoaderInstaller {
    /// Fabric's profiles give SHA-1s for some libraries but not its own loader and
    /// intermediary jars, and Quilt's give none. Like desktop launchers, fetch the
    /// `<jar>.sha1` file each Maven repository publishes and store it in the profile,
    /// so every loader file is verified on download. Libraries whose checksum
    /// cannot be fetched are left as they are.
    func completeChecksums(_ data: Data) async throws -> Data {
        guard var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var libs = json["libraries"] as? [[String: Any]] else { return data }
        var changed = false
        for i in libs.indices where libs[i]["sha1"] == nil && libs[i]["downloads"] == nil {
            guard let name = libs[i]["name"] as? String, let base = libs[i]["url"] as? String,
                  let coord = MavenCoordinate(name), let baseURL = URL(string: base) else { continue }
            let sha1URL = baseURL.appendingPathComponent(coord.path + ".sha1")
            guard let r = try? await meta.http.get(sha1URL), r.status == 200,
                  let text = String(data: r.data, encoding: .utf8)?.split(whereSeparator: \.isWhitespace).first,
                  text.count == 40, text.allSatisfy(\.isHexDigit) else { continue }
            libs[i]["sha1"] = String(text).lowercased()
            changed = true
        }
        guard changed else { return data }
        json["libraries"] = libs
        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    }
}

enum HTTPHeaders {
    /// The User-Agent that Fabric, Quilt, Modrinth, CurseForge and GitHub ask clients to send.
    static let userAgent = "Voxelium/2.4 (iOS Minecraft launcher; github.com/Vortroxious/Voxelium-launcher)"
}

extension HTTPClient {
    /// A plain GET with Voxelium's User-Agent.
    func get(_ url: URL) async throws -> JSONResponse {
        var r = URLRequest(url: url)
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue(HTTPHeaders.userAgent, forHTTPHeaderField: "User-Agent")
        return try await send(r)
    }
}
