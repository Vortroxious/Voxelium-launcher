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
