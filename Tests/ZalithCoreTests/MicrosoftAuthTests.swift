import Foundation
import Testing
@testable import ZalithCore

/// Canned HTTP responses per URL, in order; records every request.
final class MockHTTP: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var queues: [String: [(Int, Any)]] = [:]
    private(set) var requests: [URLRequest] = []

    func on(_ url: String, _ status: Int, _ body: Any) {
        lock.withLock { queues[url, default: []].append((status, body)) }
    }

    func send(_ request: URLRequest) async throws -> JSONResponse {
        try lock.withLock {
            requests.append(request)
            let key = request.url!.absoluteString
            guard var q = queues[key], !q.isEmpty else { throw URLError(.badURL) }
            let (status, body) = q.count > 1 ? q.removeFirst() : q[0]
            queues[key] = q
            return JSONResponse(status: status, data: try JSONSerialization.data(withJSONObject: body))
        }
    }

    func bodies(_ url: String) -> [String] {
        lock.withLock { requests.filter { $0.url?.absoluteString == url }.map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self) } }
    }
}

final class SleepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    var all: [Double] { lock.withLock { values } }
    func add(_ v: Double) { lock.withLock { values.append(v) } }
}

@Suite struct MicrosoftAuthTests {
    static let ms = "https://login.microsoftonline.com/consumers/oauth2/v2.0"
    static let xbl = "https://user.auth.xboxlive.com/user/authenticate"
    static let xsts = "https://xsts.auth.xboxlive.com/xsts/authorize"
    static let login = "https://api.minecraftservices.com/authentication/login_with_xbox"
    static let store = "https://api.minecraftservices.com/entitlements/mcstore"
    static let profile = "https://api.minecraftservices.com/minecraft/profile"

    func auth(_ http: MockHTTP, _ sleeps: SleepLog = SleepLog()) -> MicrosoftAuth {
        MicrosoftAuth(clientID: "test-client", http: http, sleep: { sleeps.add($0) })
    }

    func happyChain(_ http: MockHTTP) {
        http.on(Self.xbl, 200, ["Token": "xbl-token", "DisplayClaims": ["xui": [["uhs": "user-hash"]]]])
        http.on(Self.xsts, 200, ["Token": "xsts-token"])
        http.on(Self.login, 200, ["access_token": "mc-token", "expires_in": 86400])
        http.on(Self.store, 200, ["items": [["name": "game_minecraft"]]])
        http.on(Self.profile, 200, ["id": "0123456789abcdef0123456789ABCDEF", "name": "Steve"])
    }

    @Test func deviceCodeFlowSignsIn() async throws {
        let http = MockHTTP(), sleeps = SleepLog()
        http.on("\(Self.ms)/devicecode", 200, ["user_code": "ABCD-EFGH", "device_code": "dev", "verification_uri": "https://www.microsoft.com/link",
                                               "expires_in": 900, "interval": 5, "message": "Go to microsoft.com/link"])
        http.on("\(Self.ms)/token", 400, ["error": "authorization_pending"])
        http.on("\(Self.ms)/token", 400, ["error": "slow_down"])
        http.on("\(Self.ms)/token", 200, ["access_token": "ms-access", "refresh_token": "ms-refresh"])
        happyChain(http)
        let a = auth(http, sleeps)

        let code = try await a.requestDeviceCode()
        #expect(code.userCode == "ABCD-EFGH" && code.verificationURL.absoluteString == "https://www.microsoft.com/link")
        let ms = try await a.pollForTokens(code)
        #expect(ms == .init(accessToken: "ms-access", refreshToken: "ms-refresh"))
        #expect(sleeps.all == [5, 5, 10])  // slow_down adds 5 s

        let account = try await a.minecraftAccount(from: ms, now: Date(timeIntervalSince1970: 0))
        #expect(account.username == "Steve" && account.uuid == "0123456789abcdef0123456789abcdef")
        #expect(account.minecraftAccessToken == "mc-token" && account.microsoftRefreshToken == "ms-refresh")
        #expect(account.minecraftTokenExpiry == Date(timeIntervalSince1970: 86400))
        #expect(account.identity.userType == "msa" && account.identity.xuid == "user-hash")

        #expect(http.bodies("\(Self.ms)/devicecode").first == "client_id=test-client&scope=XboxLive.signin%20offline_access")
        #expect(http.bodies("\(Self.ms)/token").first?.contains("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code") == true)
        #expect(http.bodies(Self.xbl).first?.contains(#""RpsTicket":"d=ms-access""#) == true)
        #expect(http.bodies(Self.login).first == #"{"identityToken":"XBL3.0 x=user-hash;xsts-token"}"#)
        let bearer = http.requests.first { $0.url?.absoluteString == Self.profile }?.value(forHTTPHeaderField: "Authorization")
        #expect(bearer == "Bearer mc-token")
    }

    @Test func liveWebSignIn() async throws {
        #expect(MicrosoftAuth.liveAuthorizeURL.absoluteString.hasPrefix("https://login.live.com/oauth20_authorize.srf?client_id=00000000402b5328&response_type=code&scope=service::user.auth.xboxlive.com::MBI_SSL"))
        #expect(MicrosoftAuth.liveCode(from: URL(string: "ms-xal-00000000402b5328://auth/?code=M.C1_abc&lc=1033")!) == .success("M.C1_abc"))
        #expect(MicrosoftAuth.liveCode(from: URL(string: "ms-xal-00000000402b5328://auth/?error=access_denied&error_description=x")!) == .failure(.declined))

        let http = MockHTTP()
        http.on("https://login.live.com/oauth20_token.srf", 200, ["access_token": "live-access", "refresh_token": "live-refresh"])
        happyChain(http)
        let a = MicrosoftAuth.live(http: http)
        let ms = try await a.redeemLiveCode("M.C1_abc")
        let account = try await a.minecraftAccount(from: ms)
        #expect(account.username == "Steve" && account.clientID == MicrosoftAuth.liveClientID)
        let body = try #require(http.bodies("https://login.live.com/oauth20_token.srf").first)
        #expect(body.contains("client_id=00000000402b5328") && body.contains("code=M.C1_abc") && body.contains("grant_type=authorization_code"))
        // Live tokens go to Xbox Live without the "d=" prefix.
        #expect(http.bodies(Self.xbl).first?.contains(#""RpsTicket":"live-access""#) == true)

        _ = try await a.refresh("live-refresh")
        #expect(http.bodies("https://login.live.com/oauth20_token.srf").last?.contains("grant_type=refresh_token") == true)
    }

    @Test func declinedCode() async throws {
        let http = MockHTTP()
        http.on("\(Self.ms)/token", 400, ["error": "authorization_declined"])
        let code = MicrosoftAuth.DeviceCode(userCode: "A", deviceCode: "d", verificationURL: URL(string: "https://x")!, expiresIn: 60, interval: 1, message: "")
        await #expect(throws: AuthError.declined) { try await auth(http).pollForTokens(code) }
    }

    @Test func xstsErrorsAreExplained() async throws {
        let http = MockHTTP()
        http.on(Self.xbl, 200, ["Token": "xbl-token", "DisplayClaims": ["xui": [["uhs": "h"]]]])
        http.on(Self.xsts, 401, ["XErr": 2148916233, "Message": ""])
        await #expect(throws: AuthError.xbox(MicrosoftAuth.xstsReason("2148916233")!)) {
            try await auth(http).minecraftAccount(from: .init(accessToken: "a", refreshToken: "r"))
        }
    }

    @Test func unapprovedAppAndNoOwnership() async throws {
        let only403 = MockHTTP()
        only403.on(Self.xbl, 200, ["Token": "t", "DisplayClaims": ["xui": [["uhs": "h"]]]])
        only403.on(Self.xsts, 200, ["Token": "x"])
        only403.on(Self.login, 403, [:])
        await #expect(throws: AuthError.appNotApproved) {
            try await auth(only403).minecraftAccount(from: .init(accessToken: "a", refreshToken: "r"))
        }

        let noGame = MockHTTP()
        noGame.on(Self.xbl, 200, ["Token": "t", "DisplayClaims": ["xui": [["uhs": "h"]]]])
        noGame.on(Self.xsts, 200, ["Token": "x"])
        noGame.on(Self.login, 200, ["access_token": "mc", "expires_in": 86400])
        noGame.on(Self.store, 200, ["items": []])
        await #expect(throws: AuthError.doesNotOwnMinecraft) {
            try await auth(noGame).minecraftAccount(from: .init(accessToken: "a", refreshToken: "r"))
        }
    }

    @Test func refreshOnlyWhenTheTokenIsNearExpiry() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let fresh = MicrosoftAccount(username: "Steve", uuid: "u", xuid: "h", minecraftAccessToken: "old",
                                     minecraftTokenExpiry: now.addingTimeInterval(7200), microsoftRefreshToken: "r1")
        let idle = MockHTTP()
        #expect(try await auth(idle).validAccount(fresh, now: now) == fresh)
        #expect(idle.requests.isEmpty)

        let http = MockHTTP()
        http.on("\(Self.ms)/token", 200, ["access_token": "ms2", "refresh_token": "r2"])
        happyChain(http)
        var stale = fresh
        stale.minecraftTokenExpiry = now.addingTimeInterval(60)
        let renewed = try await auth(http).validAccount(stale, now: now)
        #expect(renewed.minecraftAccessToken == "mc-token" && renewed.microsoftRefreshToken == "r2")
        #expect(http.bodies("\(Self.ms)/token").first?.contains("grant_type=refresh_token") == true)

        let gone = MockHTTP()
        gone.on("\(Self.ms)/token", 400, ["error": "invalid_grant"])
        await #expect(throws: AuthError.signInAgain) { try await auth(gone).validAccount(stale, now: now) }
    }
}
