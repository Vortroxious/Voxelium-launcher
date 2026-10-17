import Foundation

/// Microsoft account sign-in for Minecraft: Microsoft sign-in → Xbox Live → XSTS →
/// Minecraft services. Two ways to get the Microsoft token:
///
/// - **Live web sign-in** (default, `MicrosoftAuth.live`): the flow Amethyst-iOS and
///   PojavLauncher use — login.live.com `oauth20_authorize.srf` in a web session with
///   Microsoft's Minecraft launcher client ID `00000000402b5328`, the authorization
///   code redeemed at `oauth20_token.srf`, scope `service::user.auth.xboxlive.com::MBI_SSL`,
///   and the token sent to Xbox Live as a bare RPS ticket. Chosen by the user
///   (2026-10-17); see docs/MICROSOFT_SIGN_IN.md.
/// - **Device code** with your own Azure app ID approved by Mojang (ZalithLauncher2's
///   MicrosoftAuthenticator.kt: tenant "consumers", RPS ticket "d=<token>").
///
/// Tokens are secrets: callers keep them in the Keychain, never in logs.
public struct MicrosoftAuth: Sendable {
    public let clientID: String
    let http: HTTPClient
    let sleep: @Sendable (Double) async throws -> Void

    public static let scope = "XboxLive.signin offline_access"
    static let msBase = "https://login.microsoftonline.com/consumers/oauth2/v2.0"

    // Live web sign-in (as Amethyst-iOS AccountListViewController / MicrosoftAuthenticator.m).
    public static let liveClientID = "00000000402b5328"
    public static let liveScope = "service::user.auth.xboxlive.com::MBI_SSL"
    public static let liveRedirect = "https://login.live.com/oauth20_desktop.srf"
    /// login.live.com sends the browser back to this scheme with `?code=…`.
    public static let liveCallbackScheme = "ms-xal-00000000402b5328"
    public static let liveAuthorizeURL: URL = {
        var c = URLComponents(string: "https://login.live.com/oauth20_authorize.srf")!
        c.queryItems = [.init(name: "client_id", value: liveClientID), .init(name: "response_type", value: "code"),
                        .init(name: "scope", value: liveScope), .init(name: "redirect_url", value: liveRedirect)]
        return c.url!
    }()
    static let liveToken = URL(string: "https://login.live.com/oauth20_token.srf")!

    /// The Live web sign-in flow.
    public static func live(http: HTTPClient = URLSessionHTTPClient()) -> MicrosoftAuth {
        MicrosoftAuth(clientID: liveClientID, http: http)
    }

    var isLive: Bool { clientID == Self.liveClientID }

    public init(clientID: String, http: HTTPClient = URLSessionHTTPClient(),
                sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }) {
        self.clientID = clientID
        self.http = http
        self.sleep = sleep
    }

    // MARK: Microsoft identity platform

    public struct DeviceCode: Sendable, Equatable {
        public let userCode: String
        public let deviceCode: String
        public let verificationURL: URL
        public let expiresIn: Int
        public let interval: Int
        public let message: String
    }

    public struct MicrosoftTokens: Sendable, Equatable {
        public let accessToken: String
        public let refreshToken: String
    }

    /// Step 1: a code the user enters at microsoft.com/link.
    public func requestDeviceCode() async throws -> DeviceCode {
        let j = try await http.form(URL(string: "\(Self.msBase)/devicecode")!, ["client_id": clientID, "scope": Self.scope])
        guard j.status == 200 else { throw AuthError.microsoft(j.oauthError ?? "HTTP \(j.status)") }
        guard let user = j.string("user_code"), let device = j.string("device_code"),
              let uri = j.string("verification_uri").flatMap(URL.init(string:)) else { throw AuthError.badResponse("device code") }
        return DeviceCode(userCode: user, deviceCode: device, verificationURL: uri,
                          expiresIn: j.int("expires_in") ?? 900, interval: max(j.int("interval") ?? 5, 1),
                          message: j.string("message") ?? "")
    }

    /// Step 2: waits until the user has approved the code (or it expires / is declined).
    public func pollForTokens(_ code: DeviceCode) async throws -> MicrosoftTokens {
        var interval = Double(code.interval)
        let deadline = Date().addingTimeInterval(Double(code.expiresIn))
        while Date() < deadline {
            try await sleep(interval)
            try Task.checkCancellation()
            let j = try await http.form(URL(string: "\(Self.msBase)/token")!, [
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "client_id": clientID, "device_code": code.deviceCode,
            ])
            if j.status == 200, let tokens = Self.tokens(j) { return tokens }
            switch j.oauthError {
            case "authorization_pending": continue
            case "slow_down": interval += 5
            case "authorization_declined": throw AuthError.declined
            case "expired_token", "bad_verification_code": throw AuthError.expired
            case let e: throw AuthError.microsoft(e ?? "HTTP \(j.status)")
            }
        }
        throw AuthError.expired
    }

    /// Live web sign-in: the `code` from the `ms-xal-…://` callback URL, or nil
    /// (with the reason) when the user cancelled or Microsoft returned an error.
    public static func liveCode(from callback: URL) -> Result<String, AuthError> {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty { return .success(code) }
        let error = items.first { $0.name == "error" }?.value ?? "no code"
        if error.hasPrefix("access_denied") { return .failure(.declined) }
        return .failure(.microsoft(items.first { $0.name == "error_description" }?.value ?? error))
    }

    /// Live web sign-in: redeems the authorization code.
    public func redeemLiveCode(_ code: String) async throws -> MicrosoftTokens {
        let j = try await http.form(Self.liveToken, [
            "client_id": clientID, "code": code, "grant_type": "authorization_code",
            "redirect_url": Self.liveRedirect, "scope": Self.liveScope,
        ])
        guard j.status == 200, let tokens = Self.tokens(j) else { throw AuthError.microsoft(j.oauthError ?? "HTTP \(j.status)") }
        return tokens
    }

    /// New Microsoft tokens from a saved refresh token.
    public func refresh(_ refreshToken: String) async throws -> MicrosoftTokens {
        let j = isLive
            ? try await http.form(Self.liveToken, [
                "client_id": clientID, "refresh_token": refreshToken, "grant_type": "refresh_token",
                "redirect_url": Self.liveRedirect, "scope": Self.liveScope,
            ])
            : try await http.form(URL(string: "\(Self.msBase)/token")!, [
                "grant_type": "refresh_token", "client_id": clientID, "refresh_token": refreshToken, "scope": Self.scope,
            ])
        guard j.status == 200, let tokens = Self.tokens(j) else {
            if j.oauthError == "invalid_grant" { throw AuthError.signInAgain }
            throw AuthError.microsoft(j.oauthError ?? "HTTP \(j.status)")
        }
        return tokens
    }

    static func tokens(_ j: JSONResponse) -> MicrosoftTokens? {
        guard let a = j.string("access_token"), let r = j.string("refresh_token") else { return nil }
        return MicrosoftTokens(accessToken: a, refreshToken: r)
    }

    // MARK: Xbox Live → XSTS → Minecraft

    /// Steps 3–6: Xbox Live, XSTS, Minecraft login, game ownership, profile.
    public func minecraftAccount(from ms: MicrosoftTokens, now: Date = Date()) async throws -> MicrosoftAccount {
        let (xbl, uhs) = try await xboxLive(ms.accessToken)
        let xsts = try await xsts(xbl)
        let mc = try await http.json(URL(string: "https://api.minecraftservices.com/authentication/login_with_xbox")!,
                                     body: ["identityToken": "XBL3.0 x=\(uhs);\(xsts)"])
        switch mc.status {
        case 200: break
        case 403: throw AuthError.appNotApproved
        case 429: throw AuthError.rateLimited
        default: throw AuthError.minecraft("login_with_xbox HTTP \(mc.status)")
        }
        guard let token = mc.string("access_token") else { throw AuthError.badResponse("Minecraft login") }
        let expires = now.addingTimeInterval(Double(mc.int("expires_in") ?? 86400))

        let owned = try await http.get(URL(string: "https://api.minecraftservices.com/entitlements/mcstore")!, bearer: token)
        guard owned.status == 200 else { throw AuthError.minecraft("entitlements HTTP \(owned.status)") }
        if (owned.object["items"] as? [Any])?.isEmpty ?? true { throw AuthError.doesNotOwnMinecraft }

        let profile = try await http.get(URL(string: "https://api.minecraftservices.com/minecraft/profile")!, bearer: token)
        if profile.status == 404 { throw AuthError.noProfile }
        guard profile.status == 200, let id = profile.string("id"), let name = profile.string("name") else {
            throw AuthError.minecraft("profile HTTP \(profile.status)")
        }
        return MicrosoftAccount(username: name, uuid: id.replacingOccurrences(of: "-", with: "").lowercased(),
                                xuid: uhs, minecraftAccessToken: token, minecraftTokenExpiry: expires,
                                microsoftRefreshToken: ms.refreshToken, clientID: clientID)
    }

    /// A launch-ready account: reuses the Minecraft token while it has more than
    /// an hour left, otherwise refreshes the whole chain.
    public func validAccount(_ account: MicrosoftAccount, now: Date = Date()) async throws -> MicrosoftAccount {
        if account.minecraftTokenExpiry.timeIntervalSince(now) > 3600 { return account }
        return try await minecraftAccount(from: refresh(account.microsoftRefreshToken), now: now)
    }

    func xboxLive(_ msAccessToken: String) async throws -> (token: String, uhs: String) {
        func request(_ ticket: String) async throws -> JSONResponse {
            try await http.json(URL(string: "https://user.auth.xboxlive.com/user/authenticate")!, body: [
                "Properties": ["AuthMethod": "RPS", "SiteName": "user.auth.xboxlive.com", "RpsTicket": ticket],
                "RelyingParty": "http://auth.xboxlive.com", "TokenType": "JWT",
            ])
        }
        // Live tokens go as they are (Amethyst); Azure tokens as "d=<token>", retried
        // without the prefix on HTTP 400 (ZalithLauncher2).
        var j = try await request(isLive ? msAccessToken : "d=\(msAccessToken)")
        if j.status == 400 && !isLive { j = try await request(msAccessToken) }
        guard j.status == 200, let token = j.string("Token"),
              let uhs = ((j.object["DisplayClaims"] as? [String: Any])?["xui"] as? [[String: Any]])?.first?["uhs"] as? String
        else { throw AuthError.xbox("Xbox Live HTTP \(j.status)") }
        return (token, uhs)
    }

    func xsts(_ xblToken: String) async throws -> String {
        let j = try await http.json(URL(string: "https://xsts.auth.xboxlive.com/xsts/authorize")!, body: [
            "Properties": ["SandboxId": "RETAIL", "UserTokens": [xblToken]],
            "RelyingParty": "rp://api.minecraftservices.com/", "TokenType": "JWT",
        ])
        if j.status == 200, let token = j.string("Token") { return token }
        let xerr = (j.object["XErr"] as? NSNumber)?.stringValue ?? (j.object["XErr"] as? String)
        throw AuthError.xbox(Self.xstsReason(xerr) ?? "XSTS HTTP \(j.status)\(xerr.map { " XErr \($0)" } ?? "")")
    }

    /// XSTS XErr codes (as listed by ZalithLauncher2 / prismarine-auth).
    static func xstsReason(_ xerr: String?) -> String? {
        switch xerr {
        case "2148916227": "This Xbox account is banned."
        case "2148916229": "This account is restricted; a parent must allow online play."
        case "2148916233": "This Microsoft account has no Xbox profile. Sign in once at xbox.com to create one."
        case "2148916234": "This account has not accepted the Xbox terms. Sign in once at xbox.com."
        case "2148916235": "Xbox Live is not available in this account's region."
        case "2148916236", "2148916237": "This account needs adult verification at xbox.com."
        case "2148916238": "This is a child account; it must be added to a Microsoft family by an adult."
        default: nil
        }
    }
}

/// A signed-in Microsoft account. Holds secrets: store it only in the Keychain.
public struct MicrosoftAccount: Codable, Sendable, Equatable {
    public var username: String
    public var uuid: String
    public var xuid: String
    public var minecraftAccessToken: String
    public var minecraftTokenExpiry: Date
    public var microsoftRefreshToken: String
    /// Which client ID signed in (the refresh must use the same one); nil = Live.
    public var clientID: String?

    public init(username: String, uuid: String, xuid: String, minecraftAccessToken: String,
                minecraftTokenExpiry: Date, microsoftRefreshToken: String, clientID: String? = nil) {
        self.username = username
        self.uuid = uuid
        self.xuid = xuid
        self.minecraftAccessToken = minecraftAccessToken
        self.minecraftTokenExpiry = minecraftTokenExpiry
        self.microsoftRefreshToken = microsoftRefreshToken
        self.clientID = clientID
    }

    public var identity: LaunchIdentity {
        LaunchIdentity(playerName: username, uuid: uuid, accessToken: minecraftAccessToken, userType: "msa", xuid: xuid)
    }
}

public enum AuthError: Error, Equatable, CustomStringConvertible {
    case noClientID, declined, expired, signInAgain, appNotApproved, rateLimited, doesNotOwnMinecraft, noProfile
    case microsoft(String), xbox(String), minecraft(String), badResponse(String)

    public var description: String {
        switch self {
        case .noClientID: "This build has no Microsoft app (client) ID, so Microsoft sign-in is unavailable. See docs/MICROSOFT_SIGN_IN.md."
        case .declined: "Sign-in was declined."
        case .expired: "The sign-in code expired. Try again."
        case .signInAgain: "Your Microsoft sign-in has expired. Sign in again."
        case .appNotApproved: "Minecraft services rejected this app's client ID (HTTP 403). New Azure app IDs must be approved by Mojang first."
        case .rateLimited: "Too many sign-in attempts. Wait a few minutes and try again."
        case .doesNotOwnMinecraft: "This Microsoft account does not own Minecraft: Java Edition."
        case .noProfile: "This account owns Minecraft but has no Java profile yet. Create one at minecraft.net."
        case .microsoft(let m): "Microsoft sign-in failed: \(m)"
        case .xbox(let m): "Xbox Live sign-in failed: \(m)"
        case .minecraft(let m): "Minecraft sign-in failed: \(m)"
        case .badResponse(let m): "Unexpected response from \(m)."
        }
    }
}

// MARK: - Small JSON-over-HTTP client (injectable for tests)

public struct JSONResponse: Sendable {
    public let status: Int
    public let data: Data

    public init(status: Int, data: Data) {
        self.status = status
        self.data = data
    }

    var object: [String: Any] { ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:] }
    func string(_ k: String) -> String? { object[k] as? String }
    func int(_ k: String) -> Int? { (object[k] as? NSNumber)?.intValue }
    var oauthError: String? { string("error") }
}

public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> JSONResponse
}

extension HTTPClient {
    func form(_ url: URL, _ fields: [String: String]) async throws -> JSONResponse {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        r.httpBody = Data(fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").utf8)
        return try await send(r)
    }

    func json(_ url: URL, body: [String: Any]) async throws -> JSONResponse {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return try await send(r)
    }

    func get(_ url: URL, bearer: String) async throws -> JSONResponse {
        var r = URLRequest(url: url)
        r.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await send(r)
    }
}

public struct URLSessionHTTPClient: HTTPClient {
    let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> JSONResponse {
        var r = request
        r.timeoutInterval = 30
        let (data, response) = try await session.data(for: r)
        return JSONResponse(status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
    }
}
