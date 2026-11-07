import SwiftUI
import VoxeliumCore

/// One installed version: its mods, resource packs, shader packs, worlds and settings.
struct VersionView: View {
    @EnvironmentObject var model: LauncherModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    let version: InstalledVersion
    @StateObject private var flow = LaunchFlow()
    @State private var tab: Tab = .content(.mods)

    enum Tab: Hashable {
        case content(ContentKind)
        case worlds
        case settings
    }

    private var tabs: [Tab] {
        (version.isModded ? ContentKind.allCases : [.resourcePacks]).map(Tab.content) + [.worlds, .settings]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header.padding(.horizontal, VX.margin(sizeClass))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tabs, id: \.self) { t in ToggleChip(title: title(t), selected: tab == t) { tab = t } }
                }
                .padding(.horizontal, VX.margin(sizeClass))
            }
            Group {
                switch tab {
                case .content(let kind): ContentPane(version: version, kind: kind).id(kind)
                case .worlds: WorldsPane(version: version)
                case .settings: VersionSettingsPane(version: version)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.top, 4)
        .vxPage()
        .navigationBarTitleDisplayMode(.inline)
        .launchFlowDialogs(flow)
        .onAppear { if !tabs.contains(tab) { tab = tabs[0] } }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(version.title).font(.vxTitle).foregroundStyle(VX.onSurface).lineLimit(2).minimumScaleFactor(0.7)
                    LoaderBadge(loader: version.loader, isModpack: version.isModpack)
                }
                if version.isModded {
                    Text(version.subtitle).font(.vxCaption).foregroundStyle(VX.onSurfaceVariant).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            PlayControl(version: version, flow: flow) {
                SwiftUI.Label("Play", systemImage: "play.fill")
                    .font(.body.weight(.heavy)).foregroundStyle(VX.onPrimary)
                    .padding(.horizontal, 18).frame(minHeight: 44)
                    .background(VX.primary, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func title(_ t: Tab) -> String {
        switch t {
        case .content(let kind): kind.title
        case .worlds: "Worlds"
        case .settings: "Settings"
        }
    }
}

/// A version's own actions: check its files, the launch plan, delete.
struct VersionSettingsPane: View {
    @EnvironmentObject var model: LauncherModel
    @EnvironmentObject var minecraft: MinecraftLauncher
    @Environment(\.dismiss) private var dismiss
    let version: InstalledVersion
    @State private var confirmDelete = false
    @State private var deleteError: String?

    private var manifestEntry: VersionManifest.Entry? {
        model.manifest?.versions(of: [.release, .snapshot, .oldBeta, .oldAlpha]).first { $0.id == version.id }
    }

    var body: some View {
        List {
            if !version.isModded, let entry = manifestEntry {
                Section {
                    SettingRow("Verify / repair files", summary: "Checks every file and downloads what is missing or damaged.") {
                        Button("Verify") { Task { await model.install(entry) } }
                            .buttonStyle(OutlineButtonStyle(height: 36))
                            .disabled(isBusy(entry.id))
                    }
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                    InstallRowStatus(id: entry.id).listRowBackground(Color.clear)
                }
            }
            Section {
                SettingRow("Launch plan", summary: "Shows how Minecraft would start, without starting it.") {
                    Button("Prepare") { model.preparePlan(version.id) }
                        .buttonStyle(OutlineButtonStyle(height: 36))
                }
                .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                if let plan = model.lastPlan {
                    LabeledContent("Main class", value: plan.mainClass).vxRow()
                    LabeledContent("Java", value: plan.requiredJavaMajor.map(String.init) ?? "?").vxRow()
                    LabeledContent("Classpath entries", value: "\(plan.classpath.count)").vxRow()
                    LabeledContent("Missing files", value: "\(plan.missingFiles.count)").vxRow()
                }
            }
            if let dir = model.gameDirectory(for: version.id) {
                Section {
                    Text(dir.path).font(.caption.monospaced()).foregroundStyle(VX.onSurfaceVariant).textSelection(.enabled).vxRow()
                } header: {
                    Text("Game folder")
                } footer: {
                    Text(version.isModded ? "This version has its own game folder: mods, config and worlds stay apart from other versions." : "Vanilla versions share one game folder.")
                }
            }
            Section {
                SettingRow("Delete version", summary: version.isModded ? "Removes this version and its game folder." : "Removes this version; shared worlds stay.") {
                    Button("Delete") {
                        let blockers = model.versionsBuilding(on: version.id)
                        if blockers.isEmpty { confirmDelete = true }
                        else { deleteError = VersionDeleteError.neededBy(version.id, blockers).description }
                    }
                    .buttonStyle(OutlineButtonStyle(tint: VX.error, height: 36))
                    .disabled(minecraft.gameActive)
                }
                .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            }
        }
        .vxList()
        .confirmationDialog("Delete \(version.title)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    deleteError = await model.deleteVersion(version.id)
                    if deleteError == nil { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
        .alert("Not deleted", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
        }
    }

    private func isBusy(_ id: String) -> Bool {
        switch model.installState[id] {
        case .preparing, .downloading: true
        default: false
        }
    }

    private var deleteMessage: String {
        guard version.isModded else {
            return "Removes Minecraft \(version.id). Worlds, resource packs and settings of vanilla versions are shared and stay."
        }
        let worlds = model.paths.map { VersionDeleter(paths: $0).worldCount(of: version.id) } ?? 0
        let worldText = worlds == 0 ? "its worlds" : "its \(worlds) world\(worlds == 1 ? "" : "s")"
        return "This also deletes \(worldText), mods, shader packs and settings in its game folder. To keep a world, share it from Worlds first. This can't be undone."
    }
}

/// The progress line of a version that is installing or being checked.
struct InstallRowStatus: View {
    @EnvironmentObject var model: LauncherModel
    let id: String
    var body: some View {
        switch model.installState[id] {
        case .preparing:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Preparing…").font(.vxCaption) }
        case .downloading(let stage, let done, let total, let failed):
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: Double(done), total: Double(max(total, 1))).tint(VX.primary)
                Text("\(stage): \(done)/\(total)\(failed > 0 ? " · \(failed) failed" : "")").font(.vxCaption).foregroundStyle(VX.onSurfaceVariant)
            }
        case .finished(let ok, let failed):
            Text(failed == 0 ? "All \(ok) files verified" : "\(failed) files failed — see Settings → Logs")
                .font(.vxCaption).foregroundStyle(failed == 0 ? VX.primary : VX.error)
        case .failed(let msg):
            Text(msg).font(.vxCaption).foregroundStyle(VX.error)
        case .idle, nil:
            EmptyView()
        }
    }
}
