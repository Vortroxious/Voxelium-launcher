import SwiftUI
import VoxeliumCore

/// README section on installing Voxelium and LocalDevVPN and making the pairing file.
let setupGuideURL = URL(string: "https://github.com/Vortroxious/Voxelium-launcher#installing-on-your-iphone")!

/// Starts Minecraft for an installed version (vanilla or modded).
@MainActor
func launchVersion(_ id: String, model: LauncherModel, minecraft: MinecraftLauncher, accounts: AccountModel,
                   renderer: GameRenderer? = nil) {
    guard let paths = model.paths else { return }
    model.settings.selectedVersion = id  // the Play page's "Last played"
    let renderer = renderer ?? RendererMemory.last(for: id) ?? .mobileGlues
    Task { await minecraft.launch(versionID: id, paths: paths, settings: model.settings, accounts: accounts, renderer: renderer) }
}

/// The renderer last chosen for each version (experimental Play menu).
enum RendererMemory {
    private static func key(_ id: String) -> String { "VoxeliumRenderer." + id }
    static func last(for id: String) -> GameRenderer? {
        UserDefaults.standard.string(forKey: key(id)).flatMap(GameRenderer.init(rawValue:))
    }
    static func remember(_ renderer: GameRenderer, for id: String) {
        UserDefaults.standard.set(renderer.rawValue, forKey: key(id))
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject var model: LauncherModel
    @EnvironmentObject var updates: UpdateModel
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
                Section {
                    LabeledContent("Voxelium", value: UpdateModel.currentVersion)
                    Button { Task { await updates.check() } } label: { Label("Check for updates", systemImage: "arrow.triangle.2.circlepath") }
                        .disabled(updates.status == .checking)
                    switch updates.status {
                    case .idle: EmptyView()
                    case .checking: HStack(spacing: 8) { ProgressView(); Text("Checking GitHub…").font(.callout) }
                    case .upToDate: Text("Voxelium is up to date.").font(.callout)
                    case .available(let r):
                        Link(destination: r.htmlUrl) { Label("Voxelium \(r.version) is available", systemImage: "arrow.down.app") }
                    case .failed(let why): Text("Couldn't check: \(why)").font(.callout).foregroundStyle(.red)
                    }
                    Toggle("Check for updates automatically", isOn: $updates.automatic)
                } header: {
                    Text("Updates")
                } footer: {
                    Text("Voxelium asks GitHub once a day for the latest release. Nothing about you is sent, and nothing is downloaded or installed by itself.")
                }
                Section("JIT") {
                    LabeledContent("get-task-allow", value: ["Unknown", "Missing", "Yes"][Int(JITCoordinator.getTaskAllow) + 1])
                    LabeledContent("JIT script needed (TXM)", value: VXJITNeedsScript() ? "Yes" : "No")
                    LabeledContent("StikDebug installed", value: JITCoordinator.stikDebugInstalled ? "Yes" : "No")
                    Link(destination: setupGuideURL) { Label("Setup guide", systemImage: "book") }
                }
                Section {
                    NavigationLink { LogList() } label: { Label("Logs", systemImage: "doc.plaintext") }
                    NavigationLink { AboutView() } label: { Label("About Voxelium & licences", systemImage: "info.circle") }
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
                    Text("This build downloads and verifies game files and starts Minecraft Java (Java 17 versions, offline profile) in the app. Starting the game needs JIT: Play turns it on with the built-in helper (JIT tab) or asks StikDebug, or open Voxelium from StikDebug.")
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

/// The log, newest first; pushed from Diagnostics.
struct LogList: View {
    @EnvironmentObject var model: LauncherModel
    @State private var entries: [LogEntry] = []

    var body: some View {
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

    func color(_ l: LogLevel) -> Color {
        switch l {
        case .error: .red
        case .warning: .orange
        default: .secondary
        }
    }
}
