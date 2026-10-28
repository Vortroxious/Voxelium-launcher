import Foundation
import UIKit
import VoxeliumCore

/// Gets JIT before a game starts (docs/JIT_INTEGRATION_PLAN.md, Phase 1).
///
/// - Already debugged (opened from StikDebug, or a hand-off earlier in this launch) and,
///   on TXM devices, the JIT script still answers: nothing to do.
/// - Otherwise opens StikDebug's `enable-jit` link for this process (with UniversalJIT26.js
///   on TXM devices) and waits until JIT is ready, the player cancels, or 2 minutes pass.
///   Coming back to Voxelium checks again at once.
@MainActor
final class JITCoordinator {
    enum Outcome: Equatable {
        case ready
        case cancelled
        case problem(JITProblem)
    }

    /// Read once: the signature does not change while the app runs.
    static let getTaskAllow = VXJITGetTaskAllow()

    /// StikDebug can be opened (needs LSApplicationQueriesSchemes in Voxelium-Info.plist).
    static var stikDebugInstalled: Bool {
        StikDebugJIT.schemes.contains { UIApplication.shared.canOpenURL(URL(string: "\($0)://")!) }
    }

    private let log = Logger.shared
    private var wait: JITWait?

    func cancel() { wait?.cancel() }

    /// Debugger flag, and on TXM devices whether UniversalJIT26.js answers the probe.
    /// The probe runs off the main thread: while StikDebug is attaching it can pause the
    /// probing thread until the script handles the breakpoint.
    static func readiness() async -> JITReadiness {
        let debugged = VXJITDebuggerAttached()
        guard debugged, VXJITNeedsScript() else {
            return JITReadiness.evaluate(debugged: debugged, probe: .notNeeded, expectedReply: VXJIT26UniversalProbeReply)
        }
        let (trapped, value) = await Task.detached { () -> (Bool, UInt64) in
            let r = VXJIT26Probe()
            return (r.trapped, UInt64(UInt(bitPattern: r.value)))
        }.value
        return JITReadiness.evaluate(debugged: true, probe: trapped ? .noAnswer : .answered(value),
                                     expectedReply: VXJIT26UniversalProbeReply)
    }

    /// `status` shows progress while waiting for StikDebug.
    func ensureJIT(status: @escaping (String) -> Void) async -> Outcome {
        let first = await Self.readiness()
        switch first {
        case .ready: return .ready
        case .problem(let p):
            log.error("jit", "\(p.title): \(VXJVMBridge.jitDescription())")
            return .problem(p)
        case .needsDebugger: break
        }
        if Self.getTaskAllow == 0 {
            log.error("jit", "get-task-allow is missing from this install's signature: no debugger can attach")
            return .problem(.missingGetTaskAllow)
        }

        let bundleID = Bundle.main.bundleIdentifier ?? "io.github.voxelium.launcher"
        let needsScript = VXJITNeedsScript()
        let script: Data? = needsScript
            ? Bundle.main.url(forResource: "UniversalJIT26", withExtension: "js").flatMap { try? Data(contentsOf: $0) }
            : nil
        let alreadyDebugged = VXJITDebuggerAttached()
        log.info("jit", "Asking StikDebug for JIT (pid \(getpid()), \(script.map { "UniversalJIT26.js, \($0.count) bytes" } ?? "no script")\(alreadyDebugged ? ", debugged before but the script is gone" : ""))")

        var opened = false
        for scheme in StikDebugJIT.schemes {
            let url = StikDebugJIT.enableJITURL(bundleID: bundleID, pid: getpid(), script: script, scheme: scheme)
            if await UIApplication.shared.open(url) {
                log.info("jit", "Opened StikDebug with \(scheme)://enable-jit")
                opened = true
                break
            }
            log.warning("jit", "iOS did not open \(scheme)://enable-jit")
        }
        guard opened else { return .problem(.stikDebugMissing) }

        status("Turning on JIT in StikDebug… Confirm there, and StikDebug brings you back.")
        let wait = JITWait()
        self.wait = wait
        let back = ReturnTime()
        let observer = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                              object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if back.date == nil { back.date = Date() }
                wait.nudge()
            }
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            self.wait = nil
        }

        let started = Date()
        var hinted = false
        let outcome = await wait.run(timeout: .seconds(120), poll: .milliseconds(200)) {
            if !hinted, let date = back.date, Date().timeIntervalSince(date) > 5 {
                hinted = true
                status("Still waiting for StikDebug. If you declined there or it showed an error, tap Cancel and try again.")
            }
            return await Self.readiness()
        }
        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        switch outcome {
        case .ready:
            log.info("jit", "JIT is on after \(seconds) s: \(VXJVMBridge.jitDescription())")
            return .ready
        case .cancelled:
            log.info("jit", "Waiting for StikDebug cancelled after \(seconds) s")
            return .cancelled
        case .problem(let p):
            log.error("jit", "\(p.title) after \(seconds) s: \(VXJVMBridge.jitDescription())")
            return .problem(p)
        case .timedOut:
            // Debugged (now or before) but the script never answered: on TXM devices that is
            // the script, not the connection.
            let p: JITProblem = needsScript && VXJITDebuggerAttached() ? .scriptNotAttached : .timedOut
            log.error("jit", "No JIT after \(seconds) s (\(p.title)): \(VXJVMBridge.jitDescription())")
            return .problem(p)
        }
    }
}

/// When Voxelium came back to the foreground during a wait.
@MainActor
private final class ReturnTime {
    var date: Date?
}
