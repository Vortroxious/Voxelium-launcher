import Foundation
import Testing
@testable import VoxeliumCore

@Suite struct UpdateCheckTests {
    static let url = UpdateCheck.latestURL.absoluteString

    func release(_ tag: String, draft: Bool = false, prerelease: Bool = false) -> [String: Any] {
        ["tag_name": tag, "name": "Voxelium \(tag.dropFirst())", "html_url": "https://github.com/Vortroxious/Voxelium-launcher/releases/tag/\(tag)",
         "draft": draft, "prerelease": prerelease, "assets": []]
    }

    @Test func comparesVersionsByNumber() {
        #expect(UpdateCheck.isNewer("v2.4", than: "2.3"))
        #expect(UpdateCheck.isNewer("2.10", than: "2.9"))
        #expect(UpdateCheck.isNewer("v2.4", than: "2.3.1"))
        #expect(UpdateCheck.isNewer("3.0", than: "2.12"))
        #expect(!UpdateCheck.isNewer("v2.3", than: "2.3"))
        #expect(!UpdateCheck.isNewer("2.4", than: "2.4.0"))
        #expect(!UpdateCheck.isNewer("v2.2", than: "2.3"))
        #expect(!UpdateCheck.isNewer("2.4-beta", than: "2.4"))
    }

    @Test func reportsANewerRelease() async throws {
        let http = MockHTTP()
        http.on(Self.url, 200, release("v2.4"))
        let result = try await UpdateCheck(http: http).check(current: "2.3")
        guard case .available(let r) = result else { Issue.record("expected an update, got \(result)"); return }
        #expect(r.version == "2.4")
        #expect(r.htmlUrl.absoluteString.hasSuffix("/releases/tag/v2.4"))
        #expect(http.requests.first?.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Voxelium/") == true)
    }

    @Test func upToDateWhenTheSameOrOlder() async throws {
        let http = MockHTTP()
        http.on(Self.url, 200, release("v2.3"))
        #expect(try await UpdateCheck(http: http).check(current: "2.3") == .upToDate(latest: "2.3"))
    }

    @Test func ignoresDraftsAndPreReleases() async throws {
        let http = MockHTTP()
        http.on(Self.url, 200, release("v2.5", prerelease: true))
        await #expect(throws: UpdateCheck.CheckError.badResponse) { try await UpdateCheck(http: http).check(current: "2.3") }
    }

    @Test func reportsHTTPErrors() async throws {
        let http = MockHTTP()
        http.on(Self.url, 403, ["message": "API rate limit exceeded"])
        await #expect(throws: UpdateCheck.CheckError.http(403)) { try await UpdateCheck(http: http).check(current: "2.3") }
    }
}
