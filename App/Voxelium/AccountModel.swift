import AuthenticationServices
import Foundation
import UIKit
import VoxeliumCore

/// The Microsoft account the user signed in with (tokens in the Keychain only).
@MainActor
final class AccountModel: ObservableObject {
    enum SignIn: Equatable {
        case idle
        case waitingForUser(MicrosoftAuth.DeviceCode)
        case working(String)
        case failed(String)
    }

    @Published private(set) var account: MicrosoftAccount?
    @Published private(set) var signIn: SignIn = .idle

    /// Your own Azure app (client) ID, if one was bundled at build time; then sign-in
    /// uses the device code flow. Otherwise the Live web sign-in (as Amethyst) is used.
    let clientID: String?
    private let keychain = KeychainStore(service: "io.github.voxelium.microsoft")
    private let log = Logger.shared
    private var task: Task<Void, Never>?
    /// The early refresh in flight, and when the last one failed: one at a time, and none
    /// for 5 minutes after a failure (several in a row got HTTP 429 from Microsoft).
    private var earlyRefresh: Task<Void, Never>?
    private var earlyRefreshFailed: Date?

    init() {
        let id = Bundle.main.url(forResource: "microsoft-client-id", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        clientID = (id?.isEmpty ?? true) ? nil : id
        if let data = keychain.read("default") {
            account = try? JSONDecoder().decode(MicrosoftAccount.self, from: data)
        }
    }

    private var auth: MicrosoftAuth { clientID.map { MicrosoftAuth(clientID: $0) } ?? .live() }
    /// The auth for an existing account: the client ID it signed in with.
    private func auth(for account: MicrosoftAccount) -> MicrosoftAuth {
        guard let id = account.clientID, id != MicrosoftAuth.liveClientID else { return .live() }
        return MicrosoftAuth(clientID: id)
    }
    private var webSession: ASWebAuthenticationSession?
    private let anchor = PresentationAnchor()

    func startSignIn() {
        let auth = self.auth
        task?.cancel()
        task = Task {
            do {
                let ms: MicrosoftAuth.MicrosoftTokens
                if clientID != nil {
                    signIn = .working("Contacting Microsoft…")
                    let code = try await auth.requestDeviceCode()
                    signIn = .waitingForUser(code)
                    ms = try await auth.pollForTokens(code)
                } else {
                    log.info("account", "Microsoft sign-in started (login.live.com web sign-in)")
                    signIn = .working("Waiting for the Microsoft sign-in page…")
                    let code = try await liveCode()
                    log.info("account", "Microsoft sign-in page returned a code; redeeming it")
                    signIn = .working("Signing in to Microsoft…")
                    ms = try await auth.redeemLiveCode(code)
                }
                signIn = .working("Signing in to Xbox Live and Minecraft…")
                let acc = try await auth.minecraftAccount(from: ms)
                try save(acc)
                signIn = .idle
                log.info("account", "Signed in to Microsoft as \(acc.username)")
            } catch is CancellationError {
                log.info("account", "Microsoft sign-in cancelled")
                signIn = .idle
            } catch {
                signIn = .failed(String(describing: error))
                log.error("account", "Microsoft sign-in failed: \(error)")
            }
        }
    }

    /// Shows login.live.com in a web session and returns the authorization code.
    private func liveCode() async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let session = ASWebAuthenticationSession(url: MicrosoftAuth.liveAuthorizeURL,
                                                     callbackURLScheme: MicrosoftAuth.liveCallbackScheme) { url, error in
                if let url {
                    cont.resume(with: MicrosoftAuth.liveCode(from: url).mapError { $0 as Error })
                } else if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin {
                    cont.resume(throwing: CancellationError())
                } else {
                    cont.resume(throwing: error ?? AuthError.badResponse("Microsoft sign-in page"))
                }
            }
            session.presentationContextProvider = anchor
            session.prefersEphemeralWebBrowserSession = true  // as Amethyst: no shared Safari cookies
            webSession = session
            if !session.start() {
                log.error("account", "Could not open the Microsoft sign-in page (ASWebAuthenticationSession.start failed)")
                cont.resume(throwing: AuthError.badResponse("Microsoft sign-in page (could not open)"))
            }
        }
    }

    func cancelSignIn() {
        webSession?.cancel()
        webSession = nil
        task?.cancel()
        task = nil
        signIn = .idle
    }

    func signOut() {
        try? keychain.delete("default")
        account = nil
        log.info("account", "Signed out of Microsoft")
    }

    /// A launch identity with a valid Minecraft token (refreshed when near expiry).
    /// Without internet (Airplane Mode for JIT on mobile data) it uses the saved sign-in,
    /// as the official launcher's offline play does: single-player works, servers and
    /// Realms check the token and need a refresh first. `offline` says which it was.
    func launchIdentity() async throws -> (identity: LaunchIdentity, offline: Bool) {
        await earlyRefresh?.value  // its result is saved; don't ask Microsoft twice
        guard let account else { throw AuthError.signInAgain }
        do {
            let valid = try await auth(for: account).validAccount(account)
            if valid != account {
                try save(valid)
                log.info("account", "Refreshed the Minecraft token for \(valid.username)")
            }
            return (valid.identity, false)
        } catch where LauncherModel.looksOffline(error) {
            log.warning("account", "No internet to refresh the Minecraft token for \(account.username) (expires \(account.minecraftTokenExpiry)): playing with the saved sign-in")
            return (account.identity, true)
        }
    }

    /// Refreshes the Minecraft token while the app is open and online, when it has less
    /// than 12 hours left, so a later Play in Airplane Mode has a current one. Failures
    /// are only logged: Play tries again.
    func refreshEarly() async {
        guard let account, signIn == .idle, earlyRefresh == nil,
              account.minecraftTokenExpiry.timeIntervalSinceNow < 12 * 3600 else { return }
        if let failed = earlyRefreshFailed, Date().timeIntervalSince(failed) < 300 { return }
        let auth = auth(for: account)
        let refresh = Task {
            do {
                let valid = try await auth.validAccount(account, margin: 12 * 3600)
                earlyRefreshFailed = nil
                guard valid != account, self.account == account else { return }
                try save(valid)
                log.info("account", "Refreshed the Minecraft token for \(valid.username) early (was valid until \(account.minecraftTokenExpiry))")
            } catch {
                earlyRefreshFailed = Date()
                log.info("account", "Early token refresh skipped: \(error)")
            }
        }
        earlyRefresh = refresh
        await refresh.value
        earlyRefresh = nil
    }

    private func save(_ acc: MicrosoftAccount) throws {
        try keychain.write(try JSONEncoder().encode(acc), for: "default")
        account = acc
    }
}

/// Where ASWebAuthenticationSession presents the Microsoft page: the app's key window.
private final class PresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}
