import Foundation

/// Abstracts the network so download logic is testable without it.
public protocol HTTPTransport: Sendable {
    /// Downloads `url` to a temporary file owned by the caller.
    func download(from url: URL) async throws -> (file: URL, statusCode: Int)
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func download(from url: URL) async throws -> (file: URL, statusCode: Int) {
        let (tmp, response) = try await session.download(from: url)
        // URLSession deletes `tmp` when this call returns, so move it first.
        let owned = FileManager.default.temporaryDirectory.appendingPathComponent("zl-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: tmp, to: owned)
        return (owned, (response as? HTTPURLResponse)?.statusCode ?? 200)
    }
}

public struct DownloadItem: Sendable, Equatable, Hashable {
    public let url: URL
    public let destination: URL
    public let sha1: String?
    public let size: Int64?

    public init(url: URL, destination: URL, sha1: String?, size: Int64?) {
        self.url = url
        self.destination = destination
        self.sha1 = sha1
        self.size = size
    }
}

public enum DownloadError: Error, Equatable, CustomStringConvertible {
    case httpStatus(Int, URL)
    case integrity(IntegrityResult, URL)
    case transport(String, URL)
    case exhausted(attempts: Int, last: String, URL)

    public var description: String {
        switch self {
        case .httpStatus(let code, let url): "HTTP \(code) for \(url.absoluteString)"
        case .integrity(let r, let url): "Integrity check failed (\(r)) for \(url.absoluteString)"
        case .transport(let msg, let url): "Network error for \(url.absoluteString): \(msg)"
        case .exhausted(let n, let last, let url): "Gave up after \(n) attempts for \(url.absoluteString): \(last)"
        }
    }

    var isRetryable: Bool {
        switch self {
        case .httpStatus(let code, _): code == 408 || code == 429 || code >= 500
        case .integrity, .transport: true
        case .exhausted: false
        }
    }
}

public enum DownloadOutcome: Sendable, Equatable {
    /// The file was already present and passed verification.
    case alreadyValid
    case downloaded(attempts: Int)
}

public struct RetryPolicy: Sendable {
    public var maxAttempts: Int
    public var baseDelay: Duration
    public var maxDelay: Duration

    public init(maxAttempts: Int = 4, baseDelay: Duration = .milliseconds(500), maxDelay: Duration = .seconds(8)) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    /// Exponential backoff: base * 2^(attempt-1), capped.
    public func delay(afterAttempt attempt: Int) -> Duration {
        let scaled = baseDelay * (1 << min(attempt - 1, 16))
        return min(scaled, maxDelay)
    }
}

public struct DownloadReport: Sendable {
    public var outcomes: [DownloadItem: DownloadOutcome] = [:]
    public var failures: [DownloadItem: DownloadError] = [:]
    public var succeeded: Bool { failures.isEmpty }
}

public struct DownloadProgress: Sendable, Equatable {
    public let completed: Int
    public let total: Int
    public let failed: Int
}

/// Downloads files with integrity verification, retry with backoff, and
/// atomic placement (a corrupt or partial file never replaces a good one).
public struct DownloadManager: Sendable {
    public let transport: HTTPTransport
    public let retry: RetryPolicy
    let sleep: @Sendable (Duration) async throws -> Void
    let log: Logger

    public init(
        transport: HTTPTransport = URLSessionTransport(),
        retry: RetryPolicy = RetryPolicy(),
        log: Logger = .shared,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.transport = transport
        self.retry = retry
        self.log = log
        self.sleep = sleep
    }

    /// Ensures `item.destination` exists and matches its expected hash/size.
    public func ensure(_ item: DownloadItem) async throws -> DownloadOutcome {
        let existing = FileHash.verify(item.destination, sha1: item.sha1, size: item.size)
        if existing.isAcceptable { return .alreadyValid }
        if existing != .missing {
            log.warning("download", "Existing file is invalid (\(existing)), re-downloading: \(item.destination.lastPathComponent)")
        }

        var lastError: DownloadError = .transport("not attempted", item.url)
        for attempt in 1...retry.maxAttempts {
            try Task.checkCancellation()
            do {
                try await attemptOnce(item)
                return .downloaded(attempts: attempt)
            } catch let error as DownloadError {
                lastError = error
                log.warning("download", "Attempt \(attempt)/\(retry.maxAttempts) failed: \(error)")
                guard error.isRetryable else { throw error }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = .transport(String(describing: error), item.url)
                log.warning("download", "Attempt \(attempt)/\(retry.maxAttempts) failed: \(lastError)")
            }
            if attempt < retry.maxAttempts { try await sleep(retry.delay(afterAttempt: attempt)) }
        }
        throw DownloadError.exhausted(attempts: retry.maxAttempts, last: lastError.description, item.url)
    }

    private func attemptOnce(_ item: DownloadItem) async throws {
        let fm = FileManager.default
        let (tmp, status) = try await transport.download(from: item.url)
        defer { try? fm.removeItem(at: tmp) }
        guard (200..<300).contains(status) else { throw DownloadError.httpStatus(status, item.url) }

        let check = FileHash.verify(tmp, sha1: item.sha1, size: item.size)
        guard check.isAcceptable else { throw DownloadError.integrity(check, item.url) }

        try fm.createDirectory(at: item.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: item.destination.path) {
            _ = try fm.replaceItemAt(item.destination, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: item.destination)
        }
    }

    /// Runs many downloads with bounded concurrency. Individual failures are
    /// collected in the report rather than aborting the batch.
    public func run(
        _ items: [DownloadItem],
        concurrency: Int = 8,
        progress: (@Sendable (DownloadProgress) -> Void)? = nil
    ) async throws -> DownloadReport {
        let unique = Array(Set(items)).sorted { $0.destination.path < $1.destination.path }
        var report = DownloadReport()
        var iterator = unique.makeIterator()
        var completed = 0

        try await withThrowingTaskGroup(of: (DownloadItem, Result<DownloadOutcome, DownloadError>).self) { group in
            func enqueue() {
                guard let item = iterator.next() else { return }
                group.addTask {
                    do { return (item, .success(try await ensure(item))) }
                    catch let e as DownloadError { return (item, .failure(e)) }
                    catch is CancellationError { throw CancellationError() }
                    catch { return (item, .failure(.transport(String(describing: error), item.url))) }
                }
            }
            for _ in 0..<max(1, concurrency) { enqueue() }
            while let (item, result) = try await group.next() {
                switch result {
                case .success(let o): report.outcomes[item] = o
                case .failure(let e): report.failures[item] = e
                }
                completed += 1
                progress?(DownloadProgress(completed: completed, total: unique.count, failed: report.failures.count))
                enqueue()
            }
        }
        return report
    }
}
