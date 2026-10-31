import Foundation
import Testing
@testable import VoxeliumCore

@Suite struct JITReadinessTests {
    let reply: UInt32 = 0x6900_00E0

    @Test func noDebuggerNeedsStikDebug() {
        #expect(JITReadiness.evaluate(debugged: false, probe: .notNeeded, expectedReply: reply) == .needsDebugger)
        #expect(JITReadiness.evaluate(debugged: false, probe: .answered(UInt64(reply)), expectedReply: reply) == .needsDebugger)
    }

    @Test func withoutTXMTheFlagIsEnough() {
        #expect(JITReadiness.evaluate(debugged: true, probe: .notNeeded, expectedReply: reply) == .ready)
    }

    @Test func txmNeedsTheScriptToAnswer() {
        // Debugged earlier, but the script has gone: ask StikDebug again.
        #expect(JITReadiness.evaluate(debugged: true, probe: .noAnswer, expectedReply: reply) == .needsDebugger)
        // Only the low 32 bits count, as in JVMBridge.
        #expect(JITReadiness.evaluate(debugged: true, probe: .answered(0xFFFF_FFFF_6900_00E0), expectedReply: reply) == .ready)
        #expect(JITReadiness.evaluate(debugged: true, probe: .answered(0xE000_0069), expectedReply: reply)
                == .problem(.wrongScript(reply: 0xE000_0069)))
    }

    @Test func everyProblemExplainsItself() {
        let all: [JITProblem] = [.stikDebugMissing, .timedOut, .missingGetTaskAllow, .scriptNotAttached, .wrongScript(reply: 0xAB), .helperFailed("No route to 10.7.0.1.")]
        for p in all {
            #expect(!p.title.isEmpty && p.message.count > 40)
        }
        #expect(JITProblem.wrongScript(reply: 0xAB).message.contains("0xAB"))
        #expect(JITProblem.stikDebugMissing.showsSetupGuide && !JITProblem.scriptNotAttached.showsSetupGuide)
    }
}

@MainActor @Suite struct JITWaitTests {
    @Test func readyAtOnceSkipsWaiting() async {
        let wait = JITWait()
        let outcome = await wait.run(timeout: .seconds(5), poll: .seconds(5)) { .ready }
        #expect(outcome == .ready)
    }

    @Test func becomesReadyAfterPolls() async {
        let wait = JITWait()
        var calls = 0
        let outcome = await wait.run(timeout: .seconds(5), poll: .milliseconds(5)) {
            calls += 1
            return calls >= 3 ? .ready : .needsDebugger
        }
        #expect(outcome == .ready && calls == 3)
    }

    @Test func timesOut() async {
        let wait = JITWait()
        let outcome = await wait.run(timeout: .milliseconds(30), poll: .milliseconds(10)) { .needsDebugger }
        #expect(outcome == .timedOut)
    }

    @Test func problemStopsTheWait() async {
        let wait = JITWait()
        let outcome = await wait.run(timeout: .seconds(5), poll: .milliseconds(5)) { .problem(.wrongScript(reply: 1)) }
        #expect(outcome == .problem(.wrongScript(reply: 1)))
    }

    @Test func cancelEndsALongPause() async {
        let wait = JITWait()
        let start = ContinuousClock.now
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(20))
            wait.cancel()
        }
        let outcome = await wait.run(timeout: .seconds(30), poll: .seconds(30)) { .needsDebugger }
        #expect(outcome == .cancelled)
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func nudgeChecksAgainAtOnce() async {
        let wait = JITWait()
        var ready = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(20))
            ready = true
            wait.nudge()
        }
        let start = ContinuousClock.now
        let outcome = await wait.run(timeout: .seconds(30), poll: .seconds(30)) { ready ? .ready : .needsDebugger }
        #expect(outcome == .ready)
        #expect(ContinuousClock.now - start < .seconds(5))
    }
}
