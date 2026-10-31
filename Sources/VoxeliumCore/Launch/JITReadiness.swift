import Foundation

/// Why Voxelium could not get JIT for a game start, with what to tell the player.
/// (docs/JIT_INTEGRATION_PLAN.md, Phase 1: one specific message per cause.)
public enum JITProblem: Equatable, Sendable {
    /// iOS refused to open StikDebug's link: StikDebug is not installed.
    case stikDebugMissing
    /// StikDebug was opened, but no debugger (or, on TXM devices, no JIT script) arrived in time.
    case timedOut
    /// This install was signed without `get-task-allow`, so no debugger can attach.
    case missingGetTaskAllow
    /// A debugger attached, but the JIT script that answers the JVM's breakpoints did not.
    case scriptNotAttached
    /// A different JIT script answered the probe (its reply is kept for the log).
    case wrongScript(reply: UInt64)
    /// Built-in JIT (spike) is chosen but no pairing file is imported, and StikDebug
    /// isn't installed to fall back on.
    case pairingFileMissing
    /// The built-in JIT helper (spike) couldn't use the imported pairing file: it isn't
    /// one, or it no longer matches this iPhone.
    case pairingFileInvalid
    /// The built-in JIT helper (spike) couldn't connect to the iPhone's developer services:
    /// LocalDevVPN is off or not connected.
    case vpnNotConnected
    /// The built-in JIT helper (spike) reported an error.
    case helperFailed(String)

    /// The problem for an error the helper reported. Connection failures become
    /// `.vpnNotConnected`, pairing failures `.pairingFileInvalid`; anything else is shown
    /// as the helper wrote it.
    public static func fromHelperError(_ error: String) -> JITProblem {
        let e = error.lowercased()
        let connectFailure = ["timeout", "timed out", "refused", "unreachable", "no route"].contains { e.contains($0) }
        if e.contains("connect") && connectFailure { return .vpnNotConnected }
        if ["pairing", "invalidhostid", "pair verify"].contains(where: { e.contains($0) }) { return .pairingFileInvalid }
        return .helperFailed(error)
    }

    public var title: String {
        switch self {
        case .stikDebugMissing: "StikDebug isn't installed"
        case .timedOut: "JIT wasn't turned on"
        case .missingGetTaskAllow: "This install can't get JIT"
        case .scriptNotAttached: "StikDebug's JIT script didn't start"
        case .wrongScript: "StikDebug ran a different JIT script"
        case .pairingFileMissing: "Import a pairing file"
        case .pairingFileInvalid: "This pairing file doesn't work"
        case .vpnNotConnected: "LocalDevVPN isn't connected"
        case .helperFailed: "The built-in JIT helper failed"
        }
    }

    public var message: String {
        switch self {
        case .stikDebugMissing:
            "Minecraft needs JIT, and Voxelium gets it from StikDebug. Install StikDebug and LocalDevVPN and import a pairing file (see the setup guide), then tap Play again."
        case .timedOut:
            "StikDebug didn't turn on JIT for Voxelium. You may have declined its prompt, or it couldn't connect: check that LocalDevVPN is connected and StikDebug has a pairing file (on mobile data, turn on Airplane Mode just before Play). Then tap Play again."
        case .missingGetTaskAllow:
            "Voxelium was signed without the get-task-allow entitlement, so StikDebug can't attach to it. Reinstall Voxelium with Sideloadly using your Apple ID (a development signature), then try again."
        case .scriptNotAttached:
            "StikDebug attached to Voxelium but its JIT script isn't running, and this iPhone needs it. Tap Play again so Voxelium can ask StikDebug once more. If it keeps happening, update StikDebug."
        case .wrongScript(let reply):
            "StikDebug answered with another JIT script (reply 0x\(String(reply, radix: 16, uppercase: true))). In StikDebug, remove any script you assigned to Voxelium, then close Voxelium and tap Play again."
        case .pairingFileMissing:
            "Voxelium turns on JIT itself, and needs this iPhone's pairing file for that. Make one on a computer (see the setup guide), import it in the JIT tab, then tap Play again."
        case .pairingFileInvalid:
            "The imported pairing file isn't a valid pairing file for this iPhone, or it's out of date (after resetting trust or erasing the iPhone, for example). Make a new one on a computer (see the setup guide), import it in the JIT tab, then tap Play again."
        case .vpnNotConnected:
            "Voxelium turns on JIT through LocalDevVPN, and couldn't reach it. Open LocalDevVPN, connect it (it should say Connected), then tap Play again."
        case .helperFailed(let reason):
            "\(reason) Check that LocalDevVPN is connected and the pairing file is current, then close Voxelium and tap Play again. To use StikDebug instead, turn off the built-in helper in Diagnostics."
        }
    }

    /// Show a link to the install guide with the message.
    public var showsSetupGuide: Bool {
        switch self {
        case .stikDebugMissing, .timedOut, .missingGetTaskAllow, .pairingFileMissing, .pairingFileInvalid, .vpnNotConnected: true
        case .scriptNotAttached, .wrongScript, .helperFailed: false
        }
    }
}

/// Whether the JIT script answered the JIT26 probe (`brk #0x69`, see JITSupport.h).
public enum JITProbe: Equatable, Sendable {
    /// No TXM: the debugger flag alone is enough, nothing to probe.
    case notNeeded
    /// The breakpoint reached our own trap handler: no script is attached right now.
    case noAnswer
    /// A script answered with this value in x0.
    case answered(UInt64)
}

public enum JITReadiness: Equatable, Sendable {
    case ready
    /// Ask StikDebug (again): no debugger yet, or on TXM devices no script attached.
    case needsDebugger
    case problem(JITProblem)

    /// `expectedReply`: what UniversalJIT26.js returns for the probe
    /// (`VXJIT26UniversalProbeReply`; only its low 32 bits are compared, as JVMBridge does).
    public static func evaluate(debugged: Bool, probe: JITProbe, expectedReply: UInt32) -> JITReadiness {
        guard debugged else { return .needsDebugger }
        switch probe {
        case .notNeeded: return .ready
        case .noAnswer: return .needsDebugger
        case .answered(let v): return UInt32(truncatingIfNeeded: v) == expectedReply ? .ready : .problem(.wrongScript(reply: v))
        }
    }
}

/// Waits for JIT while the player is in StikDebug: checks every `poll`, at once when
/// `nudge()` is called (Voxelium came back to the foreground), and stops on `cancel()`.
@MainActor
public final class JITWait {
    public enum Outcome: Equatable, Sendable {
        case ready
        case cancelled
        case timedOut
        case problem(JITProblem)
    }

    private var cancelled = false
    private var pending: (id: Int, continuation: CheckedContinuation<Void, Never>)?
    private var nextID = 0

    public init() {}

    public func cancel() {
        cancelled = true
        wake(nil)
    }

    /// Check again now instead of at the next poll.
    public func nudge() { wake(nil) }

    /// `check` runs on the main actor; it is called first, then after each poll or nudge.
    public func run(timeout: Duration, poll: Duration,
                    check: @MainActor () async -> JITReadiness) async -> Outcome {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while true {
            if cancelled { return .cancelled }
            switch await check() {
            case .ready: return .ready
            case .problem(let p): return .problem(p)
            case .needsDebugger: break
            }
            if cancelled { return .cancelled }
            let left = deadline - clock.now
            if left <= .zero { return .timedOut }
            await pause(min(poll, left))
        }
    }

    private func pause(_ duration: Duration) async {
        nextID += 1
        let id = nextID
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            pending = (id, c)
            Task { @MainActor in
                try? await Task.sleep(for: duration)
                self.wake(id)
            }
        }
    }

    /// Resumes the current pause; `id` limits it to the pause that set the timer.
    private func wake(_ id: Int?) {
        guard let p = pending, id == nil || p.id == id else { return }
        pending = nil
        p.continuation.resume()
    }
}
