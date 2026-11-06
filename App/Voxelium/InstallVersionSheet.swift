import SwiftUI
import VoxeliumCore

/// Asked when installing a Minecraft version: which mod loader to install it with
/// (as ZalithLauncher2's version installer does): Vanilla, Fabric, Quilt, Forge or NeoForge.
struct InstallVersionSheet: View {
    @EnvironmentObject var model: LauncherModel
    @Environment(\.dismiss) private var dismiss
    let entry: VersionManifest.Entry
    let initialLoader: ModLoader

    @State private var loader: ModLoader = .vanilla
    @State private var builds: [LoaderVersion] = []
    @State private var build = ""
    @State private var loading = false
    @State private var error: String?
    @State private var showAllBuilds = false

    private var needsBuild: Bool { loader != .vanilla }
    private var canInstall: Bool { loader.isAvailable(minecraft: entry.id) && (!needsBuild || !build.isEmpty) }
    private var shownBuilds: [LoaderVersion] { showAllBuilds ? builds : Array(builds.prefix(12)) }
    private var vanillaInstalled: Bool { model.installed.contains(entry.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Minecraft \(entry.id)").font(.vxTitle).foregroundStyle(VX.onSurface)
                        Text("\(entry.type == .release ? "Release" : "Snapshot") · \(entry.releaseTime.formatted(date: .abbreviated, time: .omitted))")
                            .font(.vxCaption).foregroundStyle(VX.onSurfaceVariant)
                    }
                    Spacer()
                    Button("Cancel") { dismiss() }.font(.body.weight(.semibold))
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Mod loader")
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        ForEach(ModLoader.allCases) { l in loaderTile(l) }
                    }
                }

                if needsBuild { buildRow }

                Text(note).font(.vxCaption).foregroundStyle(VX.onSurfaceVariant)

                Button {
                    let (l, b, mc) = (loader, build, entry.id)
                    dismiss()
                    Task {
                        if l == .vanilla { await model.install(entry) }
                        else { await model.installLoader(l, build: b, minecraft: mc) }
                    }
                } label: {
                    Text(installTitle)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!canInstall)
                .opacity(canInstall ? 1 : 0.5)
            }
            .padding(20)
        }
        .background(VX.surfaceLow.ignoresSafeArea())
        .tint(VX.primary)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task(id: loader) { await loadBuilds() }
        .onAppear { loader = initialLoader.isAvailable(minecraft: entry.id) ? initialLoader : .vanilla }
    }

    private var installTitle: String {
        if loader == .vanilla { return vanillaInstalled ? "Verify / repair \(entry.id)" : "Install \(entry.id)" }
        return "Install \(loader.displayName) \(entry.id)"
    }

    private var note: String {
        if loader == .vanilla {
            return vanillaInstalled
                ? "Installed. Installing again checks every file and downloads what is missing or damaged."
                : "Plain Minecraft, sharing one game folder with the other vanilla versions."
        }
        return "Modded versions get their own game folder (mods, config, saves), so they don't mix with vanilla."
            + (loader.usesForgeInstaller ? " The first launch also finishes setting up \(loader.displayName), which takes a minute or two." : "")
    }

    private func loaderTile(_ l: ModLoader) -> some View {
        let available = l.isAvailable(minecraft: entry.id)
        let selected = loader == l
        return Button { if available { loader = l } } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(l.displayName).font(.vxHeadline).foregroundStyle(available ? VX.onSurface : VX.onSurfaceVariant)
                Text(available ? Self.blurb(l) : "From \(l.oldestMinecraft ?? "?")")
                    .font(.vxCaption).foregroundStyle(selected ? VX.onPrimaryContainer : VX.onSurfaceVariant).lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
            .background(selected ? VX.primaryContainer : VX.surfaceHigh, in: RoundedRectangle(cornerRadius: VX.Radius.medium))
            .overlay { RoundedRectangle(cornerRadius: VX.Radius.medium).stroke(selected ? VX.primary : VX.outline, lineWidth: selected ? 2 : 1) }
            .opacity(available ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var buildRow: some View {
        if loading {
            Banner(.progress, "Loading \(loader.displayName) builds…")
        } else if let error {
            Banner(.error, "Couldn't load \(loader.displayName) builds", message: error) {
                Button("Try again") { Task { await loadBuilds() } }.font(.footnote.weight(.bold))
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                SettingRow("\(loader.displayName) build") {
                    Menu {
                        Picker("Build", selection: $build) {
                            ForEach(shownBuilds) { b in Text(label(b)).tag(b.version) }
                        }
                        if builds.count > 12 && !showAllBuilds {
                            Button("Show all \(builds.count) builds") { showAllBuilds = true }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(builds.first { $0.version == build }.map(label) ?? "Choose").lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down").font(.caption2)
                        }
                        .font(.subheadline).foregroundStyle(VX.onSurface)
                        .padding(.horizontal, 12).frame(minHeight: 36)
                        .overlay { RoundedRectangle(cornerRadius: VX.Radius.small).stroke(VX.outline, lineWidth: 1) }
                    }
                }
            }
        }
    }

    private func label(_ b: LoaderVersion) -> String {
        b.version + (b.stable ? "" : " (beta)") + (b.version == ModLoaderMeta.recommended(builds)?.version ? " · recommended" : "")
    }

    private func loadBuilds() async {
        guard needsBuild else { return }
        loading = true
        error = nil
        builds = []
        build = ""
        defer { loading = false }
        do {
            let list = try await model.loaderBuilds(loader, minecraft: entry.id)
            builds = list
            build = ModLoaderMeta.recommended(list)?.version ?? ""
        } catch {
            self.error = String(describing: error)
        }
    }

    static func blurb(_ l: ModLoader) -> String {
        switch l {
        case .vanilla: "No mods"
        case .fabric: "Most mods"
        case .quilt: "Runs Fabric mods"
        case .forge: "Classic"
        case .neoforge: "Create, tech"
        }
    }
}
