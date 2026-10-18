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

    /// Forge and NeoForge need their installer's Java processors run first; on iOS
    /// that takes the one JVM per app launch, so they come in a later phase.
    public var isAvailable: Bool { self == .vanilla || self == .fabric || self == .quilt }
}

/// A loader build offered for one Minecraft version.
public struct LoaderVersion: Sendable, Equatable, Identifiable {
    public let version: String
    /// Fabric marks builds stable; Quilt has no flag, so non-beta/rc/pre builds count.
    public let stable: Bool
    public var id: String { version }

    public init(version: String, stable: Bool) {
        self.version = version
        self.stable = stable
    }
}

public enum ModLoaderError: Error, Equatable, CustomStringConvertible {
    case unsupported(ModLoader)
    case noBuilds(ModLoader, String)
    case http(String, Int)
    case badProfile(String)

    public var description: String {
        switch self {
        case .unsupported(let l): "\(l.displayName) is not supported yet."
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

    /// Loader builds for `minecraft`, newest first as the meta server lists them.
    public func versions(for loader: ModLoader, minecraft: String) async throws -> [LoaderVersion] {
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
        return builds
    }

    /// The default build to offer: the first stable one, else the newest.
    public static func recommended(_ builds: [LoaderVersion]) -> LoaderVersion? {
        builds.first(where: \.stable) ?? builds.first
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

extension HTTPClient {
    /// A plain GET with the User-Agent that Fabric, Quilt and Modrinth ask clients to send.
    func get(_ url: URL) async throws -> JSONResponse {
        var r = URLRequest(url: url)
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue("Voxelium/0.1.1 (iOS Minecraft launcher)", forHTTPHeaderField: "User-Agent")
        return try await send(r)
    }
}
