import SwiftUI
import VoxeliumCore

/// Play, the home page: the last played version with a big Play button, every other installed
/// version below it, and who you play as.
struct PlayView: View {
    @EnvironmentObject var model: LauncherModel
    @EnvironmentObject var minecraft: MinecraftLauncher
    @EnvironmentObject var accounts: AccountModel
    @EnvironmentObject var updates: UpdateModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Binding var tab: AppTab
    @StateObject private var flow = LaunchFlow()
    @State private var counts: [String: VersionCounts] = [:]
    @State private var showJITSettings = false

    struct VersionCounts: Equatable { var mods: Int?; var worlds: Int }

    var body: some View {
        let installed = model.installedVersions
        let last = installed.first { $0.id == model.settings.selectedVersion } ?? installed.first
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    PageHeader("Play") { accountPill }
                    banners
                    if let last {
                        LastPlayedCard(version: last, counts: counts[last.id], memoryMB: model.settings.maxMemoryMB, flow: flow)
                        HStack {
                            SectionLabel("Installed · \(installed.count)")
                            Spacer()
                            Button("+ Install") { tab = .install }.font(.subheadline.weight(.bold)).frame(minHeight: 44)
                        }
                        ForEach(installed.filter { $0.id != last.id }) { v in
                            InstalledVersionRow(version: v, counts: counts[v.id], flow: flow)
                        }
                    } else if model.paths != nil {
                        emptyState
                    }
                    Text("Not affiliated with Mojang or Microsoft. Minecraft's files are downloaded from Mojang to your device.")
                        .font(.vxCaption).foregroundStyle(VX.onSurfaceVariant).padding(.top, 8)
                }
                .padding(.horizontal, VX.margin(sizeClass)).padding(.bottom, 16)
                .frame(maxWidth: 720).frame(maxWidth: .infinity)
            }
            .vxPage()
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { model.refreshInstalled() }
        }
        .launchFlowDialogs(flow)
        .sheet(isPresented: $showJITSettings) { BuiltInJITView(showsDone: true) }
        .task(id: installed.map(\.id)) { counts = Self.count(installed, model: model) }
    }

    private var accountPill: some View {
        let microsoft = model.settings.useMicrosoftAccount ? accounts.account : nil
        return Button { tab = .accounts } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.fill").font(.subheadline).foregroundStyle(VX.onSecondaryContainer)
                    .frame(width: 30, height: 30).background(VX.secondaryContainer, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 0) {
                    Text(microsoft?.username ?? model.settings.playerName).font(.footnote.weight(.bold)).lineLimit(1)
                    Text(microsoft == nil ? "Offline" : "Microsoft").font(.caption2).foregroundStyle(VX.onSurfaceVariant)
                }
            }
            .foregroundStyle(VX.onSurface)
            .padding(.leading, 5).padding(.trailing, 12).frame(minHeight: 44)
            .background(VX.surface, in: Capsule())
            .overlay { Capsule().stroke(VX.outline, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Playing as \(microsoft?.username ?? model.settings.playerName). Accounts")
    }

    @ViewBuilder private var banners: some View {
        if let release = updates.banner {
            Banner(.info, "Voxelium \(release.version) is available",
                   message: "You have \(UpdateModel.currentVersion). Install the new IPA with the same Apple ID; your versions and worlds stay.") {
                HStack(spacing: 16) {
                    Link("Open the release", destination: release.htmlUrl).font(.footnote.weight(.bold))
                    Button("Not now") { updates.dismiss(release) }.font(.footnote)
                }
            }
        }
        switch minecraft.state {
        case .idle:
            EmptyView()
        case .starting(let m), .running(let m):
            Banner(.progress, m)
        case .waitingForJIT(let m):
            Banner(.progress, m) { Button("Cancel") { minecraft.cancelJITWait() }.font(.footnote.weight(.bold)) }
        case .jitProblem(let p):
            Banner(.error, p.title, message: p.message) {
                HStack(spacing: 16) {
                    if p.showsSetupGuide { Link("Setup guide", destination: setupGuideURL).font(.footnote.weight(.bold)) }
                    if p == .pairingFileMissing || p == .pairingFileInvalid {
                        Button("Import a pairing file") { showJITSettings = true }.font(.footnote.weight(.bold))
                    }
                }
            }
        case .finished(let ok, let m):
            Banner(ok ? .info : .error, ok ? "Minecraft exited" : "Minecraft did not start", message: m)
        }
        if JITCoordinator.getTaskAllow == 0 {
            Banner(.warning, JITProblem.missingGetTaskAllow.title, message: JITProblem.missingGetTaskAllow.message)
        }
        if case .startup(let detail) = model.manifestProblem {
            Banner(.error, "Voxelium could not start", message: detail)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nothing installed yet").font(.vxTitle)
            Text("Pick a Minecraft version and a mod loader to get started.").font(.vxBody).foregroundStyle(VX.onSurfaceVariant)
            Button("Install Minecraft") { tab = .install }.buttonStyle(PrimaryButtonStyle(height: 48)).padding(.top, 4)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VX.surface, in: RoundedRectangle(cornerRadius: VX.Radius.extraLarge))
    }

    /// Mods and worlds per version, read from their game folders.
    static func count(_ versions: [InstalledVersion], model: LauncherModel) -> [String: VersionCounts] {
        var out: [String: VersionCounts] = [:]
        for v in versions {
            guard let dir = model.gameDirectory(for: v.id) else { continue }
            let mods = v.isModded ? ContentManager(gameDirectory: dir).list(.mods).count : nil
            out[v.id] = VersionCounts(mods: mods, worlds: WorldManager(gameDirectory: dir).list().count)
        }
        return out
    }
}

private func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

/// The big card for the last played version.
struct LastPlayedCard: View {
    let version: InstalledVersion
    let counts: PlayView.VersionCounts?
    let memoryMB: Int
    @ObservedObject var flow: LaunchFlow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LAST PLAYED").font(.caption2.weight(.bold)).kerning(0.8).foregroundStyle(VX.secondary)
            HStack(spacing: 8) {
                Text(version.title).font(.vxTitle).foregroundStyle(VX.onSurface).lineLimit(2)
                LoaderBadge(loader: version.loader, isModpack: version.isModpack)
            }
            if version.isModded {
                Text(version.subtitle).font(.footnote).foregroundStyle(VX.onHighlight).lineLimit(1)
            }
            HStack(spacing: 6) {
                if let mods = counts?.mods { InfoChip(text: plural(mods, "mod")) }
                if let worlds = counts?.worlds { InfoChip(text: plural(worlds, "world")) }
                InfoChip(text: memoryMB % 1024 == 0 ? "\(memoryMB / 1024) GB memory" : "\(memoryMB) MB memory")
            }
            .padding(.top, 4).padding(.bottom, 8)
            HStack(spacing: 10) {
                PlayControl(version: version, flow: flow) {
                    SwiftUI.Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                VersionMenu(version: version) {
                    Image(systemName: "ellipsis").font(.title3.weight(.bold)).foregroundStyle(VX.onSecondaryContainer)
                        .frame(width: 52, height: 52)
                        .overlay { Circle().stroke(VX.highlightBorder, lineWidth: 1) }
                }
                .accessibilityLabel("More for \(version.title)")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VX.highlight, in: RoundedRectangle(cornerRadius: VX.Radius.extraLarge))
        .overlay { RoundedRectangle(cornerRadius: VX.Radius.extraLarge).stroke(VX.highlightBorder, lineWidth: 1) }
    }
}

/// One installed version under the card.
struct InstalledVersionRow: View {
    let version: InstalledVersion
    let counts: PlayView.VersionCounts?
    @ObservedObject var flow: LaunchFlow

    var body: some View {
        RowCard {
            VersionMenu(version: version) {
                HStack(spacing: 10) {
                    LoaderBadge(loader: version.loader, isModpack: version.isModpack)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(version.title).font(.vxHeadline).foregroundStyle(VX.onSurface).lineLimit(1)
                        Text(detail).font(.vxCaption).foregroundStyle(VX.onSurfaceVariant).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            PlayControl(version: version, flow: flow) {
                Image(systemName: "play.fill").font(.system(size: 17, weight: .bold)).foregroundStyle(VX.primary)
                    .frame(width: 44, height: 44).background(VX.secondaryContainer, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(version.title)")
        }
    }

    private var detail: String {
        var parts: [String] = []
        if version.isModpack { parts.append("Modpack · \(version.loaderLine)") } else if !version.isModded { parts.append("Vanilla") }
        if let mods = counts?.mods { parts.append(plural(mods, "mod")) }
        if let worlds = counts?.worlds, worlds > 0 { parts.append(plural(worlds, "world")) }
        return parts.joined(separator: " · ")
    }
}
