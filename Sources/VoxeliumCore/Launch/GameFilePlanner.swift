import Foundation

/// Decides which libraries a version needs on this launcher and which files
/// must be downloaded to install it.
public struct GameFilePlanner: Sendable {
    public let paths: AppPaths
    public let platform: RulePlatform

    public init(paths: AppPaths, platform: RulePlatform = .iOSDefault) {
        self.paths = paths
        self.platform = platform
    }

    /// Mirrors ZalithLauncher2 2.6.1 `filterLibrary()`: LWJGL and old
    /// platform-native helper jars are replaced by launcher-bundled builds,
    /// because Mojang ships no iOS/Android natives.
    public static func isReplacedByLauncher(_ library: Library) -> Bool {
        let n = library.name
        return n.contains("org.lwjgl") || n.contains("jinput-platform") || n.contains("twitch-platform")
    }

    /// Java (non-native) libraries for the classpath, de-duplicated by
    /// group:artifact:classifier with the later entry winning (mod loader
    /// convention), in manifest order.
    public func classpathLibraries(of version: VersionInfo) -> [Library] {
        var order: [String] = []
        var byKey: [String: Library] = [:]
        for lib in version.libraries {
            guard RuleEvaluator.allows(lib.rules, on: platform), !lib.isNative, !Self.isReplacedByLauncher(lib) else { continue }
            let key = lib.coordinate?.key ?? lib.name
            if byKey[key] == nil { order.append(key) }
            byKey[key] = lib
        }
        return order.compactMap { byKey[$0] }
    }

    /// Everything needed to install `version` except assets objects (which
    /// require the asset index to be downloaded first; see `assetItems`).
    public func installItems(for version: VersionInfo) throws -> [DownloadItem] {
        var items: [DownloadItem] = []
        if let client = version.downloads?.client {
            items.append(DownloadItem(url: client.url, destination: try paths.clientJar(version.id), sha1: client.sha1, size: client.size))
        }
        for lib in classpathLibraries(of: version) {
            guard let a = lib.artifact, let path = a.path ?? lib.coordinate?.path else { continue }
            items.append(DownloadItem(url: a.url, destination: try paths.library(path), sha1: a.sha1, size: a.size))
        }
        if let idx = version.assetIndex {
            items.append(DownloadItem(url: idx.url, destination: try paths.assetIndex(idx.id), sha1: idx.sha1, size: idx.size))
        }
        if let cfg = version.logging?.client, let id = cfg.file.id {
            items.append(DownloadItem(url: cfg.file.url, destination: try paths.resolve("log_configs/\(id)", in: paths.assetsDir), sha1: cfg.file.sha1, size: cfg.file.size))
        }
        return items
    }

    public func assetItems(for index: AssetIndex, base: URL = AssetIndex.resourceBase) throws -> [DownloadItem] {
        try index.uniqueObjects.map {
            DownloadItem(url: AssetIndex.url(for: $0, base: base), destination: try paths.assetObject(hash: $0.hash), sha1: $0.hash, size: $0.size)
        }
    }
}
