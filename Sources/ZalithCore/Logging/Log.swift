import Foundation
import os

/// Severity levels shared by the in-memory/file log and os_log.
public enum LogLevel: Int, Sendable, Comparable, CustomStringConvertible {
    case debug = 0, info, warning, error

    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }

    public var description: String {
        switch self {
        case .debug: "DEBUG"
        case .info: "INFO"
        case .warning: "WARN"
        case .error: "ERROR"
        }
    }
}

public struct LogEntry: Sendable, Equatable {
    public let date: Date
    public let level: LogLevel
    public let category: String
    public let message: String

    public var formatted: String {
        "\(ISO8601DateFormatter().string(from: date)) [\(level)] \(category): \(message)"
    }
}

/// Thread-safe logger that mirrors entries to os_log and, optionally, an
/// append-only file (used for the launcher log the user can export).
public final class Logger: @unchecked Sendable {
    public static let shared = Logger()

    private let lock = NSLock()
    private var entries: [LogEntry] = []
    private var fileHandle: FileHandle?
    private let maxEntries: Int
    private let osLog = os.Logger(subsystem: "io.github.zalithios", category: "core")

    public var minimumLevel: LogLevel = .debug

    public init(maxEntries: Int = 5000) {
        self.maxEntries = maxEntries
    }

    /// Starts mirroring entries to `url`, creating the file if needed.
    public func attachFile(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        lock.withLock {
            try? fileHandle?.close()
            fileHandle = handle
        }
    }

    public func log(_ level: LogLevel, _ category: String, _ message: String) {
        guard level >= minimumLevel else { return }
        let entry = LogEntry(date: Date(), level: level, category: category, message: message)
        osLog.log(level: level.osLogType, "\(category, privacy: .public): \(message, privacy: .public)")
        lock.withLock {
            entries.append(entry)
            if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
            if let data = (entry.formatted + "\n").data(using: .utf8) {
                try? fileHandle?.write(contentsOf: data)
            }
        }
    }

    public func debug(_ category: String, _ message: String) { log(.debug, category, message) }
    public func info(_ category: String, _ message: String) { log(.info, category, message) }
    public func warning(_ category: String, _ message: String) { log(.warning, category, message) }
    public func error(_ category: String, _ message: String) { log(.error, category, message) }

    public var snapshot: [LogEntry] { lock.withLock { entries } }
}

private extension LogLevel {
    var osLogType: OSLogType {
        switch self {
        case .debug: .debug
        case .info: .info
        case .warning: .default
        case .error: .error
        }
    }
}
