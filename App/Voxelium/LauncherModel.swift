import Foundation
import VoxeliumCore

/// App state. All launcher logic lives in VoxeliumCore; this only adapts it to SwiftUI.
@MainActor
final class LauncherModel: ObservableObject {
    enum InstallState: Equatable {
        case idle
        case preparing
        case downloading(stage: String, completed: Int, total: Int, failed: Int)
        case finished(ok: Int, failed: Int)
        case failed(String)
    }

    @Published private(set) var manifest: VersionManifest?
    @Published private(set) var manifestError: String?
    @Published private(set) var loadingManifest = false
    @Published private(set) var installed: Set<String> = []
    @Published private(set) var installState: [String: InstallState] = [:]
    @Published private(set) var lastPlan: LaunchPlan?
    @Published var settings = LauncherSettings() {
        didSet { try? settingsStore?.save(settings) }
    }

    let log = Logger.shared
    private(set) var paths: AppPaths?
    private var settingsStore: SettingsStore?
    private var installer: GameInstaller?

    func start() async {
        guard paths == nil else { return }
        do {
            let p = try AppPaths.applicationDefault()
            try p.createLayout()
            try log.attachFile(p.logsDir.appendingPathComponent("launcher.log"))
            paths = p
            settingsStore = SettingsStore(paths: p)
            settings = settingsStore!.load()
            installer = GameInstaller(paths: p)
            let info = Bundle.main.infoDictionary
            log.info("app", "Build \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))")
            log.info("app", "Data directory: \(p.root.path)")
            log.info("app", "JIT/debugger attached: \(DeviceInfo.isDebuggerAttached)")
            log.info("app", "JIT: \(VXJVMBridge.jitDescription())")
            log.info("app", "GLFW bridge: \(VXGLFWSelfCheck())")
            exportJITScript()
            refreshInstalled()
            await loadManifest()
        } catch {
            log.error("app", "Startup failed: \(error)")
            manifestError = "Startup failed: \(error)"
        }
    }

    /// Puts UniversalJIT26.js in Documents (visible in Files and StikDebug's
    /// script picker) so it can be assigned to this app.
    private func exportJITScript() {
        let fm = FileManager.default
        guard let src = Bundle.main.url(forResource: "UniversalJIT26", withExtension: "js"),
              let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let dest = docs.appendingPathComponent("UniversalJIT26.js")
        if fm.contentsEqual(atPath: src.path, andPath: dest.path) { return }
        try? fm.removeItem(at: dest)
        do {
            try fm.copyItem(at: src, to: dest)
            log.info("app", "Exported JIT script to \(dest.path)")
        } catch {
            log.warning("app", "Could not export JIT script: \(error)")
        }
    }

    func loadManifest() async {
        guard let installer else { return }
        loadingManifest = true
        defer { loadingManifest = false }
        do {
            manifest = try await installer.fetchManifest()
            manifestError = nil
        } catch {
            log.error("versions", "Manifest download failed: \(error)")
            manifestError = String(describing: error)
        }
    }

    var visibleVersions: [VersionManifest.Entry] {
        manifest?.versions(of: settings.showSnapshots ? [.release, .snapshot] : [.release]) ?? []
    }

    func refreshInstalled() {
        guard let paths, let installer else { return }
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: paths.versionsDir.path)) ?? []
        installed = Set(ids.filter(installer.isInstalled))
    }

    func install(_ entry: VersionManifest.Entry) async {
        guard let installer else { return }
        installState[entry.id] = .preparing
        do {
            let version = try await installer.fetchVersion(entry)
            let report = try await installer.install(version, concurrency: settings.downloadConcurrency) { stage, p in
                Task { @MainActor in
                    self.installState[entry.id] = .downloading(stage: stage == .assets ? "Assets" : "Game files", completed: p.completed, total: p.total, failed: p.failed)
                }
            }
            installState[entry.id] = .finished(ok: report.outcomes.count, failed: report.failures.count)
            for (item, err) in report.failures.prefix(20) { log.error("install", "\(item.destination.lastPathComponent): \(err)") }
            refreshInstalled()
        } catch {
            log.error("install", "Install of \(entry.id) failed: \(error)")
            installState[entry.id] = .failed(String(describing: error))
        }
    }

    /// Installs `minecraft` with a mod loader build (installing the vanilla base first
    /// if needed). Progress is shown on the Minecraft version's row.
    func installLoader(_ loader: ModLoader, build: String, minecraft: String) async {
        guard let installer else { return }
        installState[minecraft] = .preparing
        do {
            let (id, report) = try await installer.installLoader(loader, minecraft: minecraft, version: build,
                                                                 concurrency: settings.downloadConcurrency) { stage, p in
                Task { @MainActor in
                    self.installState[minecraft] = .downloading(stage: stage == .assets ? "Assets" : "Game files", completed: p.completed, total: p.total, failed: p.failed)
                }
            }
            installState[minecraft] = .finished(ok: report.outcomes.count, failed: report.failures.count)
            for (item, err) in report.failures.prefix(20) { log.error("install", "\(item.destination.lastPathComponent): \(err)") }
            log.info("install", "Installed \(loader.displayName) \(build) for \(minecraft) as \(id): \(report.outcomes.count) files, \(report.failures.count) failed")
            refreshInstalled()
        } catch {
            log.error("install", "\(loader.displayName) \(build) for \(minecraft) failed: \(error)")
            installState[minecraft] = .failed(String(describing: error))
        }
    }

    /// Loader builds offered for a Minecraft version (Fabric, Quilt).
    func loaderBuilds(_ loader: ModLoader, minecraft: String) async throws -> [LoaderVersion] {
        try await ModLoaderMeta().versions(for: loader, minecraft: minecraft)
    }

    /// Everything installed, newest first: vanilla versions and mod loader versions
    /// (which Mojang's version list does not contain).
    var installedVersions: [InstalledVersion] {
        guard let paths else { return [] }
        let resolver = VersionResolver(paths: paths)
        return installed.compactMap { id -> InstalledVersion? in
            guard let r = try? resolver.resolve(id) else { return nil }
            return InstalledVersion(id: id, base: r.baseVersionID, isModded: r.isModded,
                                    loader: Self.loaderName(of: r), releaseTime: r.info.releaseTime)
        }
        .sorted { ($0.releaseTime ?? .distantPast, $0.id) > ($1.releaseTime ?? .distantPast, $1.id) }
    }

    static func loaderName(of r: ResolvedVersion) -> String? {
        guard r.isModded else { return nil }
        let main = r.info.mainClass
        if main.hasPrefix("net.fabricmc") { return "Fabric" }
        if main.hasPrefix("org.quiltmc") { return "Quilt" }
        return "Modded"
    }

    /// Builds the JVM command line for inspection (Account tab). It does not start
    /// Java; MinecraftLauncher does that.
    func preparePlan(_ id: String) {
        guard let paths else { return }
        do {
            let resolved = try VersionResolver(paths: paths).resolve(id)
            let identity = OfflineIdentity.identity(for: settings.playerName)
            lastPlan = try LaunchPlanner(paths: paths).plan(version: resolved.info, identity: identity,
                                                            extraJVMArguments: ["-Xmx\(settings.maxMemoryMB)M"],
                                                            gameDirectory: resolved.isModded ? try paths.instanceDir(id) : nil)
            log.info("launch", "Prepared launch plan for \(id); missing files: \(lastPlan?.missingFiles.count ?? -1)")
        } catch {
            log.error("launch", "Could not prepare launch plan for \(id): \(error)")
        }
    }

    var runtimes: [JavaRuntime] {
        guard let paths else { return [] }
        return RuntimeCatalog(directory: paths.runtimesDir).discover()
    }
}

/// A row in the Installed section.
struct InstalledVersion: Identifiable, Equatable {
    let id: String
    /// The Minecraft version it runs (itself for vanilla).
    let base: String
    let isModded: Bool
    /// "Fabric", "Quilt", … for modded versions.
    let loader: String?
    let releaseTime: Date?
}
