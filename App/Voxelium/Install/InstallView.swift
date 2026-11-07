import SwiftUI
import VoxeliumCore

/// Install: Mojang's version list (releases or snapshots, searchable). A version opens the
/// install sheet, where its mod loader is chosen. Modpacks open from the header.
struct InstallView: View {
    @EnvironmentObject var model: LauncherModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var query = ""
    @State private var snapshots = false
    @State private var target: VersionManifest.Entry?
    @State private var showModpacks = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    PageHeader("Install") {
                        Button { showModpacks = true } label: {
                            SwiftUI.Label("Modpacks", systemImage: "shippingbox")
                        }
                        .buttonStyle(OutlineButtonStyle(tint: VX.onSurface, height: 40))
                    }
                    search
                    HStack(spacing: 8) {
                        ToggleChip(title: "Releases", selected: !snapshots) { snapshots = false }
                        ToggleChip(title: "Snapshots", selected: snapshots) { snapshots = true }
                    }
                    problem
                    LazyVStack(spacing: 6) {
                        if model.manifest == nil && model.manifestProblem == nil {
                            ForEach(0..<9, id: \.self) { VersionRowSkeleton(index: $0) }
                        }
                        ForEach(versions) { entry in
                            Button { target = entry } label: { InstallRow(entry: entry) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, VX.margin(sizeClass)).padding(.bottom, 16)
                .frame(maxWidth: 720).frame(maxWidth: .infinity)
            }
            .vxPage()
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await model.loadManifest() }
            .sheet(item: $target) { entry in
                InstallVersionSheet(entry: entry, initialLoader: .vanilla)
            }
            .sheet(isPresented: $showModpacks, onDismiss: { model.refreshInstalled() }) { ModpackBrowseView() }
        }
    }

    private var versions: [VersionManifest.Entry] {
        let list = model.manifest?.versions(of: snapshots ? [.snapshot] : [.release]) ?? []
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? list : list.filter { $0.id.localizedCaseInsensitiveContains(q) }
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(VX.onSurfaceVariant)
            TextField("Search versions", text: $query)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.search)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(VX.onSurfaceVariant) }
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12).frame(minHeight: 44)
        .background(VX.surface, in: RoundedRectangle(cornerRadius: VX.Radius.small + 2))
    }

    @ViewBuilder private var problem: some View {
        switch model.manifestProblem {
        case .offline:
            Banner(.warning, "No internet connection", message: "Turn on the internet to see Minecraft's versions.") { refresh }
        case .unavailable:
            Banner(.error, "Couldn't load the version list", message: "Minecraft's servers didn't answer. Try again in a moment; details are in Settings → Logs.") { refresh }
        case .startup(let detail):
            Banner(.error, "Voxelium could not start", message: detail)
        case nil:
            EmptyView()
        }
    }

    private var refresh: some View {
        Button("Try again") { Task { await model.loadManifest() } }.font(.footnote.weight(.bold))
    }
}

/// One Minecraft version in the list, with its install progress.
struct InstallRow: View {
    @EnvironmentObject var model: LauncherModel
    let entry: VersionManifest.Entry

    var body: some View {
        let installedHere = model.installedVersions.filter { $0.base == entry.id }
        RowCard(selected: !installedHere.isEmpty) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.id).font(.vxHeadline).foregroundStyle(VX.onSurface)
                if installedHere.isEmpty {
                    Text(entry.releaseTime, style: .date).font(.vxCaption).foregroundStyle(VX.onSurfaceVariant)
                } else {
                    Text("Installed · " + installedHere.map { $0.isModpack ? $0.id : $0.loader ?? "Vanilla" }.joined(separator: ", "))
                        .font(.vxCaption).foregroundStyle(VX.secondary).lineLimit(1)
                }
                InstallRowStatus(id: entry.id)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote.weight(.bold))
                .foregroundStyle(installedHere.isEmpty ? VX.onSurfaceVariant : VX.secondary)
        }
        .contentShape(Rectangle())
    }
}
