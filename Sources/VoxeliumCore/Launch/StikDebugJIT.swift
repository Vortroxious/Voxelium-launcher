import Foundation

/// The link that asks StikDebug to turn on JIT for Voxelium while it is already running,
/// so it can be opened from the Home Screen instead of from StikDebug, as Amethyst does
/// (`LauncherNavigationController.invokeAfterJITEnabled`, GPL-3.0).
///
/// StikDebug (`HomeView.handleExternalURL`, read at 17b1e1d, 2026-10-19) handles
/// `stikjit://enable-jit` with:
/// - `bundle-id`: the app; with `pid` it also switches back to the app afterwards;
/// - `pid`: attach to this running process instead of launching the app again;
/// - `script-data`: a base64url JIT script to run while attached (iOS 26 with TXM needs
///   UniversalJIT26.js). Without it StikDebug uses the script assigned to the app, if any.
///
/// StikDebug asks the user to confirm unless they turned that off in its settings.
public enum StikDebugJIT {
    public static func enableJITURL(bundleID: String, pid: Int32, script: Data?) -> URL {
        var c = URLComponents()
        c.scheme = "stikjit"
        c.host = "enable-jit"
        var items = [URLQueryItem(name: "bundle-id", value: bundleID), URLQueryItem(name: "pid", value: String(pid))]
        if let script, !script.isEmpty {
            items.append(URLQueryItem(name: "script-data", value: base64URL(script)))
        }
        c.queryItems = items
        return c.url!
    }

    /// Base64 with `-`/`_` and no padding: safe inside a query without escaping.
    /// StikDebug turns it back into standard base64 (`base64URLToBase64`).
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
