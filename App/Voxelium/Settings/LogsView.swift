import SwiftUI
import VoxeliumCore

/// Settings → Logs: Voxelium's log, newest first, with a filter and Share for the log files.
struct LogsView: View {
    @EnvironmentObject var model: LauncherModel
    @State private var entries: [LogEntry] = []
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable { case all = "All", warnings = "Warnings", errors = "Errors" }

    private var shown: [LogEntry] {
        let minimum: LogLevel = switch filter {
        case .all: .debug
        case .warnings: .warning
        case .errors: .error
        }
        return entries.filter { $0.level >= minimum }.reversed()
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 6) {
                    ForEach(Filter.allCases, id: \.self) { f in ToggleChip(title: f.rawValue, selected: filter == f) { filter = f } }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }
            if shown.isEmpty {
                Text(filter == .all ? "Nothing logged yet." : "No \(filter.rawValue.lowercased()).")
                    .foregroundStyle(VX.onSurfaceVariant).vxRow()
            }
            ForEach(Array(shown.enumerated()), id: \.offset) { _, e in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(e.level.description).font(.caption2.weight(.heavy)).foregroundStyle(color(e.level))
                        Text(e.category).font(.caption.weight(.semibold)).foregroundStyle(VX.onSurface)
                        Spacer()
                        Text(e.date, format: .dateTime.hour().minute().second()).font(.caption2).foregroundStyle(VX.onSurfaceVariant)
                    }
                    Text(e.message).font(.caption.monospaced()).foregroundStyle(VX.onSurface).textSelection(.enabled)
                }
                .vxRow()
            }
        }
        .vxList()
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { entries = model.log.snapshot } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Refresh")
                let files = LogFiles.existing(model.paths)
                if !files.isEmpty {
                    ShareLink(items: files) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Share the log files")
                }
            }
        }
        .onAppear { entries = model.log.snapshot }
    }

    private func color(_ l: LogLevel) -> Color {
        switch l {
        case .error: VX.error
        case .warning: VX.tertiary
        case .info: VX.primary
        case .debug: VX.onSurfaceVariant
        }
    }
}

/// The log files worth sharing when asking for help.
enum LogFiles {
    /// Voxelium's own log and Minecraft's (Java) log, when they exist.
    static func existing(_ paths: AppPaths?) -> [URL] {
        guard let logs = paths?.logsDir else { return [] }
        return ["launcher.log", "jvm.log"].map { logs.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The last lines of Minecraft's log (logs/jvm.log), read from its end.
    static func gameLogTail(_ paths: AppPaths?, lines: Int = 40) -> String? {
        guard let url = paths?.logsDir.appendingPathComponent("jvm.log"),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > 32_768 ? size - 32_768 : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }
}

/// Shown when Minecraft ends with an error or doesn't start: why, the end of its log, and
/// the log files to share.
struct GameEndedSheet: View {
    @EnvironmentObject var model: LauncherModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    let message: String
    @State private var tail: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(VX.error)
                            .frame(width: 48, height: 48)
                            .background(VX.errorContainer, in: RoundedRectangle(cornerRadius: VX.Radius.medium))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Minecraft stopped").font(.vxTitle).foregroundStyle(VX.onSurface)
                            Text("It ended with an error. The end of its log is below.").font(.vxCaption).foregroundStyle(VX.onSurfaceVariant)
                        }
                    }
                    SectionLabel("What happened").padding(.top, 4)
                    Text(message).font(.subheadline).foregroundStyle(VX.onSurface).textSelection(.enabled)
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(VX.surface, in: RoundedRectangle(cornerRadius: VX.Radius.medium))
                    if let tail {
                        SectionLabel("End of Minecraft's log").padding(.top, 4)
                        ScrollView(.horizontal) {
                            Text(tail).font(.caption2.monospaced()).foregroundStyle(VX.onSurface).textSelection(.enabled)
                                .padding(12)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(VX.surfaceLowest, in: RoundedRectangle(cornerRadius: VX.Radius.medium))
                        .overlay { RoundedRectangle(cornerRadius: VX.Radius.medium).stroke(VX.outline, lineWidth: 1) }
                    }
                    let files = LogFiles.existing(model.paths)
                    if !files.isEmpty {
                        ShareLink(items: files) { SwiftUI.Label("Share the logs", systemImage: "square.and.arrow.up") }
                            .buttonStyle(PrimaryButtonStyle(height: 48)).padding(.top, 4)
                    }
                    Text("When you ask for help, share these two files: launcher.log (Voxelium) and jvm.log (Minecraft).")
                        .font(.vxCaption).foregroundStyle(VX.onSurfaceVariant)
                }
                .padding(.horizontal, VX.margin(sizeClass)).padding(.vertical, 12)
            }
            .vxPage()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Close") { dismiss() } }
        }
        .task { tail = LogFiles.gameLogTail(model.paths) }
    }
}
