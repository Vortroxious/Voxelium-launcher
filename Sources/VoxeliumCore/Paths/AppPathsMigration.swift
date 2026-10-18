import Foundation

/// What `AppPaths.migrateIfNeeded(from:to:)` did, as paths relative to the old root.
public struct DataMigrationReport: Sendable, Equatable {
    /// Items moved into the new root (a whole folder counts once).
    public var moved: [String] = []
    /// Items left in the old root because the new root already had something there.
    public var kept: [String] = []
    /// Whether the old root was empty at the end and removed.
    public var removedOldRoot = false

    public init() {}

    public var didAnything: Bool { !moved.isEmpty || !kept.isEmpty || removedOldRoot }
}

extension AppPaths {
    /// Moves everything from `old` into `new`. A folder that exists on both sides is
    /// merged: missing children move, existing files and folders in `new` stay as
    /// they are. Nothing is overwritten or deleted; only folders left empty by the
    /// move are removed, the old root last. Moves within one volume are renames, so
    /// gigabytes of game files move instantly, and a run cut short is finished by
    /// the next one.
    @discardableResult
    public static func migrateIfNeeded(from old: URL, to new: URL, fileManager: FileManager = .default) throws -> DataMigrationReport {
        var report = DataMigrationReport()
        let old = old.standardizedFileURL, new = new.standardizedFileURL
        guard old != new, isDirectory(old, fileManager) else { return report }
        try fileManager.createDirectory(at: new, withIntermediateDirectories: true)
        try merge(old, into: new, relative: "", report: &report, fileManager: fileManager)
        if (try? fileManager.contentsOfDirectory(atPath: old.path))?.isEmpty == true {
            try fileManager.removeItem(at: old)
            report.removedOldRoot = true
        }
        return report
    }

    private static func merge(_ src: URL, into dst: URL, relative: String, report: inout DataMigrationReport,
                              fileManager fm: FileManager) throws {
        for name in try fm.contentsOfDirectory(atPath: src.path).sorted() {
            let from = src.appendingPathComponent(name), to = dst.appendingPathComponent(name)
            let rel = relative.isEmpty ? name : "\(relative)/\(name)"
            if !fm.fileExists(atPath: to.path) && (try? fm.destinationOfSymbolicLink(atPath: to.path)) == nil {
                try fm.moveItem(at: from, to: to)
                report.moved.append(rel)
            } else if isDirectory(from, fm) && isDirectory(to, fm) {
                try merge(from, into: to, relative: rel, report: &report, fileManager: fm)
                if (try? fm.contentsOfDirectory(atPath: from.path))?.isEmpty == true { try fm.removeItem(at: from) }
            } else {
                report.kept.append(rel)
            }
        }
    }

    /// A real folder (a symlink to one is moved as a link, never followed).
    private static func isDirectory(_ url: URL, _ fm: FileManager) -> Bool {
        (try? fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeDirectory
    }
}
