import SwiftUI
import VoxeliumCore

/// Settings: Game, JIT, Diagnostics, Logs and About, each on its own page.
struct SettingsView: View {
    @EnvironmentObject var model: LauncherModel
    @EnvironmentObject var updates: UpdateModel
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    PageHeader("Settings").padding(.bottom, 4)
                    link("Game", summary: gameSummary, systemImage: "slider.horizontal.3") { GameSettingsView() }
                    link("JIT", summary: JITSettingsList.method, systemImage: "bolt.fill") {
                        JITSettingsList().navigationTitle("JIT").navigationBarTitleDisplayMode(.inline)
                    }
                    link("Diagnostics", summary: "Device, Java and graphics tests", systemImage: "stethoscope") { DiagnosticsView() }
                    link("Logs", summary: "What Voxelium and Minecraft wrote", systemImage: "doc.plaintext") { LogsView() }
                    link("About", summary: aboutSummary, systemImage: "info.circle") { AboutView() }
                }
                .padding(.horizontal, VX.margin(sizeClass)).padding(.bottom, 16)
                .frame(maxWidth: 720).frame(maxWidth: .infinity)
            }
            .vxPage()
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var gameSummary: String {
        let mb = model.settings.maxMemoryMB
        let memory = mb % 1024 == 0 ? "\(mb / 1024) GB" : "\(mb) MB"
        return "\(memory) memory · \(Int((model.settings.renderScale * 100).rounded()))% resolution"
    }

    private var aboutSummary: String {
        if case .available(let r) = updates.status { return "Voxelium \(r.version) is available" }
        return "Voxelium \(UpdateModel.currentVersion), credits and licences"
    }

    private func link<Destination: View>(_ title: String, summary: String, systemImage: String,
                                         @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink(destination: destination) {
            RowCard {
                Image(systemName: systemImage).font(.body).foregroundStyle(VX.onSecondaryContainer)
                    .frame(width: 40, height: 40)
                    .background(VX.secondaryContainer, in: RoundedRectangle(cornerRadius: VX.Radius.small))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.vxHeadline).foregroundStyle(VX.onSurface)
                    Text(summary).font(.vxCaption).foregroundStyle(VX.onSurfaceVariant).lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(VX.onSurfaceVariant)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Settings → Diagnostics: the device, JIT prerequisites, the Java and graphics tests,
/// downloaded runtimes and the data folder.
struct DiagnosticsView: View {
    @EnvironmentObject var model: LauncherModel
    @StateObject private var javaTest = JavaTestModel()
    @StateObject private var graphicsTest = GraphicsTestModel()

    var body: some View {
        List {
            Section("Device") {
                LabeledContent("System", value: DeviceInfo.systemDescription)
                LabeledContent("Physical memory", value: ByteCountFormatter.string(fromByteCount: Int64(DeviceInfo.physicalMemory), countStyle: .memory))
                if let avail = DeviceInfo.availableMemory {
                    LabeledContent("Available to the app", value: ByteCountFormatter.string(fromByteCount: Int64(avail), countStyle: .memory))
                }
                LabeledContent("Debugger attached (JIT)", value: DeviceInfo.isDebuggerAttached ? "Yes" : "No")
            }
            .vxRow()
            Section {
                LabeledContent("get-task-allow", value: ["Unknown", "Missing", "Yes"][Int(JITCoordinator.getTaskAllow) + 1])
                LabeledContent("JIT script needed (TXM)", value: VXJITNeedsScript() ? "Yes" : "No")
                LabeledContent("StikDebug installed", value: JITCoordinator.stikDebugInstalled ? "Yes" : "No")
            } header: {
                Text("JIT")
            } footer: {
                Text("Starting Minecraft needs JIT. Play turns it on with the built-in helper (Settings → JIT) or asks StikDebug.")
            }
            .vxRow()
            JavaTestSection(test: javaTest, paths: model.paths).vxRow()
            GraphicsTestSection(test: graphicsTest, paths: model.paths).vxRow()
            Section("Downloaded Java runtimes") {
                if model.runtimes.isEmpty {
                    Text("None downloaded. The Java test uses the runtime bundled in the app.").foregroundStyle(VX.onSurfaceVariant)
                }
                ForEach(model.runtimes, id: \.home) { rt in
                    LabeledContent(rt.name, value: "Java \(rt.javaVersion)")
                }
            }
            .vxRow()
            if let root = model.paths?.root {
                Section {
                    Text(root.path).font(.caption.monospaced()).textSelection(.enabled)
                } header: {
                    Text("Data folder")
                } footer: {
                    Text("In Files → On My iPhone → Voxelium.")
                }
                .vxRow()
            }
        }
        .vxList()
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }
}
