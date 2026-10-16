import SwiftUI
import UIKit
import ZalithCore

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

    var bundled: Bool { ZLGLTestRuntimeBundled() }

    func finish(ok: Bool, report: String) {
        self.report = report
        state = .finished(ok: ok)
        Logger.shared.log(ok ? .info : .error, "gl", ok ? "GL test passed" : "GL test failed")
    }
}

struct GLTestController: UIViewControllerRepresentable {
    let logPath: String?
    let onFinish: (Bool, String) -> Void

    func makeUIViewController(context: Context) -> ZLGLTestViewController {
        let vc = ZLGLTestViewController()
        vc.logPath = logPath
        vc.onFinish = { ok, report in onFinish(ok, report) }
        return vc
    }

    func updateUIViewController(_ vc: ZLGLTestViewController, context: Context) {}
}

struct GraphicsTestSection: View {
    @ObservedObject var test: GraphicsTestModel
    let paths: AppPaths?

    var body: some View {
        Section {
            LabeledContent("ANGLE bundled", value: test.bundled ? "Yes (Metal backend)" : "No")
            switch test.state {
            case .idle:
                Button("Run graphics test") {
                    test.state = .running
                    test.presenting = true
                }
                .disabled(!test.bundled)
            case .running:
                HStack { ProgressView(); Text("Rendering…") }
            case .finished(let ok):
                Label(ok ? "OpenGL ES drew and read back correctly: ZALITH_GL_OK" : "Graphics test failed",
                      systemImage: ok ? "checkmark.seal.fill" : "xmark.octagon.fill")
                    .foregroundStyle(ok ? Color.green : Color.red)
                Button("Run again") {
                    test.state = .running
                    test.presenting = true
                }
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
            Text("Draws a triangle with OpenGL ES 3 through ANGLE on Metal for about 2 seconds, then checks pixels. Does not need JIT.")
        }
        .fullScreenCover(isPresented: $test.presenting) {
            GLTestController(logPath: paths.map { $0.logsDir.appendingPathComponent("gl.log").path }) { ok, report in
                test.finish(ok: ok, report: report)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { test.presenting = false }
            }
            .ignoresSafeArea()
        }
    }
}
