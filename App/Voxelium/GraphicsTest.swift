import SwiftUI
import UIKit
import VoxeliumCore

/// MobileGlues keeps GL state (VAO/buffer/program bookkeeping) process-wide,
/// keyed by object name, and cannot be reset; only the first context it serves
/// in a process behaves. Minecraft uses one context per launch, so each
/// MobileGlues test (native or Java) is limited to one per app launch.
enum MobileGluesSession {
    @MainActor static var used = false
}

/// Milestone 6 step 1: OpenGL ES through ANGLE/Metal, verified by pixel read-back.
@MainActor
final class GraphicsTestModel: ObservableObject {
    enum State: Equatable {
        case idle
        case running
        case finished(ok: Bool)
    }

    @Published var state: State = .idle
    @Published var report = ""
    @Published var presenting = false
    /// Run through MobileGlues (desktop GL 3.3 shaders) instead of plain GLES.
    @Published var desktopGL = false

    var bundled: Bool { VXGLTestRuntimeBundled() }
    var mobileGluesBundled: Bool { VXMobileGluesBundled() }

    func start(desktopGL: Bool) {
        if desktopGL {
            guard !MobileGluesSession.used else { return }
            MobileGluesSession.used = true
        }
        self.desktopGL = desktopGL
        state = .running
        presenting = true
    }

    func finish(ok: Bool, report: String) {
        self.report = report
        state = .finished(ok: ok)
        let name = desktopGL ? "Desktop GL (MobileGlues) test" : "GL test"
        Logger.shared.log(ok ? .info : .error, "gl", ok ? "\(name) passed" : "\(name) failed")
    }
}

struct GLTestController: UIViewControllerRepresentable {
    let logPath: String?
    let desktopGL: Bool
    let mobileGluesDir: String?
    let onFinish: (Bool, String) -> Void

    func makeUIViewController(context: Context) -> VXGLTestViewController {
        let vc = VXGLTestViewController()
        vc.logPath = logPath
        vc.useMobileGlues = desktopGL
        vc.mobileGluesDir = mobileGluesDir
        vc.onFinish = { ok, report in onFinish(ok, report) }
        return vc
    }

    func updateUIViewController(_ vc: VXGLTestViewController, context: Context) {}
}

struct GraphicsTestSection: View {
    @ObservedObject var test: GraphicsTestModel
    let paths: AppPaths?

    var body: some View {
        Section {
            LabeledContent("ANGLE bundled", value: test.bundled ? "Yes (Metal backend)" : "No")
            LabeledContent("MobileGlues bundled", value: test.mobileGluesBundled ? "Yes (desktop GL on ANGLE)" : "No")
            switch test.state {
            case .idle:
                Button("Run graphics test") { test.start(desktopGL: false) }
                    .disabled(!test.bundled)
                Button("Run desktop GL test (MobileGlues)") { test.start(desktopGL: true) }
                    .disabled(!test.mobileGluesBundled || MobileGluesSession.used)
            case .running:
                HStack { ProgressView(); Text("Rendering…") }
            case .finished(let ok):
                Label(ok ? (test.desktopGL ? "Desktop GL via MobileGlues: VOXELIUM_DESKTOPGL_OK" : "OpenGL ES drew and read back correctly: VOXELIUM_GL_OK")
                         : "Graphics test failed",
                      systemImage: ok ? "checkmark.seal.fill" : "xmark.octagon.fill")
                    .foregroundStyle(ok ? Color.green : Color.red)
                Button("Run graphics test again") { test.start(desktopGL: false) }
                Button("Run desktop GL test (MobileGlues)") { test.start(desktopGL: true) }
                    .disabled(!test.mobileGluesBundled || MobileGluesSession.used)
            }
            if MobileGluesSession.used {
                Text("MobileGlues has been used in this launch. Close and relaunch the app to run another MobileGlues test.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            #if VOXELIUM_ZINK_EXPERIMENT
            ZinkTestRows(paths: paths)
            #endif
            if !test.report.isEmpty {
                ScrollView(.horizontal) {
                    Text(test.report).font(.caption2.monospaced()).textSelection(.enabled)
                }
                .frame(maxHeight: 220)
            }
        } header: {
            Text("Graphics test (Milestone 6)")
        } footer: {
            Text("Draws a triangle for about 2 seconds, then checks pixels: with OpenGL ES 3 on ANGLE, or with desktop GL 3.3 shaders through MobileGlues on ANGLE. Does not need JIT. One MobileGlues test (native or Java) per app launch.")
        }
        .fullScreenCover(isPresented: $test.presenting) {
            GLTestController(
                logPath: paths.map { $0.logsDir.appendingPathComponent("gl.log").path },
                desktopGL: test.desktopGL,
                mobileGluesDir: paths.map { $0.logsDir.appendingPathComponent("mobileglues", isDirectory: true).path }
            ) { ok, report in
                test.finish(ok: ok, report: report)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { test.presenting = false }
            }
            .ignoresSafeArea()
        }
    }
}

#if VOXELIUM_ZINK_EXPERIMENT
/// Zink and its Vulkan driver cannot be unloaded or set up a second time in a
/// process, so, like MobileGlues, the Zink test runs once per app launch.
enum ZinkSession {
    @MainActor static var used = false
}

/// Compute-shader feasibility spike (experimental IPA only): desktop GL 4.6
/// through Mesa's Zink on Vulkan, run headless, logged to logs/zink.log.
@MainActor
final class ZinkTestModel: ObservableObject {
    @Published var running = false
    @Published var result: Bool?
    @Published var report = ""
    private var test: VXZinkTest?

    var bundled: Bool { VXZinkBundled() }
    var driver: String? { VXZinkVulkanDriverName() }

    func start(paths: AppPaths?, versionOverride: Bool) {
        guard !ZinkSession.used else { return }
        ZinkSession.used = true
        running = true
        result = nil
        report = ""
        let test = VXZinkTest()
        if let logs = paths?.logsDir {
            try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            test.logPath = logs.appendingPathComponent("zink.log").path
            test.mesaLogPath = logs.appendingPathComponent("zink-mesa.log").path
        }
        test.versionOverride = versionOverride
        test.onFinish = { ok, report in
            Task { @MainActor in self.finish(ok: ok, report: report) }
        }
        self.test = test
        test.start()
    }

    private func finish(ok: Bool, report: String) {
        running = false
        result = ok
        self.report = report
        test = nil
        Logger.shared.log(ok ? .info : .error, "gl", ok ? "Zink test passed" : "Zink test failed")
    }
}

/// Experimental builds: play Minecraft 1.17+ through Zink (desktop GL 4.6 on
/// KosmicKrisp) instead of MobileGlues. Read by MinecraftLauncher at launch.
enum ZinkRenderer {
    static let defaultsKey = "VoxeliumZinkRenderer"
    static var enabled: Bool { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
}

struct ZinkTestRows: View {
    @StateObject private var test = ZinkTestModel()
    @AppStorage(ZinkRenderer.defaultsKey) private var playWithZink = true
    @State private var swapchainTest = false
    @State private var swapchainResult: Bool?
    @State private var swapchainReport = ""
    let paths: AppPaths?

    var body: some View {
        LabeledContent("Zink bundled", value: test.driver.map { "Yes (\($0))" } ?? "No")
        // The cover hangs on the button: a List drops an EmptyView row, and its
        // fullScreenCover with it (nothing happened on tap, build 202610231121).
        Button("Vulkan swapchain test (KosmicKrisp WSI)") { swapchainTest = true }
            .disabled(!VXVulkanWSIBundled())
            .fullScreenCover(isPresented: $swapchainTest) {
                VulkanSwapchainTestController(
                    logPath: paths.map { $0.logsDir.appendingPathComponent("vulkan-swapchain.log").path }
                ) { ok, report in
                    swapchainResult = ok
                    swapchainReport = report
                    Logger.shared.log(ok ? .info : .error, "gl", ok ? "Vulkan swapchain test passed" : "Vulkan swapchain test failed")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { swapchainTest = false }
                }
                .ignoresSafeArea()
            }
        if let ok = swapchainResult {
            Label(ok ? "Vulkan swapchain: VOXELIUM_VK_SWAPCHAIN_OK" : "Vulkan swapchain test failed",
                  systemImage: ok ? "checkmark.seal.fill" : "xmark.octagon.fill")
                .foregroundStyle(ok ? Color.green : Color.red)
        }
        Toggle("Play with Zink (experimental)", isOn: $playWithZink)
            .disabled(!test.bundled)
        Text("Minecraft 1.17+ renders with desktop GL 4.6 on Zink instead of MobileGlues. Needs iOS 26. Not in the same launch as the Zink test.")
            .font(.caption2).foregroundStyle(.secondary)
        if test.running {
            HStack { ProgressView(); Text("Running Zink test…") }
        } else if let ok = test.result {
            Label(ok ? "Zink: VOXELIUM_ZINK_OK" : "Zink test failed",
                  systemImage: ok ? "checkmark.seal.fill" : "xmark.octagon.fill")
                .foregroundStyle(ok ? Color.green : Color.red)
        }
        // Zink on Metal reports GL 2.1 without MESA_GL_VERSION_OVERRIDE, so the
        // 4.6 override (with the compute check) is the main test.
        Button("Zink test (experimental)") { test.start(paths: paths, versionOverride: true) }
            .disabled(!test.bundled || ZinkSession.used)
        Button("Zink test, native GL version (no override)") { test.start(paths: paths, versionOverride: false) }
            .disabled(!test.bundled || ZinkSession.used)
        if ZinkSession.used && !test.running {
            Text("Zink has run in this launch. Close and relaunch the app to run it again. Log: logs/zink.log")
                .font(.caption2).foregroundStyle(.secondary)
        }
        if !test.report.isEmpty {
            ScrollView(.horizontal) {
                Text(test.report).font(.caption2.monospaced()).textSelection(.enabled)
            }
            .frame(maxHeight: 220)
        }
        if !swapchainReport.isEmpty {
            ScrollView(.horizontal) {
                Text(swapchainReport).font(.caption2.monospaced()).textSelection(.enabled)
            }
            .frame(maxHeight: 220)
        }
    }
}

struct VulkanSwapchainTestController: UIViewControllerRepresentable {
    let logPath: String?
    let onFinish: (Bool, String) -> Void

    func makeUIViewController(context: Context) -> VXVulkanSwapchainTestViewController {
        let vc = VXVulkanSwapchainTestViewController()
        vc.logPath = logPath
        vc.onFinish = { ok, report in onFinish(ok, report) }
        return vc
    }

    func updateUIViewController(_ vc: VXVulkanSwapchainTestViewController, context: Context) {}
}
#endif
