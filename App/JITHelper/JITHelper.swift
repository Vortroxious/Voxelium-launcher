// Voxelium JIT helper, spike (docs/JIT_INTEGRATION_PLAN.md, Phase 2).
//
// An app extension that turns on JIT for Voxelium with StikJIT (MPL-2.0, compiled in
// from source by scripts/build-jit-helper.sh). It has to be a separate process: a
// process that attaches a debugger to itself deadlocks.
//
// Requests (NSExtensionItem userInfo):
// - action "check": pid, reachability of the device's services, TXM, get-task-allow.
// - action "enableJIT": hostPid, pairingFile (data), script (UniversalJIT26.js data),
//   forceScript. Runs StikJIT.enableJIT, which on TXM devices stays attached, answering
//   the JVM's breakpoints, until the script detaches after libjvm's code-cache request.
//
// Progress goes out as a Darwin notification whose state is a stage number; the
// reply carries ok/error and StikJIT's log lines. The pairing file is written to a
// temporary file only for the call and is never logged.

import Darwin
import Foundation

private let stageNotification = "io.github.voxelium.jithelper.stage"

// libnotify (notify.h is not visible to Swift). 0 = NOTIFY_STATUS_OK.
@_silgen_name("notify_register_check")
private func notify_register_check(_ name: UnsafePointer<CChar>, _ token: UnsafeMutablePointer<Int32>) -> UInt32
@_silgen_name("notify_set_state")
private func notify_set_state(_ token: Int32, _ state: UInt64) -> UInt32
@_silgen_name("notify_post")
private func notify_post(_ name: UnsafePointer<CChar>) -> UInt32
@_silgen_name("notify_cancel")
private func notify_cancel(_ token: Int32) -> UInt32

enum HelperStage: UInt64 {
    case checkingReachability = 1, checkingDDI, downloadingDDI, mountingDDI, verifyingDDI, prepared
    case attaching = 7, finished = 8
}

private func post(_ stage: HelperStage) {
    var token: Int32 = 0
    guard notify_register_check(stageNotification, &token) == 0 else { return }
    _ = notify_set_state(token, stage.rawValue)
    _ = notify_post(stageNotification)
    _ = notify_cancel(token)
}

/// 1 = true, 0 = missing, -1 = unknown (SecTask SPI, as the host's VXJITGetTaskAllow).
private func getTaskAllow() -> Int {
    typealias Create = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
    typealias Copy = @convention(c) (UnsafeMutableRawPointer, CFString, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFTypeRef>?
    guard let c = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecTaskCreateFromSelf"),
          let v = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecTaskCopyValueForEntitlement") else { return -1 }
    let create = unsafeBitCast(c, to: Create.self)
    let copy = unsafeBitCast(v, to: Copy.self)
    guard let task = create(nil) else { return -1 }
    defer { Unmanaged<AnyObject>.fromOpaque(task).release() }
    guard let value = copy(task, "get-task-allow" as CFString, nil)?.takeRetainedValue() else { return 0 }
    return (value as? Bool) == true ? 1 : 0
}

/// Lines from StikJIT, collected from whichever thread reports them.
private final class LogBox {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) {
        NSLog("[JITHelper] %@", line)
        lock.lock(); lines.append(line); lock.unlock()
    }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

@objc(VXJITHelperHandler)
final class VXJITHelperHandler: NSObject, NSExtensionRequestHandling {
    /// StikJIT's calls block; the guide asks for one serial queue.
    private static let queue = DispatchQueue(label: "io.github.voxelium.jithelper")

    func beginRequest(with context: NSExtensionContext) {
        let info = (context.inputItems.first as? NSExtensionItem)?.userInfo ?? [:]
        Self.queue.async {
            let reply = (info["action"] as? String) == "enableJIT" ? Self.enableJIT(info) : Self.check(info)
            let item = NSExtensionItem()
            item.userInfo = reply
            context.completeRequest(returningItems: [item], completionHandler: nil)
        }
    }

    private static func check(_ info: [AnyHashable: Any]) -> [String: Any] {
        func reach(_ port: UInt16) -> String {
            EndpointProbe.failureReason(address: "10.7.0.1", port: port, timeout: 2) ?? "connected"
        }
        let txm = StikJIT.isTXMPresent.map { $0 ? "present" : "absent" } ?? "unknown"
        return [
            "ok": true,
            "helperPid": Int(getpid()),
            "hostPid": (info["hostPid"] as? NSNumber)?.intValue ?? 0,
            "lockdown": reach(62078),
            "rsd": reach(49152),
            "txm": txm,
            "getTaskAllow": getTaskAllow(),
        ]
    }

    private static func enableJIT(_ info: [AnyHashable: Any]) -> [String: Any] {
        guard let pid = (info["hostPid"] as? NSNumber)?.int32Value,
              let pairing = info["pairingFile"] as? Data,
              let script = info["script"] as? Data else {
            return ["ok": false, "error": "The request was missing the pid, pairing file or script."]
        }
        let forceScript = (info["forceScript"] as? NSNumber)?.boolValue ?? false
        let log = LogBox()
        let fm = FileManager.default
        let pairingURL = fm.temporaryDirectory.appendingPathComponent("pairing-\(UUID().uuidString).plist")
        defer { try? fm.removeItem(at: pairingURL) }
        do {
            try pairing.write(to: pairingURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            return ["ok": false, "error": "Could not write the pairing file for StikJIT: \(error.localizedDescription)"]
        }
        // The Developer Disk Image cache lives in the helper's own Library, once per boot.
        let library = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("StikJIT", isDirectory: true)
        try? fm.createDirectory(at: library, withIntermediateDirectories: true)
        let paths = DDIPaths.default(in: library)

        log.add("Host pid \(pid), forceScript \(forceScript), TXM (StikJIT) \(StikJIT.isTXMPresent.map(String.init) ?? "unknown"), script \(script.count) bytes")
        do {
            try StikJIT.enableJIT(
                targetPID: pid, pairingFile: pairingURL, ddiPaths: paths,
                script: .customBase64(script.base64EncodedString()), forceScript: forceScript,
                preparationProgress: { stage in
                    switch stage {
                    case .checkingReachability: post(.checkingReachability); log.add("Checking the connection")
                    case .checkingDDI: post(.checkingDDI); log.add("Checking the Developer Disk Image")
                    case .downloadingDDI(let f, let s): post(.downloadingDDI); log.add("Downloading the Developer Disk Image \(Int(f * 100))% \(s)")
                    case .mountingDDI(let f): post(.mountingDDI); if f == 0 || f >= 1 { log.add("Mounting the Developer Disk Image \(Int(f * 100))%") }
                    case .verifyingDDI: post(.verifyingDDI); log.add("Verifying the mount")
                    case .ready: post(.prepared); log.add("Device ready")
                    }
                },
                progress: { line in
                    if line.hasPrefix("Running") || line.hasPrefix("Attaching") { post(.attaching) }
                    log.add(line)
                })
            post(.finished)
            return ["ok": true, "log": log.all]
        } catch {
            log.add("Failed: \(error.localizedDescription)")
            return ["ok": false, "error": error.localizedDescription, "log": log.all]
        }
    }
}
