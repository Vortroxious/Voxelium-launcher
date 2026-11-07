import Foundation
import VoxeliumCore

/// Launcher update checks: asks GitHub for the latest release at start (at most once a
/// day, when online) and on request. Shows a banner on Play when a newer
/// release exists; "Not now" hides that version.
@MainActor
final class UpdateModel: ObservableObject {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate(String)
        case available(UpdateCheck.Release)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published var automatic: Bool {
        didSet { UserDefaults.standard.set(automatic, forKey: Self.automaticKey) }
    }

    private static let automaticKey = "VoxeliumUpdateCheckAutomatic"
    private static let lastCheckKey = "VoxeliumUpdateCheckLast"
    private static let dismissedKey = "VoxeliumUpdateDismissed"
    private let log = Logger.shared

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    init() {
        automatic = UserDefaults.standard.object(forKey: Self.automaticKey) as? Bool ?? true
    }

    /// The release to show on Play: newer and not dismissed.
    var banner: UpdateCheck.Release? {
        guard case .available(let r) = status,
              UserDefaults.standard.string(forKey: Self.dismissedKey) != r.version else { return nil }
        return r
    }

    func dismiss(_ release: UpdateCheck.Release) {
        UserDefaults.standard.set(release.version, forKey: Self.dismissedKey)
        objectWillChange.send()
    }

    /// At start and when the network comes back: at most once every 24 hours.
    func checkIfDue(offline: Bool) async {
        guard automatic, !offline, status != .checking else { return }
        if let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < 24 * 3600 { return }
        await check()
    }

    func check() async {
        guard status != .checking else { return }
        status = .checking
        let current = Self.currentVersion
        do {
            switch try await UpdateCheck().check(current: current) {
            case .upToDate(let latest):
                status = .upToDate(latest)
                log.info("update", "Voxelium \(current) is up to date (latest release \(latest))")
            case .available(let release):
                status = .available(release)
                log.info("update", "Voxelium \(release.version) is available (running \(current))")
            }
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
        } catch {
            let text = LauncherModel.looksOffline(error) ? "No internet connection." : "\(error)"
            status = .failed(text)
            log.warning("update", "Update check failed: \(text)")
        }
    }
}
