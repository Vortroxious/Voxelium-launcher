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

        #if VOXELIUM_JIT_HELPER_SPIKE
        if BuiltInJITSpike.useForPlay {
            if let pairing = BuiltInJITSpike.pairingData {
                return await ensureWithHelper(pairing: pairing, status: status)
            }
            // No pairing file: StikDebug can still turn on JIT if it's installed.
            guard Self.stikDebugInstalled else {
                log.error("jit", "Built-in JIT is on but no pairing file is imported, and StikDebug isn't installed")
                return .problem(.pairingFileMissing)
            }
            log.info("jit", "No pairing file imported: asking StikDebug instead")
        }
        #endif

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

#if VOXELIUM_JIT_HELPER_SPIKE
extension JITCoordinator {
    /// Spike (docs/JIT_INTEGRATION_PLAN.md, Phase 2): JIT from the built-in helper
    /// extension (StikJIT), with no switch to StikDebug. Readiness is the same check as
    /// for StikDebug; the helper's own answer only matters when it fails, because on TXM
    /// devices it answers only after the JIT script detached, which is after the JVM
    /// got its code cache.
    func ensureWithHelper(pairing: Data, status: @escaping (String) -> Void) async -> Outcome {
        guard let script = Bundle.main.url(forResource: "UniversalJIT26", withExtension: "js").flatMap({ try? Data(contentsOf: $0) }) else {
            return .problem(.helperFailed("UniversalJIT26.js is missing from the app."))
        }
        let needsScript = VXJITNeedsScript()
        let log = Logger.shared
        log.info("jit", "Asking the built-in helper for JIT (pid \(getpid()), \(needsScript ? "script forced (TXM)" : "no script needed"))")
        status("Turning on JIT with the built-in helper…")
        let wait = JITWait()
        self.wait = wait
        defer { self.wait = nil }
        let failure = HelperFailure()
        VXJITHelperEnableJIT(getpid(), pairing, script, needsScript, { stage in
            MainActor.assumeIsolated {
                let text = BuiltInJITSpike.stageText(stage)
                log.info("jit", "Helper stage \(stage): \(text)")
                status(text)
            }
        }, { ok, error, lines in
            MainActor.assumeIsolated {
                for line in lines { log.info("jit", "Helper: \(line)") }
                if ok {
                    log.info("jit", "Helper finished: JIT script done")
                } else {
                    log.error("jit", "Helper failed: \(error ?? "?")")
                    failure.reason = error ?? "The helper gave no reason."
                    wait.nudge()
                }
            }
        })

        let started = Date()
        let outcome = await wait.run(timeout: .seconds(180), poll: .milliseconds(200)) {
            if let reason = failure.reason { return .problem(.fromHelperError(reason)) }
            return await Self.readiness()
        }
        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        switch outcome {
        case .ready:
            log.info("jit", "JIT is on (built-in helper) after \(seconds) s: \(VXJVMBridge.jitDescription())")
            return .ready
        case .cancelled:
            return .cancelled
        case .problem(let p):
            log.error("jit", "\(p.title) after \(seconds) s: \(VXJVMBridge.jitDescription())")
            return .problem(p)
        case .timedOut:
            log.error("jit", "No JIT from the helper after \(seconds) s: \(VXJVMBridge.jitDescription())")
            return .problem(.helperFailed("JIT wasn't on after 3 minutes."))
        }
    }
}

/// The helper's failure, if it reports one while Voxelium waits.
@MainActor
private final class HelperFailure {
    var reason: String?
}
#endif
