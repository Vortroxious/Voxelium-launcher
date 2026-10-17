import Foundation
#if canImport(UIKit)
import UIKit
#endif

// `csops` is exported by libsystem_kernel but has no public header. The same
// check is used by PojavLauncher/Amethyst to detect an attached debugger
// (StikDebug, Xcode), which is what allows JIT on stock iOS.
@_silgen_name("csops")
private func csops(_ pid: pid_t, _ ops: UInt32, _ useraddr: UnsafeMutableRawPointer?, _ usersize: Int) -> Int32

enum DeviceInfo {
    private static let CS_OPS_STATUS: UInt32 = 0
    private static let CS_DEBUGGED: UInt32 = 0x10000000

    /// True when the process is being debugged (CS_DEBUGGED). This is a
    /// prerequisite for JIT, not proof that JIT memory mapping works — on
    /// newer iOS versions/devices the debugger must also service JIT requests.
    static var isDebuggerAttached: Bool {
        var flags: UInt32 = 0
        guard csops(getpid(), CS_OPS_STATUS, &flags, MemoryLayout<UInt32>.size) == 0 else { return false }
        return flags & CS_DEBUGGED != 0
    }

    @MainActor static var systemDescription: String {
        #if canImport(UIKit)
        "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion) (\(machine))"
        #else
        "\(ProcessInfo.processInfo.operatingSystemVersionString) (\(machine))"
        #endif
    }

    static var machine: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    static var physicalMemory: UInt64 { ProcessInfo.processInfo.physicalMemory }

    /// Memory this process can still allocate before Jetsam (iOS only).
    static var availableMemory: UInt64? {
        #if os(iOS)
        UInt64(os_proc_available_memory())
        #else
        nil
        #endif
    }
}
