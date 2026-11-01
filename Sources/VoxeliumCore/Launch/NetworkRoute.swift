import Foundation

/// How the iPhone is connected, as far as JIT cares. LocalDevVPN's tunnel to the
/// iPhone's own developer services doesn't connect on mobile data alone (iOS 27; StikJIT's
/// README: it needs Wi-Fi or Airplane Mode). With Airplane Mode on for the ~2 seconds JIT
/// takes, it does; the network can come back right after.
public enum NetworkRoute: Equatable, Sendable {
    /// Wi-Fi or a cable: JIT works.
    case local
    /// Mobile data and no Wi-Fi: JIT needs Airplane Mode for a moment.
    case mobileDataOnly
    /// No network (Airplane Mode): JIT works through LocalDevVPN alone.
    case offline

    /// From an NWPath: whether it's satisfied and which interface types it uses.
    public static func of(satisfied: Bool, wifi: Bool, wired: Bool, cellular: Bool) -> NetworkRoute {
        if wifi || wired { return .local }
        if satisfied && cellular { return .mobileDataOnly }
        return .offline
    }
}
