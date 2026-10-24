import Foundation

/// The account fields that go into game arguments. Only offline/demo values
/// are produced by this project so far; Microsoft auth is not implemented.
public struct LaunchIdentity: Sendable, Equatable {
    public var playerName: String
    public var uuid: String
    public var accessToken: String
    public var userType: String
    public var xuid: String

    public init(playerName: String, uuid: String, accessToken: String, userType: String, xuid: String = "0") {
        self.playerName = playerName
        self.uuid = uuid
        self.accessToken = accessToken
        self.userType = userType
        self.xuid = xuid
    }
}

/// A fully resolved command line for the JVM. Producing this does NOT mean
/// the game can start: on iOS it still needs a JRE, LWJGL natives and a GL
/// layer (see docs/PORTING_FEASIBILITY.md).
public struct LaunchPlan: Sendable, Equatable {
    public let mainClass: String
    public let classpath: [URL]
    public let jvmArguments: [String]
    public let gameArguments: [String]
    public let requiredJavaMajor: Int?
    /// Classpath entries that are not on disk yet.
    public let missingFiles: [URL]
}

public struct LaunchPlanner: Sendable {
    public let paths: AppPaths
    public let platform: RulePlatform
    public var launcherName = "Voxelium"
    public var launcherVersion = "2.2"

    public init(paths: AppPaths, platform: RulePlatform = .iOSDefault) {
        self.paths = paths
        self.platform = platform
    }

    public func plan(
        version: VersionInfo,
        identity: LaunchIdentity,
        resolution: (width: Int, height: Int)? = nil,
        extraJVMArguments: [String] = [],
        gameDirectory: URL? = nil,
        includeClientJar: Bool = true,
        fileManager: FileManager = .default
    ) throws -> LaunchPlan {
        // Mod loader profiles must be merged with their parent first (VersionResolver).
        if version.inheritsFrom != nil {
            throw LaunchPlanError.inheritanceNotSupported(version.id)
        }
        var platform = self.platform
        if resolution != nil { platform.features["has_custom_resolution"] = true }

        let files = GameFilePlanner(paths: paths, platform: platform)
        let libraries = files.classpathLibraries(of: version)
        var classpath = try libraries.compactMap { lib -> URL? in
            guard let path = lib.artifact?.path ?? lib.coordinate?.path else { return nil }
            return try paths.library(path)
        }
        // Created by the Forge/NeoForge processors on the first launch (ForgeInstaller), so
        // not "missing" before it.
        let produced = Set(try libraries.compactMap { lib -> URL? in
            guard let a = lib.artifact, a.isProducedByInstaller, let path = a.path ?? lib.coordinate?.path else { return nil }
            return try paths.library(path)
        })
        // Forge and NeoForge run a patched copy made by their processors; the vanilla jar
        // on the classpath is a second Minecraft that Forge 1.21's bootstrap trips over.
        if includeClientJar { classpath.append(try paths.clientJar(version.clientJarID)) }

        let separator = ":"
        var vars: [String: String] = [
            "auth_player_name": identity.playerName,
            "auth_uuid": identity.uuid,
            "auth_access_token": identity.accessToken,
            "auth_session": identity.accessToken,
            "auth_xuid": identity.xuid,
            "clientid": "",
            "user_type": identity.userType,
            "user_properties": "{}",
            "version_name": version.id,
            "version_type": version.type?.rawValue ?? "release",
            "game_directory": (gameDirectory ?? paths.gameDir).path,
            "assets_root": paths.assetsDir.path,
            "game_assets": paths.assetsDir.path,
            "assets_index_name": version.assetIndex?.id ?? version.assets ?? "legacy",
            "natives_directory": try paths.nativesDir(version.id).path,
            "launcher_name": launcherName,
            "launcher_version": launcherVersion,
            "classpath": classpath.map(\.path).joined(separator: separator),
            "classpath_separator": separator,
            "library_directory": paths.librariesDir.path,
        ]
        if let resolution {
            vars["resolution_width"] = String(resolution.width)
            vars["resolution_height"] = String(resolution.height)
        }

        let rawGame: [String]
        let rawJVM: [String]
        if let args = version.arguments {
            rawGame = (args.game ?? []).flatMap { $0.resolve(on: platform) }
            rawJVM = (args.jvm ?? []).flatMap { $0.resolve(on: platform) }
        } else {
            rawGame = (version.minecraftArguments ?? "").split(separator: " ").map(String.init)
            // Pre-1.13 versions have no JVM arguments in their JSON; these are
            // the standard ones every launcher adds.
            rawJVM = ["-Djava.library.path=${natives_directory}", "-cp", "${classpath}"]
        }

        var jvm = extraJVMArguments + rawJVM.map { Self.substitute($0, vars) }
        if let log = version.logging?.client, let id = log.file.id {
            let cfg = try paths.resolve("log_configs/\(id)", in: paths.assetsDir)
            jvm.append(log.argument.replacingOccurrences(of: "${path}", with: cfg.path))
        }

        let missing = classpath.filter { !produced.contains($0) && !fileManager.fileExists(atPath: $0.path) }
        return LaunchPlan(
            mainClass: version.mainClass,
            classpath: classpath,
            jvmArguments: jvm,
            gameArguments: rawGame.map { Self.substitute($0, vars) },
            requiredJavaMajor: version.javaVersion?.majorVersion,
            missingFiles: missing
        )
    }

    /// Replaces `${name}` placeholders. Unknown placeholders are left as-is so
    /// they are visible in diagnostics instead of silently disappearing.
    public static func substitute(_ s: String, _ vars: [String: String]) -> String {
        guard s.contains("${") else { return s }
        var out = ""
        var rest = Substring(s)
        while let open = rest.range(of: "${") {
            out += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].firstIndex(of: "}") else {
                out += rest[open.lowerBound...]
                return out
            }
            let key = String(rest[open.upperBound..<close])
            out += vars[key] ?? "${\(key)}"
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }
}

public enum LaunchPlanError: Error, Equatable {
    /// A mod loader profile (`inheritsFrom`) was passed unmerged; resolve it with
    /// `VersionResolver` first.
    case inheritanceNotSupported(String)
}
