import AVFoundation
import Foundation
import ZalithCore

/// Milestone 7: start an installed vanilla version inside this process.
///
/// Builds on everything verified in Milestones 5–6: the bundled iOS JRE with
/// StikDebug JIT, LWJGL 3.3.3 iOS natives, MobileGlues (desktop GL) on ANGLE,
/// the app's own GLFW, openal-soft, and no-op stubs for the macOS-only
/// ca.weblite.objc API Minecraft calls (it sees os.name = "Mac OS X").
@MainActor
final class MinecraftLauncher: ObservableObject {
    enum State: Equatable {
        case idle
        case starting(String)
        case running(String)
        case finished(ok: Bool, message: String)
    }

    @Published private(set) var state: State = .idle
    private let log = Logger.shared

    /// Java-side LWJGL modules Minecraft 1.20.1 uses (Mojang's own LWJGL entries
    /// are filtered out by GameFilePlanner and replaced with these iOS builds).
    static let lwjglModules = ["lwjgl", "lwjgl-glfw", "lwjgl-opengl", "lwjgl-openal", "lwjgl-stb", "lwjgl-tinyfd", "lwjgl-jemalloc"]

    /// One JVM per process: once Minecraft has been started, relaunch the app to start again.
    private static var started = false

    func launch(versionID: String, paths: AppPaths, settings: LauncherSettings) {
        guard !Self.started else {
            state = .finished(ok: false, message: "A JVM already ran in this launch. Close and relaunch the app.")
            return
        }
        guard let res = Bundle.main.resourceURL, let frameworks = Bundle.main.privateFrameworksURL else { return }
        let java = res.appendingPathComponent("java", isDirectory: true)
        let lwjgl = java.appendingPathComponent("lwjgl", isDirectory: true)
        let home = java.appendingPathComponent("jre17", isDirectory: true)
        let fm = FileManager.default

        do {
            let version = try VersionInfo.decode(Data(contentsOf: try paths.versionJSON(versionID)))
            if let major = version.javaVersion?.majorVersion, major > 17 {
                throw LaunchError.message("\(versionID) needs Java \(major); only Java 17 is bundled.")
            }
            guard OfflineIdentity.isValidName(settings.playerName) else {
                throw LaunchError.message("Set a valid player name (3–16 letters, digits or _) on the Account tab.")
            }
            let plan = try LaunchPlanner(paths: paths).plan(version: version, identity: OfflineIdentity.identity(for: settings.playerName))
            if !plan.missingFiles.isEmpty {
                throw LaunchError.message("\(plan.missingFiles.count) game files are missing. Install or repair \(versionID) first.")
            }

            // Classpath: iOS LWJGL + compat stubs, then the game's libraries and client jar.
            let ours = Self.lwjglModules.map { lwjgl.appendingPathComponent("\($0).jar") }
                + [java.appendingPathComponent("zalith-ios-compat.jar")]
            for url in ours where !fm.fileExists(atPath: url.path) {
                throw LaunchError.message("Bundled file missing: \(url.lastPathComponent)")
            }
            let classpath = (ours + plan.classpath).map(\.path).joined(separator: ":")

            // Version JSON JVM args, minus what the JNI invocation API cannot take
            // ("-cp <cp>", passed as java.class.path by JVMBridge) and the log4j XML
            // console config (plain text is readable in jvm.log).
            var jvmArgs: [String] = []
            var skipNext = false
            for arg in plan.jvmArguments {
                if skipNext { skipNext = false; continue }
                if arg == "-cp" || arg == "-classpath" { skipNext = true; continue }
                if arg.hasPrefix("-Dlog4j.configurationFile=") { continue }
                jvmArgs.append(arg)
            }

            let heap = Self.heapMegabytes(requested: settings.maxMemoryMB)
            var options = JavaTestModel.jvmOptions(paths: paths)
                .filter { !$0.hasPrefix("-Xmx") && !$0.hasPrefix("-Xms") && !$0.hasPrefix("-Duser.dir=") }
            options += [
                "-Xms256M",
                "-Xmx\(heap)M",
                "-Djava.awt.headless=true",
                "-Dlog4j2.formatMsgNoLookups=true",
                "-Dorg.lwjgl.librarypath=\(lwjgl.path)",
                "-Dorg.lwjgl.glfw.libname=\(ZLGLFWLibraryPath())",
                "-Dorg.lwjgl.glfw.checkThread0=false",
                "-Dorg.lwjgl.opengl.libname=\(frameworks.appendingPathComponent("libmobileglues.dylib").path)",
                "-Dorg.lwjgl.system.allocator=system",
                // Minecraft resolves logs/, crash-reports/ etc. against the working directory.
                "-Duser.dir=\(paths.gameDir.path)",
            ]
            options += jvmArgs

            // iOS gives an app the "solo ambient" audio category by default, which
            // the silent switch / Action button mutes. A game should play anyway.
            Self.activateAudioSession(log: log)
            // The process cwd is "/" on iOS; log4j's logs/latest.log is relative to it.
            fm.changeCurrentDirectoryPath(paths.gameDir.path)
            let mgDir = paths.logsDir.appendingPathComponent("mobileglues", isDirectory: true)
            try? fm.createDirectory(at: mgDir, withIntermediateDirectories: true)
            setenv("MG_DIR_PATH", mgDir.path, 1)
            // Render at half the native pixels by default (2796x1290 is a lot for a phone GPU).
            if getenv("ZALITH_RENDER_SCALE") == nil { setenv("ZALITH_RENDER_SCALE", "0.5", 1) }

            let logURL = paths.logsDir.appendingPathComponent("jvm.log")
            let header = "\n===== Minecraft \(versionID) \(ISO8601DateFormatter().string(from: Date())) heap=\(heap)M \(ZLJVMBridge.jitDescription())\n"
            if let h = try? FileHandle(forWritingTo: logURL) {
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: Data(header.utf8))
                try? h.close()
            } else {
                fm.createFile(atPath: logURL.path, contents: Data(header.utf8))
            }

            log.info("launch", "Starting Minecraft \(versionID): heap \(heap) MB, \(ours.count + plan.classpath.count) classpath entries, \(options.count) JVM options")
            Self.started = true
            MobileGluesSession.used = true
            state = .running("Minecraft \(versionID) is running. Its log goes to logs/jvm.log.")

            let mainClass = plan.mainClass
            let gameArgs = plan.gameArguments
            Task.detached(priority: .userInitiated) {
                let result = ZLJVMBridge.run(javaHome: home.path, classpath: classpath, mainClass: mainClass,
                                             args: gameArgs, jvmOptions: options, logPath: logURL.path)
                await MainActor.run {
                    self.state = .finished(ok: result.status == .OK, message: result.message)
                    self.log.log(result.status == .OK ? .info : .error, "launch", "Minecraft returned (status \(result.status.rawValue)): \(result.message)")
                }
            }
        } catch {
            state = .finished(ok: false, message: String(describing: error))
            log.error("launch", "Could not start \(versionID): \(error)")
        }
    }

    static func activateAudioSession(log: Logger) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            log.info("launch", "Audio session: playback, active (output \(session.currentRoute.outputs.first?.portName ?? "?"), volume \(session.outputVolume))")
        } catch {
            log.error("launch", "Audio session setup failed: \(error)")
        }
    }

    /// Requested heap, capped at 40% of the memory iOS currently lets this app use.
    static func heapMegabytes(requested: Int) -> Int {
        let availableMB = (DeviceInfo.availableMemory ?? 0) >> 20
        guard availableMB > 0 else { return min(requested, 1024) }
        return max(512, min(requested, Int(Double(availableMB) * 0.4)))
    }

    enum LaunchError: Error, CustomStringConvertible {
        case message(String)
        var description: String {
            switch self { case .message(let m): m }
        }
    }
}
