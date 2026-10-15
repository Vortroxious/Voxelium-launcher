import Foundation
import Testing
@testable import ZalithCore

enum Fixture {
    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
}


/// A fresh temp directory per test, removed on deinit.
final class TempDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("zl-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    var paths: AppPaths { AppPaths(root: url) }
}

/// Scripted transport: each URL gets a queue of responses, consumed in order.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    enum Response {
        case ok(Data)
        case status(Int, Data = Data())
        case fail(URLError.Code)
    }

    private let lock = NSLock()
    private var queues: [URL: [Response]] = [:]
    private(set) var requests: [URL] = []

    func enqueue(_ url: URL, _ responses: Response...) {
        lock.withLock { queues[url, default: []].append(contentsOf: responses) }
    }

    func requestCount(_ url: URL) -> Int { lock.withLock { requests.filter { $0 == url }.count } }

    func download(from url: URL) async throws -> (file: URL, statusCode: Int) {
        let response: Response = lock.withLock {
            requests.append(url)
            guard var q = queues[url], !q.isEmpty else { return .status(404) }
            let r = q.removeFirst()
            // Keep the last response sticky so retries past the script repeat it.
            queues[url] = q.isEmpty ? [r] : q
            return r
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("zl-mock-\(UUID().uuidString)")
        switch response {
        case .ok(let d):
            try d.write(to: tmp)
            return (tmp, 200)
        case .status(let code, let d):
            try d.write(to: tmp)
            return (tmp, code)
        case .fail(let code):
            throw URLError(code)
        }
    }
}
