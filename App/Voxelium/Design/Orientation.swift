import SwiftUI
import UIKit
import VoxeliumCore

/// The launcher is portrait on iPhone; the game, SDL's window and the full-screen controls
/// editor are landscape. iPad allows every orientation.
///
/// Info.plist still lists the landscape orientations on iPhone, because the game's own
/// windows (VXGLFW, SDL) rotate to landscape; this narrows the launcher's window to portrait.
@MainActor
enum OrientationLock {
    /// Set while the launcher itself shows a landscape screen (the controls editor).
    private(set) static var launcherLandscape = false

    static func mask(for window: UIWindow?) -> UIInterfaceOrientationMask {
        if UIDevice.current.userInterfaceIdiom == .pad { return .all }
        guard let window, isLauncherWindow(window) else { return .allButUpsideDown }
        return launcherLandscape ? .landscape : .portrait
    }

    /// Turns the launcher to landscape (true) or back to portrait (false).
    static func setLandscape(_ landscape: Bool) {
        launcherLandscape = landscape
        update(to: landscape ? .landscape : .portrait)
    }

    /// Puts the launcher back in portrait, for example after a game window closed.
    static func restorePortrait() {
        guard !launcherLandscape else { return }
        update(to: .portrait)
    }

    private static func update(to mask: UIInterfaceOrientationMask) {
        guard UIDevice.current.userInterfaceIdiom != .pad else { return }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows where isLauncherWindow(window) {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
                Logger.shared.warning("ui", "Orientation request failed: \(error)")
            }
        }
    }

    /// SwiftUI's own window (its root is a hosting controller), not the game's.
    private static func isLauncherWindow(_ window: UIWindow) -> Bool {
        guard let root = window.rootViewController else { return false }
        return String(describing: type(of: root)).contains("HostingController")
    }
}

final class VoxeliumAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { OrientationLock.mask(for: window) }
    }
}
