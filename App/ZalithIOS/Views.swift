import SwiftUI
import ZalithCore

struct VersionsView: View {
    @EnvironmentObject var model: LauncherModel

    var body: some View {
        NavigationStack {
            List {
                if let error = model.manifestError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                        Button("Retry") { Task { await model.loadManifest() } }
                    }
                }
                Section {
                    Toggle("Show snapshots", isOn: $model.settings.showSnapshots)
                }
                Section("Versions") {
                    ForEach(model.visibleVersions) { entry in
                        VersionRow(entry: entry)
                    }
                }
            }
            .overlay { if model.loadingManifest && model.manifest == nil { ProgressView("Loading versions…") } }
            .refreshable { await model.loadManifest() }
            .navigationTitle("Minecraft Versions")
        }
    }
}

struct VersionRow: View {
    @EnvironmentObject var model: LauncherModel
    let entry: VersionManifest.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading) {
                    Text(entry.id).font(.headline)
                    Text(entry.releaseTime, style: .date).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                action
            }
            status
        }
    }

    @ViewBuilder var action: some View {
        switch model.installState[entry.id] {
        case .preparing, .downloading:
            ProgressView()
        default:
            if model.installed.contains(entry.id) {
                Menu {
                    Button("Verify / repair files") { Task { await model.install(entry) } }
                    Button("Prepare launch plan") { model.preparePlan(entry.id) }
                } label: { Label("Installed", systemImage: "checkmark.circle.fill") }
            } else {
                Button("Install") { Task { await model.install(entry) } }.buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder var status: some View {
        switch model.installState[entry.id] {
        case .downloading(let stage, let done, let total, let failed):
            ProgressView(value: Double(done), total: Double(max(total, 1))) {
                Text("\(stage): \(done)/\(total)\(failed > 0 ? " · \(failed) failed" : "")").font(.caption)
            }
        case .finished(let ok, let failed):
            Text(failed == 0 ? "All \(ok) files verified" : "\(failed) files failed — see Logs")
                .font(.caption).foregroundStyle(failed == 0 ? Color.green : Color.red)
        case .failed(let msg):
            Text(msg).font(.caption).foregroundStyle(.red)
        default:
            EmptyView()
        }
    }
}

struct AccountView: View {
    @EnvironmentObject var model: LauncherModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Player name", text: $model.settings.playerName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !OfflineIdentity.isValidName(model.settings.playerName) {
                        Text("3–16 characters: letters, digits, underscore").font(.caption).foregroundStyle(.red)
                    }
                } header: {
                    Text("Offline profile")
                } footer: {
                    Text("Microsoft account sign-in is not implemented yet. Offline profiles cannot join online-mode servers.")
                }
                Section("Game") {
                    Stepper("Max memory: \(model.settings.maxMemoryMB) MB", value: $model.settings.maxMemoryMB, in: 512...8192, step: 256)
                }
                if let plan = model.lastPlan {
                    Section("Last launch plan (not executed)") {
                        LabeledContent("Main class", value: plan.mainClass)
                        LabeledContent("Java", value: plan.requiredJavaMajor.map(String.init) ?? "?")
                        LabeledContent("Classpath entries", value: "\(plan.classpath.count)")
                        LabeledContent("Missing files", value: "\(plan.missingFiles.count)")
                    }
                }
            }
            .navigationTitle("Account & Game")
        }
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject var model: LauncherModel
    @StateObject private var javaTest = JavaTestModel()
    @StateObject private var graphicsTest = GraphicsTestModel()

    var body: some View {
        NavigationStack {
            List {
                Section("Device") {
                    LabeledContent("System", value: DeviceInfo.systemDescription)
                    LabeledContent("Physical memory", value: ByteCountFormatter.string(fromByteCount: Int64(DeviceInfo.physicalMemory), countStyle: .memory))
                    if let avail = DeviceInfo.availableMemory {
                        LabeledContent("Available to app", value: ByteCountFormatter.string(fromByteCount: Int64(avail), countStyle: .memory))
                    }
                    LabeledContent("Debugger attached (JIT prerequisite)", value: DeviceInfo.isDebuggerAttached ? "Yes" : "No")
                }
                JavaTestSection(test: javaTest, paths: model.paths)
                GraphicsTestSection(test: graphicsTest, paths: model.paths)
                Section("Downloaded Java runtimes") {
                    if model.runtimes.isEmpty {
                        Text("None downloaded. The test above uses the runtime bundled in the app.").foregroundStyle(.secondary)
                    }
                    ForEach(model.runtimes, id: \.home) { rt in
                        LabeledContent(rt.name, value: "Java \(rt.javaVersion)")
                    }
                }
                Section("Status") {
                    Text("This build can download and verify game files and run a Java smoke test. It cannot start Minecraft.")
                        .font(.footnote)
                }
                if let root = model.paths?.root {
                    Section("Data directory") { Text(root.path).font(.caption.monospaced()).textSelection(.enabled) }
                }
            }
            .navigationTitle("Diagnostics")
        }
    }
}

struct LogView: View {
    @EnvironmentObject var model: LauncherModel
    @State private var entries: [LogEntry] = []

    var body: some View {
        NavigationStack {
            List(Array(entries.enumerated().reversed()), id: \.offset) { _, e in
                VStack(alignment: .leading) {
                    Text("[\(e.level.description)] \(e.category)").font(.caption.bold()).foregroundStyle(color(e.level))
                    Text(e.message).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            .navigationTitle("Logs")
            .toolbar { Button("Refresh") { entries = model.log.snapshot } }
            .onAppear { entries = model.log.snapshot }
        }
    }

    func color(_ l: LogLevel) -> Color {
        switch l {
        case .error: .red
        case .warning: .orange
        default: .secondary
        }
    }
}
