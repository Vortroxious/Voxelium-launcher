import Foundation
import Network
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

    /// Why the version list is missing, in words for the player (details go to the log).
    enum ManifestProblem: Equatable {
        case offline
        case unavailable
        case startup(String)

        var canRefresh: Bool {
            if case .startup = self { return false }
            return true
        }
    }

    @Published private(set) var manifest: VersionManifest?
    @Published private(set) var manifestProblem: ManifestProblem?
    /// No network path (Wi-Fi and mobile data off, airplane mode). Reloads the version
    /// list by itself when a connection comes back.
    @Published private(set) var isOffline = false
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
    private let pathMonitor = NWPathMonitor()

    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            Task { @MainActor in
                guard let self, self.isOffline != offline else { return }
                self.isOffline = offline
                self.log.info("network", offline ? "No internet connection" : "Internet connection available")
                if !offline && self.manifest == nil && self.manifestProblem == .offline { await self.loadManifest() }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "Voxelium.network"))
    }

    /// Whether a download failed because there is no connection (URL errors arrive as
    /// text through the downloader).
    static func looksOffline(_ error: Error) -> Bool {
        if let e = error as? URLError {
            return [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff]
                .contains(e.code)
        }
        let text = String(describing: error).lowercased()
        return ["-1009", "-1005", "-1020", "-1018", "appears to be offline", "not connected to the internet"]
            .contains { text.contains($0) }
    }

    func start() async {
        guard paths == nil else { return }
        do {
            let p = try AppPaths.applicationDefault()
            // 0.1.0 kept everything in Application Support, where Files can't see it.
            var migration = DataMigrationReport(), migrationError: Error?
            if let legacy = AppPaths.legacyRoot() {
                do { migration = try AppPaths.migrateIfNeeded(from: legacy, to: p.root) } catch { migrationError = error }
            }
            try p.createLayout()
            try log.attachFile(p.logsDir.appendingPathComponent("launcher.log"))
            if migration.didAnything {
                log.info("app", "Moved data to Documents (visible in Files): \(migration.moved.joined(separator: ", "))\(migration.removedOldRoot ? "; old folder removed" : "")")
            }
            if !migration.kept.isEmpty {
                log.warning("app", "Left in the old data folder because Documents already has them: \(migration.kept.joined(separator: ", "))")
            }
            if let migrationError { log.error("app", "Moving data to Documents stopped (retried next start): \(migrationError)") }
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
            startNetworkMonitor()
            refreshInstalled()
            await loadManifest()
        } catch {
            log.error("app", "Startup failed: \(error)")
            manifestProblem = .startup(String(describing: error))
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
        if isOffline {
            manifestProblem = .offline
            return
        }
        loadingManifest = true
        defer { loadingManifest = false }
        do {
            manifest = try await installer.fetchManifest()
            manifestProblem = nil
        } catch {
            log.error("versions", "Manifest download failed: \(error)")
            manifestProblem = isOffline || Self.looksOffline(error) ? .offline : .unavailable
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

    enum ModpackState: Equatable {
        case idle
        case working(stage: String, completed: Int, total: Int)
        case finished(id: String, mods: Int)
        case failed(String)
    }

    @Published private(set) var modpackState: ModpackState = .idle

    /// Downloads a Modrinth modpack version's .mrpack (checksum verified) and installs it.
    func installModpack(_ version: ModrinthAPI.Version) async {
        guard let installer, let file = version.primaryFile else { return }
        modpackState = .working(stage: "Downloading the modpack", completed: 0, total: 1)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("modpacks", isDirectory: true)
            .appendingPathComponent(file.filename.replacingOccurrences(of: "/", with: "_"))
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try await installer.downloader.ensure(DownloadItem(url: file.url, destination: dest, sha1: file.hashes.sha1, size: file.size))
            await installModpackFile(dest, source: (version.projectId, version.id))
        } catch {
            log.error("modpack", "Download of \(file.filename) failed: \(error)")
            modpackState = .failed(isOffline || Self.looksOffline(error)
                ? "No internet connection. Please turn on your internet and try again."
                : "The modpack could not be downloaded. Please try again in a moment.")
        }
    }

    /// Installs a .mrpack file (from Modrinth or the Files app) as its own version.
    func installModpackFile(_ file: URL, source: (projectID: String, versionID: String)? = nil) async {
        guard let installer else { return }
        let packs = ModpackInstaller(game: installer)
        modpackState = .working(stage: "Reading the modpack", completed: 0, total: 1)
        do {
            let (id, report) = try await packs.install(file, source: source) { stage, p in
                let label = switch stage {
                case .minecraft: "Installing Minecraft"
                case .loader: "Installing the mod loader"
                case .modpackFiles: "Downloading mods"
                case .overrides: "Copying settings"
                }
                Task { @MainActor in self.modpackState = .working(stage: label, completed: p.completed, total: p.total) }
            }
            for (item, err) in report.failures.prefix(20) { log.error("modpack", "\(item.destination.lastPathComponent): \(err)") }
            if report.succeeded {
                let mods = (try? ModpackInstaller.read(file).index.clientModCount) ?? 0
                log.info("modpack", "Installed modpack \(id) (\(mods) mods, \(report.outcomes.count) game files)")
                modpackState = .finished(id: id, mods: mods)
            } else {
                modpackState = .failed("\(report.failures.count) file\(report.failures.count == 1 ? "" : "s") could not be downloaded. Tap Install to try again; finished files are kept.")
            }
            refreshInstalled()
        } catch let error as ModpackError {
            log.error("modpack", "\(file.lastPathComponent): \(error)")
            modpackState = .failed(error.description)
        } catch {
            log.error("modpack", "\(file.lastPathComponent): \(error)")
            modpackState = .failed(isOffline || Self.looksOffline(error)
                ? "No internet connection. Please turn on your internet and try again."
                : "The modpack could not be installed. Details are in Logs.")
        }
    }

    func resetModpackState() { modpackState = .idle }

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

    /// Where a version's mods, packs and saves live: its own folder when modded,
    /// the shared game folder for vanilla.
    func gameDirectory(for id: String) -> URL? {
        guard let paths, let r = try? VersionResolver(paths: paths).resolve(id) else { return nil }
        return r.isModded ? try? paths.instanceDir(id) : paths.gameDir
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
