import AVFoundation
import Foundation
import UIKit
import VoxeliumCore

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

    /// Java-side LWJGL modules every LWJGL 3 Minecraft uses (Mojang's own LWJGL entries
    /// are filtered out by GameFilePlanner and replaced with these iOS builds).
    static let lwjglModules = ["lwjgl", "lwjgl-glfw", "lwjgl-opengl", "lwjgl-openal", "lwjgl-stb", "lwjgl-tinyfd", "lwjgl-jemalloc"]
    /// Added only when the version lists them.
    static let optionalLWJGLModules = ["lwjgl-freetype", "lwjgl-vulkan"]

    /// One JVM per process: once Minecraft has been started, relaunch the app to start again.
    private static var started = false

    func launch(versionID: String, paths: AppPaths, settings: LauncherSettings, accounts: AccountModel) async {
        guard !Self.started else {
            state = .finished(ok: false, message: "A JVM already ran in this launch. Close and relaunch the app.")
            return
        }
        if case .running = state { return }
        if case .starting = state { return }

        // Who plays: the Microsoft account (token refreshed if needed) or the offline profile.
        let identity: LaunchIdentity
        if settings.useMicrosoftAccount, accounts.account != nil {
            state = .starting("Checking your Microsoft sign-in…")
            do {
                identity = try await accounts.launchIdentity()
            } catch {
                state = .finished(ok: false, message: "Microsoft sign-in: \(error). Sign in again on the Account tab, or choose the offline profile.")
                log.error("launch", "Microsoft token refresh failed: \(error)")
                return
            }
        } else {
            guard OfflineIdentity.isValidName(settings.playerName) else {
                state = .finished(ok: false, message: "Set a valid player name (3–16 letters, digits or _) on the Account tab.")
                return
            }
            identity = OfflineIdentity.identity(for: settings.playerName)
        }
        guard !Self.started else { return }
        guard let res = Bundle.main.resourceURL, let frameworks = Bundle.main.privateFrameworksURL else { return }
        let java = res.appendingPathComponent("java", isDirectory: true)
        let fm = FileManager.default

        do {
            // Mod loader profiles (Fabric, Quilt) are merged with the version they build on.
            let resolved = try VersionResolver(paths: paths).resolve(versionID)
            let version = resolved.info
            // Modded versions get their own game folder (mods, config, saves, options),
            // as with ZalithLauncher2's version isolation; vanilla versions share one.
            let gameDir = resolved.isModded ? try paths.instanceDir(versionID) : paths.gameDir
            try fm.createDirectory(at: gameDir, withIntermediateDirectories: true)
            // Forge and NeoForge start through voxelium-boot.jar, which runs their installer
            // processors in this JVM on the first launch (ForgeInstaller, ForgeLaunch).
            let forgePlan = ForgeLaunch.processorPlan(for: resolved, paths: paths)

            // Java: the smallest bundled runtime that satisfies the version (8, 17, 21, 25).
            let major = GameRuntime.javaMajor(for: version)
            let bundled = GameRuntime.bundledJava.filter {
                fm.fileExists(atPath: java.appendingPathComponent("jre\($0)/lib/server/libjvm.dylib").path)
            }
            guard let javaMajor = GameRuntime.java(for: major, available: bundled) else {
                throw LaunchError.message("\(versionID) needs Java \(major); this build bundles Java \(bundled.map(String.init).joined(separator: ", ")).")
            }
            let home = java.appendingPathComponent("jre\(javaMajor)", isDirectory: true)

            // LWJGL: the app's iOS builds stand in for Mojang's (3.3.3, or 3.4.1 for LWJGL ≥ 3.4.1).
            // Versions up to 1.12.2 (LWJGL 2) also get lwjglx, the LWJGL 2 API on top of LWJGL 3.
            let wanted = GameRuntime.lwjgl(for: version)
            let lwjgl2 = GameRuntime.needsLWJGL2Bridge(wanted)
            let build = GameRuntime.lwjglBuild(for: wanted)
            let lwjgl = java.appendingPathComponent(build == .v333 ? "lwjgl" : "lwjgl-\(build.rawValue)", isDirectory: true)
            guard fm.fileExists(atPath: lwjgl.appendingPathComponent("lwjgl.jar").path) else {
                throw LaunchError.message("\(versionID) uses LWJGL \(wanted.map { "\($0)" } ?? "?"), which needs the app's LWJGL \(build.rawValue) build; it is not in this build yet.")
            }
            let plan = try LaunchPlanner(paths: paths).plan(version: version, identity: identity, gameDirectory: gameDir,
                                                            includeClientJar: forgePlan == nil)
            if !plan.missingFiles.isEmpty {
                throw LaunchError.message("\(plan.missingFiles.count) game files are missing. Install or repair \(versionID) first.")
            }

            // Classpath: iOS LWJGL + compat stubs, then the game's libraries and client jar.
            // Extra modules newer versions list (lwjgl-freetype from 1.20.5, lwjgl-vulkan in 26.2).
            let requested = Set(version.libraries.compactMap { lib -> String? in
                let c = lib.name.split(separator: ":")
                return c.count >= 3 && c[0] == "org.lwjgl" ? String(c[1]) : nil
            })
            if requested.contains("lwjgl-sdl") {
                throw LaunchError.message("\(versionID) uses SDL and Vulkan instead of GLFW and OpenGL (Minecraft 26.3 and later). This launcher's iOS window and graphics layers do not support that yet.")
            }
            // Minecraft 26.2 (the first version to list lwjgl-vulkan) starts but draws only a
            // black screen: its shader programs fail to link on MobileGlues + ANGLE (ES 3.0).
            // Investigation paused (docs/ENGINEERING_LOG.md, 2026-10-17); refuse it clearly.
            if requested.contains("lwjgl-vulkan") {
                throw LaunchError.message("\(versionID) is not supported yet: it starts but shows only a black screen on iOS (its graphics shaders do not work on this phone's OpenGL ES layer). Minecraft up to 26.1.2 works.")
            }
            let extras = Self.optionalLWJGLModules.filter(requested.contains)
            let modules = Self.lwjglModules + extras + (lwjgl2 ? ["lwjgl-lwjglx"] : [])  // bridge last, as upstream
            let ours = (forgePlan == nil ? [] : [java.appendingPathComponent(ForgeLaunch.bootJarName)])
                + modules.map { lwjgl.appendingPathComponent("\($0).jar") }
                + [java.appendingPathComponent("voxelium-ios-compat.jar")]
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
            // Forge/NeoForge module options in the form JNI_CreateJavaVM accepts.
            jvmArgs = ForgeLaunch.jniOptions(ForgeLaunch.extendIgnoreList(jvmArgs, with: [ForgeLaunch.bootJarName]))

            // Desktop GL layer: Minecraft 1.13 - 1.16.5 (Java 8) render with fixed-function
            // GL (glFog, matrix stacks), which MobileGlues does not implement (glFogfv was
            // NULL on 1.16.5); they get gl4es, as on Amethyst and ZalithLauncher. 1.17+ use
            // MobileGlues. Both run on the app's ANGLE context.
            let useGL4ES = javaMajor == 8
            let glLibrary = frameworks.appendingPathComponent(useGL4ES ? "libgl4es.dylib" : "libmobileglues.dylib")
            guard fm.fileExists(atPath: glLibrary.path) else {
                throw LaunchError.message("Bundled file missing: \(glLibrary.lastPathComponent)")
            }

            let heap = Self.heapMegabytes(requested: settings.maxMemoryMB)
            var options = JavaTestModel.jvmOptions(paths: paths)
                .filter { !$0.hasPrefix("-Xmx") && !$0.hasPrefix("-Xms") && !$0.hasPrefix("-Duser.dir=") }
            options += [
                // One option list for Java 8–25: skip -XX flags a runtime does not know.
                "-XX:+IgnoreUnrecognizedVMOptions",
                "-Xms256M",
                "-Xmx\(heap)M",
                "-Djava.awt.headless=true",
                "-Dlog4j2.formatMsgNoLookups=true",
                // Sodium 0.5 (Minecraft 1.20.x) refuses to start unless LWJGL is exactly
                // 3.3.1 ("currently active LWJGL version is not compatible", seen with a
                // 1.20.1 modpack, 2026-10-18); Voxelium ships 3.3.3. Sodium's own switch
                // (BugChecks "sodium.checks.issue2561") turns that check off.
                "-Dsodium.checks.issue2561=false",
                "-Dorg.lwjgl.librarypath=\(lwjgl.path)",
                "-Dorg.lwjgl.glfw.libname=\(VXGLFWLibraryPath())",
                "-Dorg.lwjgl.glfw.checkThread0=false",
                "-Dorg.lwjgl.opengl.libname=\(glLibrary.path)",
                "-Dorg.lwjgl.system.allocator=system",
                // Minecraft resolves logs/, crash-reports/ etc. against the working directory.
                "-Duser.dir=\(gameDir.path)",
            ]
            // The iOS Java 8 build's C2 compiler asked for a 128 MB arena while emitting
            // safepoint polls (ConcurrentHashMap.putVal) and the JVM died with "Out of
            // Memory Error (allocation.cpp:389)" on 1.13.2 (hs_err, 2026-10-17).
            // Use the C1 JIT only on Java 8.
            if javaMajor == 8 { options.append("-XX:TieredStopAtLevel=1") }
            // iOS kills the app at a fixed footprint (3376 MB on an iPhone 15 Pro Max,
            // "exceeded mem limit: ActiveHard", 2026-10-18 with shader packs), and a Java
            // heap that grew once never shrinks by default. Give freed heap back to iOS
            // (G1: shrink to at most 30% free after a collection, and collect every 15 s
            // when idle so that happens), and log each collection's heap use to jvm.log.
            if javaMajor >= 9 {
                options += ["-XX:MinHeapFreeRatio=10", "-XX:MaxHeapFreeRatio=30", "-XX:G1PeriodicGCInterval=15000",
                            "-Xlog:gc:stdout"]
            }
            // Diagnostics: when logs/lwjgl-debug contains "on", LWJGL logs GL functions it
            // cannot find and extensions it rejects (to stderr, i.e. jvm.log). Off by default.
            let lwjglDebugFlag = (try? String(contentsOf: paths.logsDir.appendingPathComponent("lwjgl-debug"), encoding: .utf8)) ?? ""
            if lwjglDebugFlag.trimmingCharacters(in: .whitespacesAndNewlines) == "on" {
                options += ["-Dorg.lwjgl.util.Debug=true", "-Dorg.lwjgl.util.DebugFunctions=true", "-Dorg.lwjgl.util.DebugLoader=true"]
                log.info("launch", "LWJGL debug output on (logs/lwjgl-debug)")
            }
            if let forgePlan {
                options += ["-Dvoxelium.processors=\(forgePlan.path)", "-Dvoxelium.mainClass=\(plan.mainClass)"]
                try ForgeLaunch.disableEarlyWindow(gameDirectory: gameDir)
            }
            options += jvmArgs

            // iOS gives an app the "solo ambient" audio category by default, which
            // the silent switch / Action button mutes. A game should play anyway.
            Self.activateAudioSession(log: log)
            // The process cwd is "/" on iOS; log4j's logs/latest.log is relative to it.
            fm.changeCurrentDirectoryPath(gameDir.path)
            let mgDir = paths.logsDir.appendingPathComponent("mobileglues", isDirectory: true)
            try? fm.createDirectory(at: mgDir, withIntermediateDirectories: true)
            setenv("MG_DIR_PATH", mgDir.path, 1)
            // On-screen controls: the user's layout (Controls tab) or the default, read by VXGLFW.
            let screen = UIScreen.main.bounds.size
            let controlsLayout = ControlLayoutStore(paths: paths)
                .effective(width: max(screen.width, screen.height), height: min(screen.width, screen.height), log: log)
            let controlsURL = paths.controlsDir.appendingPathComponent("active.json")
            do {
                try ControlLayoutStore.write(controlsLayout, to: controlsURL)
                setenv("VOXELIUM_CONTROLS_PATH", controlsURL.path, 1)
            } catch {
                log.error("launch", "Could not write the control layout, using the built-in one: \(error)")
            }
            // Render resolution (Account tab; default half the native pixels, since 2796x1290 is a lot for a phone GPU).
            let renderScale = min(max(settings.renderScale, LauncherSettings.renderScaleRange.lowerBound), LauncherSettings.renderScaleRange.upperBound)
            setenv("VOXELIUM_RENDER_SCALE", String(format: "%.2f", renderScale), 1)

            let logURL = paths.logsDir.appendingPathComponent("jvm.log")
            let header = "\n===== Minecraft \(versionID) \(ISO8601DateFormatter().string(from: Date())) java=\(javaMajor) heap=\(heap)M \(VXJVMBridge.jitDescription())\n"
            if let h = try? FileHandle(forWritingTo: logURL) {
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: Data(header.utf8))
                try? h.close()
            } else {
                fm.createFile(atPath: logURL.path, contents: Data(header.utf8))
            }

            log.info("launch", "Starting Minecraft \(versionID)\(resolved.isModded ? " (on \(resolved.chain.dropFirst().joined(separator: " → ")), own game folder)" : "") as \(identity.playerName) (\(identity.userType)): Java \(javaMajor) (asks \(major)), LWJGL \(build.rawValue) for \(wanted.map { "\($0)" } ?? "?"), GL \(useGL4ES ? "gl4es" : "MobileGlues"), heap \(heap) MB, render scale \(Int(renderScale * 100))%, \(ours.count + plan.classpath.count) classpath entries, \(options.count) JVM options")
            Self.started = true
            if !useGL4ES { MobileGluesSession.used = true }
            // The app's GLFW resolves glfwGetProcAddress from this library.
            setenv("VOXELIUM_GL_LIBRARY", glLibrary.path, 1)
            if useGL4ES {
                // gl4es loads GLES from here (ANGLE) and uses its GLES 2 backend.
                setenv("LIBGL_GLES", frameworks.appendingPathComponent("libGLESv2.framework/libGLESv2").path, 1)
                setenv("LIBGL_ES", "2", 1)
            }
            if let forgePlan, !ForgeInstaller.processorsDone(forgePlan) {
                state = .running("Setting up \(LauncherModel.loaderName(of: resolved) ?? "the mod loader") for its first launch. This takes a minute or two, then Minecraft starts. Its log goes to logs/jvm.log.")
            } else {
                state = .running("Minecraft \(versionID) is running. Its log goes to logs/jvm.log.")
            }

            let mainClass = forgePlan == nil ? plan.mainClass : ForgeLaunch.bootMainClass
            let gameArgs = plan.gameArguments
            Task.detached(priority: .userInitiated) {
                let result = VXJVMBridge.run(javaHome: home.path, classpath: classpath, mainClass: mainClass,
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
