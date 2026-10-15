import Foundation
import Testing
@testable import ZalithCore

@Suite struct DownloadTests {
    let body = Data("hello minecraft".utf8)
    var sha: String { FileHash.sha1(of: body) }
    let url = URL(string: "https://example.invalid/file.jar")!

    func manager(_ t: MockTransport, attempts: Int = 3) -> DownloadManager {
        DownloadManager(transport: t, retry: RetryPolicy(maxAttempts: attempts, baseDelay: .zero), log: Logger(), sleep: { _ in })
    }

    @Test func knownSHA1() {
        // `printf 'hello minecraft' | shasum -a1`
        #expect(sha == "0205c49d7dadcddde7b919c2b0763dd43d1679f0")
    }

    @Test func downloadsAndVerifies() async throws {
        let tmp = try TempDir()
        let t = MockTransport()
        t.enqueue(url, .ok(body))
        let dest = tmp.url.appendingPathComponent("a/b/file.jar")
        let out = try await manager(t).ensure(DownloadItem(url: url, destination: dest, sha1: sha, size: Int64(body.count)))
        #expect(out == .downloaded(attempts: 1))
        #expect(try Data(contentsOf: dest) == body)
    }

    @Test func skipsAlreadyValidFile() async throws {
        let tmp = try TempDir()
        let dest = tmp.url.appendingPathComponent("file.jar")
        try body.write(to: dest)
        let t = MockTransport()
        let out = try await manager(t).ensure(DownloadItem(url: url, destination: dest, sha1: sha, size: nil))
        #expect(out == .alreadyValid)
        #expect(t.requests.isEmpty)
    }

    @Test func replacesCorruptExistingFile() async throws {
        let tmp = try TempDir()
        let dest = tmp.url.appendingPathComponent("file.jar")
        try Data("garbage!!!!!!!!".utf8).write(to: dest) // same size, wrong hash
        let t = MockTransport()
        t.enqueue(url, .ok(body))
        let out = try await manager(t).ensure(DownloadItem(url: url, destination: dest, sha1: sha, size: Int64(body.count)))
        #expect(out == .downloaded(attempts: 1))
        #expect(try Data(contentsOf: dest) == body)
    }

    @Test func retriesOnHashMismatchThenSucceeds() async throws {
        let tmp = try TempDir()
        let t = MockTransport()
        t.enqueue(url, .ok(Data("truncated".utf8)), .fail(.networkConnectionLost), .ok(body))
        let dest = tmp.url.appendingPathComponent("file.jar")
        let out = try await manager(t, attempts: 4).ensure(DownloadItem(url: url, destination: dest, sha1: sha, size: nil))
        #expect(out == .downloaded(attempts: 3))
        #expect(t.requestCount(url) == 3)
    }

    @Test func retriesServerErrors() async throws {
        let tmp = try TempDir()
        let t = MockTransport()
        t.enqueue(url, .status(503), .status(429), .ok(body))
        let out = try await manager(t).ensure(DownloadItem(url: url, destination: tmp.url.appendingPathComponent("f"), sha1: sha, size: nil))
        #expect(out == .downloaded(attempts: 3))
    }

    @Test func doesNotRetryNotFound() async throws {
        let tmp = try TempDir()
        let t = MockTransport()
        t.enqueue(url, .status(404))
        await #expect(throws: DownloadError.httpStatus(404, url)) {
            try await manager(t).ensure(DownloadItem(url: url, destination: tmp.url.appendingPathComponent("f"), sha1: sha, size: nil))
        }
        #expect(t.requestCount(url) == 1)
    }

    @Test func givesUpAfterMaxAttemptsAndLeavesNoFile() async throws {
        let tmp = try TempDir()
        let t = MockTransport()
        t.enqueue(url, .ok(Data("wrong".utf8)))
        let dest = tmp.url.appendingPathComponent("f")
        await #expect {
            try await manager(t, attempts: 3).ensure(DownloadItem(url: url, destination: dest, sha1: sha, size: nil))
        } throws: { error in
            guard case DownloadError.exhausted(let n, _, _) = error else { return false }
            return n == 3
        }
        #expect(t.requestCount(url) == 3)
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    @Test func failedDownloadDoesNotClobberExistingFile() async throws {
        // The existing file is invalid, but a failed re-download must not
        // replace it with something worse (or delete it mid-way).
        let tmp = try TempDir()
        let dest = tmp.url.appendingPathComponent("f")
        let old = Data("old".utf8)
        try old.write(to: dest)
        let t = MockTransport()
        t.enqueue(url, .status(500))
        _ = try? await manager(t, attempts: 2).ensure(DownloadItem(url: url, destination: dest, sha1: sha, size: nil))
        #expect(try Data(contentsOf: dest) == old)
    }

    @Test func batchCollectsFailuresAndReportsProgress() async throws {
        let tmp = try TempDir()
        let t = MockTransport()
        var items: [DownloadItem] = []
        for i in 0..<20 {
            let u = URL(string: "https://example.invalid/\(i)")!
            if i == 7 { t.enqueue(u, .status(404)) } else { t.enqueue(u, .ok(body)) }
            items.append(DownloadItem(url: u, destination: tmp.url.appendingPathComponent("\(i)"), sha1: sha, size: nil))
        }
        let seen = Counter()
        let report = try await manager(t).run(items + items.prefix(3), concurrency: 4) { p in
            seen.set(p.completed)
            #expect(p.total == 20)
        }
        #expect(report.outcomes.count == 19)
        #expect(report.failures.count == 1)
        #expect(!report.succeeded)
        #expect(seen.value == 20)
    }

    @Test func backoffIsExponentialAndCapped() {
        let p = RetryPolicy(maxAttempts: 10, baseDelay: .milliseconds(500), maxDelay: .seconds(4))
        #expect(p.delay(afterAttempt: 1) == .milliseconds(500))
        #expect(p.delay(afterAttempt: 2) == .seconds(1))
        #expect(p.delay(afterAttempt: 3) == .seconds(2))
        #expect(p.delay(afterAttempt: 6) == .seconds(4))
    }

    @Test func integrityResults() throws {
        let tmp = try TempDir()
        let f = tmp.url.appendingPathComponent("x")
        #expect(FileHash.verify(f, sha1: sha, size: nil) == .missing)
        try body.write(to: f)
        #expect(FileHash.verify(f, sha1: sha, size: 1) == .sizeMismatch(expected: 1, actual: Int64(body.count)))
        #expect(FileHash.verify(f, sha1: sha.uppercased(), size: nil) == .valid)
        #expect(FileHash.verify(f, sha1: nil, size: nil) == .unverified)
        if case .hashMismatch = FileHash.verify(f, sha1: String(repeating: "0", count: 40), size: nil) {} else {
            Issue.record("expected hash mismatch")
        }
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var v = 0
    func set(_ n: Int) { lock.withLock { v = max(v, n) } }
    var value: Int { lock.withLock { v } }
}
