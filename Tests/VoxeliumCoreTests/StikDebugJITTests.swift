import Foundation
import Testing
@testable import VoxeliumCore

@Suite struct StikDebugJITTests {
    /// What StikDebug does with the link (HomeView.handleExternalURL / base64URLToBase64).
    func decodeLikeStikDebug(_ url: URL) -> (bundle: String?, pid: Int?, script: Data?) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value }
        var script: Data?
        if let raw = value("script-data")?.removingPercentEncoding {
            var b = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            let pad = 4 - (b.count % 4)
            if pad < 4 { b += String(repeating: "=", count: pad) }
            script = Data(base64Encoded: b)
        }
        return (value("bundle-id"), value("pid").flatMap(Int.init), script)
    }

    @Test func linkCarriesAppPidAndScript() throws {
        // Bytes that give "+", "/" and "=" in standard base64.
        let script = Data((0..<1000).map { UInt8(truncatingIfNeeded: $0 * 7 + 251) }) + Data("}?>".utf8)
        let url = StikDebugJIT.enableJITURL(bundleID: "io.github.voxelium.launcher.ABCDE12345", pid: 4242, script: script)
        #expect(url.scheme == "stikjit" && url.host == "enable-jit")
        let raw = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "script-data" }?.value)
        #expect(!raw.contains("+") && !raw.contains("/") && !raw.contains("="))
        let d = decodeLikeStikDebug(url)
        #expect(d.bundle == "io.github.voxelium.launcher.ABCDE12345")
        #expect(d.pid == 4242)
        #expect(d.script == script)
    }

    @Test func noScriptWhenNotNeeded() {
        let url = StikDebugJIT.enableJITURL(bundleID: "a.b", pid: 1, script: nil)
        #expect(url.absoluteString == "stikjit://enable-jit?bundle-id=a.b&pid=1")
    }
}
