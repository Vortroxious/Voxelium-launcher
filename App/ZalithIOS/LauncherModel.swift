import Foundation
import ZalithCore

/// App state. All launcher logic lives in ZalithCore; this only adapts it to SwiftUI.
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
            log.info("app", "Data directory: \(p.root.path)")
            log.info("app", "JIT/debugger attached: \(DeviceInfo.isDebuggerAttached)")
            log.info("app", "JIT: \(ZLJVMBridge.jitDescription())")
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

    /// Builds the JVM command line. This does NOT start Java: the iOS JVM
    /// bridge is not implemented (see docs/PORTING_FEASIBILITY.md, gate A).
    func preparePlan(_ id: String) {
        guard let paths else { return }
        do {
            let data = try Data(contentsOf: try paths.versionJSON(id))
            let version = try VersionInfo.decode(data)
            let identity = OfflineIdentity.identity(for: settings.playerName)
            lastPlan = try LaunchPlanner(paths: paths).plan(version: version, identity: identity, extraJVMArguments: ["-Xmx\(settings.maxMemoryMB)M"])
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
