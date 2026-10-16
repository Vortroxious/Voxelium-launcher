import Foundation
import SwiftUI
import ZalithCore

/// Milestone 5: start the bundled iOS JRE inside this process and run a
/// small Java program. Proves (or disproves) gate A on a real device.
@MainActor
final class JavaTestModel: ObservableObject {
    enum State: Equatable {
        case idle
        case running
        case finished(ok: Bool, message: String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var log = ""
    @Published private(set) var jitDescription = ZLJVMBridge.jitDescription()

    private let logger = Logger.shared

    static var bundledJavaHome: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("java/jre17", isDirectory: true)
    }

    static var bundledTestJar: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("java/zalith-javatest.jar")
    }

    var runtimeBundled: Bool {
        guard let home = Self.bundledJavaHome else { return false }
        return FileManager.default.fileExists(atPath: home.appendingPathComponent("lib/server/libjvm.dylib").path)
    }

    func refreshJIT() { jitDescription = ZLJVMBridge.jitDescription() }

    func run(paths: AppPaths) {
        guard state != .running, let home = Self.bundledJavaHome, let jar = Self.bundledTestJar else { return }
        refreshJIT()
        let logURL = paths.logsDir.appendingPathComponent("jvm.log")
        // Append, never wipe: a crashed run's output is the evidence we need.
        let header = "\n===== Java test \(ISO8601DateFormatter().string(from: Date())) \(jitDescription)\n"
        if let h = try? FileHandle(forWritingTo: logURL) {
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(header.utf8))
            try? h.close()
        } else {
            FileManager.default.createFile(atPath: logURL.path, contents: Data(header.utf8))
        }
        let options = Self.jvmOptions(paths: paths)
        logger.info("java", "Starting JVM test: \(jitDescription)")
        state = .running

        Task.detached(priority: .userInitiated) {
            let result = ZLJVMBridge.run(
                javaHome: home.path,
                classpath: jar.path,
                mainClass: "io.github.zalithios.JavaSmokeTest",
                args: [],
                jvmOptions: options,
                logPath: logURL.path
            )
            let all = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            // Only this run's section.
            let text = all.range(of: header).map { String(all[$0.upperBound...]) } ?? all
            let ok = result.status == .OK && text.contains("ZALITH_JAVA_OK")
            await MainActor.run {
                self.log = text
                self.state = .finished(ok: ok, message: result.message)
                self.logger.log(ok ? .info : .error, "java", "JVM test finished (status \(result.status.rawValue)): \(result.message)")
            }
        }
    }

    /// Flags mirror Amethyst-iOS's JavaLauncher.m for a free developer account.
    static func jvmOptions(paths: AppPaths) -> [String] {
        var o = [
            "-Xms64M",
            "-Xmx256M",
            "-Djava.io.tmpdir=\(NSTemporaryDirectory())",
            "-Duser.home=\(paths.root.path)",
            "-Duser.dir=\(paths.root.path)",
            // HotSpot's own crash report lands next to our logs.
            "-XX:ErrorFile=\(paths.logsDir.path)/hs_err_pid%p.log",
            "-XX:+UnlockExperimentalVMOptions",
            "-XX:+DisablePrimordialThreadGuardPages",
            // No extended-virtual-addressing entitlement on a free account.
            "-XX:-UseCompressedClassPointers",
        ]
        if #available(iOS 26.0, *) {
            o.append("-XX:+MirrorMappedCodeCache")
        }
        return o
    }
}

struct JavaTestSection: View {
    @ObservedObject var test: JavaTestModel
    let paths: AppPaths?

    var body: some View {
        Section {
            LabeledContent("Runtime bundled", value: test.runtimeBundled ? "Java 17 (iOS arm64)" : "No")
            Text(test.jitDescription).font(.caption.monospaced()).textSelection(.enabled)
            switch test.state {
            case .idle:
                Button("Run Java test") { if let paths { test.run(paths: paths) } }
                    .disabled(!test.runtimeBundled || paths == nil)
            case .running:
                HStack { ProgressView(); Text("Running Java…") }
            case .finished(let ok, let message):
                Label(ok ? "Java ran: ZALITH_JAVA_OK" : "Java test failed", systemImage: ok ? "checkmark.seal.fill" : "xmark.octagon.fill")
                    .foregroundStyle(ok ? Color.green : Color.red)
                Text(message).font(.caption)
                Text("Restart the app to run the test again (one JVM per process).").font(.caption2).foregroundStyle(.secondary)
            }
            if !test.log.isEmpty {
                ScrollView(.horizontal) {
                    Text(test.log).font(.caption2.monospaced()).textSelection(.enabled)
                }
                .frame(maxHeight: 260)
            }
        } header: {
            Text("Java runtime test (Milestone 5)")
        } footer: {
            Text("Needs JIT: open StikDebug, assign the Universal JIT script to this app, and launch it from StikDebug.")
        }
        .onAppear { test.refreshJIT() }
    }
}
