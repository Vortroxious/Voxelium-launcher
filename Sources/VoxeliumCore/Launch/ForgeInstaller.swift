import Foundation

/// Forge and NeoForge builds for a Minecraft version.
///   NeoForge: https://maven.neoforged.net/api/maven/versions/releases/net/neoforged/neoforge
///             (builds are numbered after Minecraft: 1.21.1 → 21.1.x, 26.1.2 → 26.1.2.x)
///   Forge:    https://maven.minecraftforge.net/net/minecraftforge/forge/maven-metadata.xml
///             (versions "1.20.1-47.4.10"), recommended builds from promotions_slim.json
public struct ForgeMeta: Sendable {
    let http: HTTPClient

    public init(http: HTTPClient = URLSessionHTTPClient()) { self.http = http }

    static let neoForgeVersions = URL(string: "https://maven.neoforged.net/api/maven/versions/releases/net/neoforged/neoforge")!
    static let forgeMetadata = URL(string: "https://maven.minecraftforge.net/net/minecraftforge/forge/maven-metadata.xml")!
    static let forgePromotions = URL(string: "https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json")!

    public func versions(for loader: ModLoader, minecraft: String) async throws -> [LoaderVersion] {
        guard loader.isAvailable(minecraft: minecraft) else { throw ModLoaderError.notOffered(loader, minecraft) }
        let builds: [LoaderVersion]
        switch loader {
        case .neoforge:
            let r = try await http.get(Self.neoForgeVersions)
            guard r.status == 200 else { throw ModLoaderError.http("NeoForge versions", r.status) }
            builds = try Self.neoForgeBuilds(r.data, minecraft: minecraft)
        case .forge:
            let r = try await http.get(Self.forgeMetadata)
            guard r.status == 200 else { throw ModLoaderError.http("Forge versions", r.status) }
            // Promotions only mark the recommended build; the list works without them.
            let promos = try? await http.get(Self.forgePromotions)
            builds = Self.forgeBuilds(r.data, promotions: promos?.status == 200 ? promos?.data : nil, minecraft: minecraft)
        default:
            throw ModLoaderError.unsupported(loader)
        }
        if builds.isEmpty { throw ModLoaderError.noBuilds(loader, minecraft) }
        return builds
    }

    /// Forge is offered for Minecraft 1.17 and newer (26.x included).
    static func offersForge(minecraft mc: String) -> Bool {
        let p = mc.split(separator: ".").map { Int($0) }
        guard p.count >= 2, let major = p[0], let minor = p[1] else { return false }
        return major > 1 || minor >= 17
    }

    /// The build-number prefix NeoForge uses for a Minecraft version, or nil when
    /// NeoForge has no builds of its own for it (before 1.20.2; 1.20.1's NeoForge
    /// was a Forge fork with Forge's installer and is not offered).
    static func neoForgePrefix(minecraft mc: String) -> String? {
        let p = mc.split(separator: ".").map(String.init)
        guard p.count >= 2, p.allSatisfy({ Int($0) != nil }) else { return nil }
        if p[0] == "1" {
            let minor = Int(p[1])!, patch = p.count > 2 ? Int(p[2])! : 0
            guard minor > 20 || (minor == 20 && patch >= 2) else { return nil }
            return "\(minor).\(patch)."
        }
        return "\(p[0]).\(p[1]).\(p.count > 2 ? p[2] : "0")."
    }

    /// Newest first; "-beta"/"-alpha" builds are not stable.
    static func neoForgeBuilds(_ data: Data, minecraft: String) throws -> [LoaderVersion] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let all = json["versions"] as? [String] else {
            throw ModLoaderError.badProfile("unexpected NeoForge version list")
        }
        guard let prefix = neoForgePrefix(minecraft: minecraft) else { return [] }
        return all.filter { $0.hasPrefix(prefix) }
            .sorted { compareVersions($0, $1) == .orderedDescending }
            .map { v in LoaderVersion(version: v, stable: !["beta", "alpha"].contains { v.lowercased().contains($0) }) }
    }

    /// Builds for `minecraft` as "47.4.10", newest first. All Forge builds count as
    /// stable; the promoted recommended (else latest) one is marked recommended.
    static func forgeBuilds(_ metadata: Data, promotions: Data?, minecraft: String) -> [LoaderVersion] {
        let xml = String(decoding: metadata, as: UTF8.self)
        var builds: [String] = []
        var rest = xml[...]
        while let open = rest.range(of: "<version>"), let close = rest[open.upperBound...].range(of: "</version>") {
            let v = rest[open.upperBound..<close.lowerBound]
            if v.hasPrefix(minecraft + "-") {
                let build = String(v.dropFirst(minecraft.count + 1))
                // Pre-1.13 entries look like "10.13.4.1614-1.7.10"; never for versions we offer.
                if !build.contains("-") { builds.append(build) }
            }
            rest = rest[close.upperBound...]
        }
        var recommended: String?
        if let promotions, let json = (try? JSONSerialization.jsonObject(with: promotions)) as? [String: Any],
           let promos = json["promos"] as? [String: String] {
            recommended = promos["\(minecraft)-recommended"] ?? promos["\(minecraft)-latest"]
        }
        return Array(Set(builds)).sorted { compareVersions($0, $1) == .orderedDescending }
            .map { LoaderVersion(version: $0, stable: true, recommended: $0 == recommended) }
    }

    /// Compares dotted build numbers numerically ("21.1.100" > "21.1.99"), suffixes last.
    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        func parts(_ s: String) -> [Int] {
            s.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        // Same numbers: a release sorts above its "-beta".
        if a.contains("-") != b.contains("-") { return a.contains("-") ? .orderedAscending : .orderedDescending }
        return a.compare(b)
    }
}

public enum ForgeInstallError: Error, Equatable, CustomStringConvertible {
    case badInstaller(String)

    public var description: String {
        switch self {
        case .badInstaller(let m): "The installer is not usable: \(m)"
        }
    }
}

/// Installs a Forge or NeoForge build the way their own installer's "client" mode
/// does, except that the Java processors (binary patcher, remapper, …) are not run
/// here: iOS allows one JVM per app launch, so they run in the game's JVM on the first
/// launch, through the bundled `voxelium-boot.jar` (JavaRuntime/voxelium-boot).
///
/// Writes:
///   libraries/…/<loader>-<build>-installer.jar   (SHA-1 checked against the Maven .sha1)
///   libraries/…                                   the processors' jars and the loader's own
///                                                 files bundled in the installer (maven/…)
///   versions/<id>/installer-data/…                files the processors read (data/client.lzma)
///   versions/<id>/voxelium-processors.txt         the processor plan Boot.java reads
///   versions/<id>/<id>.json                       the loader's version JSON (inheritsFrom <mc>)
public struct ForgeInstaller: Sendable {
    public let paths: AppPaths
    let downloader: DownloadManager
    let http: HTTPClient

    public init(paths: AppPaths, downloader: DownloadManager = DownloadManager(), http: HTTPClient = URLSessionHTTPClient()) {
        self.paths = paths
        self.downloader = downloader
        self.http = http
    }

    public static let planFileName = "voxelium-processors.txt"

    /// The processor plan for a version, if it is a Forge/NeoForge install.
    public static func processorPlan(_ id: String, paths: AppPaths) -> URL? {
        guard let url = try? paths.versionDir(id).appendingPathComponent(planFileName),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// True once the processors ran successfully (Boot.java writes `<plan>.done`).
    public static func processorsDone(_ plan: URL) -> Bool {
        FileManager.default.fileExists(atPath: plan.path + ".done")
    }

    static func installerCoordinate(_ loader: ModLoader, minecraft: String, build: String) throws -> MavenCoordinate {
        switch loader {
        case .neoforge: return MavenCoordinate("net.neoforged:neoforge:\(build):installer")!
        case .forge: return MavenCoordinate("net.minecraftforge:forge:\(minecraft)-\(build):installer")!
        default: throw ModLoaderError.unsupported(loader)
        }
    }

    static func repository(_ loader: ModLoader) -> URL {
        loader == .neoforge ? URL(string: "https://maven.neoforged.net/releases/")! : URL(string: "https://maven.minecraftforge.net/")!
    }

    /// Downloads the installer and the processors' libraries, then writes the plan and
    /// the version JSON. Returns the version id (e.g. "neoforge-21.11.48",
    /// "1.20.1-forge-47.4.10") and the download report of those files; the version's
    /// own libraries are downloaded afterwards by `GameInstaller` like any version's.
    public func installProfile(
        _ loader: ModLoader, minecraft: String, build: String, concurrency: Int = 8,
        progress: (@Sendable (DownloadProgress) -> Void)? = nil
    ) async throws -> (id: String, report: DownloadReport) {
        // Also covers modpacks, which install their loader through here.
        guard loader.isAvailable(minecraft: minecraft) else { throw ModLoaderError.notOffered(loader, minecraft) }
        guard Self.isSafeBuild(build) else { throw ModLoaderError.badProfile("unexpected build \(build)") }
        let coord = try Self.installerCoordinate(loader, minecraft: minecraft, build: build)
        let installerURL = Self.repository(loader).appendingPathComponent(coord.path)
        let installer = try paths.library(coord.path)
        let sha1 = try await fetchSHA1(installerURL)
        let first = try await downloader.run([DownloadItem(url: installerURL, destination: installer, sha1: sha1, size: nil)], concurrency: 1)
        if !first.succeeded { return ("", first) }

        let zip = try ZipReader(url: installer)
        guard let profileData = try zip.read("install_profile.json"),
              let profile = (try? JSONSerialization.jsonObject(with: profileData)) as? [String: Any] else {
            throw ForgeInstallError.badInstaller("no install_profile.json")
        }
        if profile["install"] != nil || profile["versionInfo"] != nil {
            throw ForgeInstallError.badInstaller("old installer format")
        }
        let jsonPath = ((profile["json"] as? String) ?? "/version.json").trimmingPrefix("/")
        guard let versionData = try zip.read(String(jsonPath)) else { throw ForgeInstallError.badInstaller("no \(jsonPath)") }
        let version: VersionInfo
        do { version = try VersionInfo.decode(versionData) } catch { throw ModLoaderError.badProfile("\(error)") }
        guard version.inheritsFrom == minecraft else {
            throw ModLoaderError.badProfile("it builds on \(version.inheritsFrom ?? "nothing"), not \(minecraft)")
        }
        let versionDir = try paths.versionDir(version.id)   // rejects ids that escape versions/
        let fm = FileManager.default
        try fm.createDirectory(at: versionDir, withIntermediateDirectories: true)

        // Libraries: the processors' (install profile) and the loader's (version JSON).
        // Those without a URL are inside the installer under maven/, or are made by
        // the processors.
        let installLibs = try Self.decodeLibraries(profile["libraries"])
        var items: [DownloadItem] = []
        for lib in installLibs + version.libraries {
            guard let a = lib.artifact, let path = a.path ?? lib.coordinate?.path else { continue }
            let dest = try paths.library(path)
            if a.isProducedByInstaller {
                if zip.entry(named: "maven/\(path)") != nil { try extract(zip, "maven/\(path)", to: dest, sha1: a.sha1) }
            } else if installLibs.contains(lib) {
                items.append(DownloadItem(url: a.url, destination: dest, sha1: a.sha1, size: a.size))
            }
        }
        let report = try await downloader.run(Array(Set(items)), concurrency: concurrency) { progress?($0) }
        if !report.succeeded { return (version.id, report) }

        let plan = try processorPlan(profile: profile, installLibs: installLibs, zip: zip, installer: installer,
                                     minecraft: minecraft, versionDir: versionDir)
        let planURL = versionDir.appendingPathComponent(Self.planFileName)
        try? fm.removeItem(atPath: planURL.path + ".done")
        try Data(plan.utf8).write(to: planURL, options: .atomic)
        try versionData.write(to: try paths.versionJSON(version.id), options: .atomic)
        return (version.id, report)
    }

    static func isSafeBuild(_ b: String) -> Bool {
        !b.isEmpty && b.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" || $0 == "_" }
    }

    static func decodeLibraries(_ raw: Any?) throws -> [Library] {
        guard let raw else { return [] }
        let data = try JSONSerialization.data(withJSONObject: raw)
        return try MojangJSON.decoder().decode([Library].self, from: data)
    }

    /// Maven publishes `<file>.sha1` next to each file; the installer is checked against it.
    func fetchSHA1(_ url: URL) async throws -> String {
        let r = try await http.get(URL(string: url.absoluteString + ".sha1")!)
        guard r.status == 200, let text = String(data: r.data, encoding: .utf8)?.split(whereSeparator: \.isWhitespace).first,
              text.count == 40, text.allSatisfy(\.isHexDigit) else {
            throw ModLoaderError.http("Installer checksum", r.status)
        }
        return text.lowercased()
    }

    func extract(_ zip: ZipReader, _ name: String, to dest: URL, sha1: String?) throws {
        guard let data = try zip.read(name, limit: 512 << 20) else { throw ForgeInstallError.badInstaller("no \(name)") }
        if let sha1, !sha1.isEmpty, FileHash.sha1(of: data) != sha1.lowercased() {
            throw ForgeInstallError.badInstaller("\(name) does not match its checksum")
        }
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: dest, options: .atomic)
    }

    /// Resolves the client processors into Boot.java's plan format, following the
    /// installer's rules: `[group:artifact:version]` is a library path, `'text'` a
    /// literal, `/path` a file extracted from the installer, `{KEY}` a data value.
    func processorPlan(profile: [String: Any], installLibs: [Library], zip: ZipReader, installer: URL,
                       minecraft: String, versionDir: URL) throws -> String {
        func library(_ name: String) throws -> String {
            guard let c = MavenCoordinate(name) else { throw ForgeInstallError.badInstaller("bad artifact \(name)") }
            return try paths.library(c.path).path
        }
        let dataDir = versionDir.appendingPathComponent("installer-data", isDirectory: true)
        var data: [String: String] = [
            "SIDE": "client",
            "MINECRAFT_JAR": try paths.clientJar(minecraft).path,
            "MINECRAFT_VERSION": minecraft,
            "ROOT": paths.gameDir.path,
            "INSTALLER": installer.path,
            "LIBRARY_DIR": paths.librariesDir.path,
        ]
        for (key, sides) in (profile["data"] as? [String: Any]) ?? [:] {
            guard let value = (sides as? [String: Any])?["client"] as? String, !value.isEmpty else { continue }
            if value.hasPrefix("[") && value.hasSuffix("]") {
                data[key] = try library(String(value.dropFirst().dropLast()))
            } else if value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2 {
                data[key] = String(value.dropFirst().dropLast())
            } else if value.hasPrefix("/") {
                let dest = try paths.resolve(String(value.dropFirst()), in: dataDir)
                try extract(zip, String(value.dropFirst()), to: dest, sha1: nil)
                data[key] = dest.path
            } else {
                data[key] = value
            }
        }
        func resolve(_ arg: String) throws -> String {
            if arg.hasPrefix("[") && arg.hasSuffix("]") { return try library(String(arg.dropFirst().dropLast())) }
            var out = ""
            var rest = Substring(arg)
            while let open = rest.firstIndex(of: "{") {
                out += rest[..<open]
                guard let close = rest[open...].firstIndex(of: "}") else { out += rest[open...]; return out }
                let key = String(rest[rest.index(after: open)..<close])
                guard let value = data[key] else { throw ForgeInstallError.badInstaller("unknown value {\(key)}") }
                out += value
                rest = rest[rest.index(after: close)...]
            }
            out += rest
            // Output checksums are written as 'sha1' literals.
            if out.hasPrefix("'") && out.hasSuffix("'") && out.count >= 2 { out = String(out.dropFirst().dropLast()) }
            return out
        }

        var lines: [String] = []
        for case let p as [String: Any] in (profile["processors"] as? [Any]) ?? [] {
            if let sides = p["sides"] as? [String], !sides.contains("client") { continue }
            guard let jar = p["jar"] as? String else { throw ForgeInstallError.badInstaller("processor without a jar") }
            let args = try ((p["args"] as? [String]) ?? []).map(resolve)
            var name = MavenCoordinate(jar)?.artifact ?? jar
            if let i = args.firstIndex(of: "--task"), i + 1 < args.count { name += " " + args[i + 1] }
            lines.append("processor \(name)")
            lines.append("jar \(try library(jar))")
            for cp in (p["classpath"] as? [String]) ?? [] { lines.append("cp \(try library(cp))") }
            for a in args { lines.append("arg \(a)") }
            for (k, v) in ((p["outputs"] as? [String: String]) ?? [:]).sorted(by: { $0.key < $1.key }) {
                let sha = try resolve(v)
                lines.append("out \(try resolve(k)) \(sha.isEmpty ? "-" : sha)")
            }
            lines.append("end")
        }
        if let bad = lines.first(where: { $0.contains("\n") || $0.contains("\r") }) {
            throw ForgeInstallError.badInstaller("line break in \(bad.prefix(60))")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
