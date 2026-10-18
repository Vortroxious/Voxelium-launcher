import SwiftUI
import VoxeliumCore

/// Asked when installing a Minecraft version: which mod loader to install it with
/// (as ZalithLauncher2's version installer does). Vanilla, Fabric and Quilt work;
/// Forge and NeoForge are shown as coming later.
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

    private var needsBuild: Bool { loader == .fabric || loader == .quilt }
    private var canInstall: Bool { loader.isAvailable && (!needsBuild || !build.isEmpty) }
    private var shownBuilds: [LoaderVersion] { showAllBuilds ? builds : Array(builds.prefix(12)) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(ModLoader.allCases) { l in
                        Button {
                            if l.isAvailable { loader = l }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(l.displayName).foregroundStyle(l.isAvailable ? Color.primary : Color.secondary)
                                    Text(Self.blurb(l)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if loader == l { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                            }
                        }
                        .disabled(!l.isAvailable)
                    }
                } header: {
                    Text("Mod loader")
                } footer: {
                    Text(loader == .vanilla
                         ? "Plain Minecraft, sharing one game folder with the other vanilla versions."
                         : "Modded versions get their own game folder (mods, config, saves), so they don't mix with vanilla.")
                }

                if needsBuild {
                    Section {
                        if loading {
                            HStack { ProgressView(); Text("Loading \(loader.displayName) builds…") }
                        } else if let error {
                            Text(error).font(.callout).foregroundStyle(.red)
                            Button("Try again") { Task { await loadBuilds() } }
                        } else {
                            Picker("Build", selection: $build) {
                                ForEach(shownBuilds) { b in
                                    Text(b.version + (b.stable ? "" : " (beta)") + (b.version == ModLoaderMeta.recommended(builds)?.version ? " · recommended" : ""))
                                        .tag(b.version)
                                }
                            }
                            .pickerStyle(.navigationLink)
                            if builds.count > 12 && !showAllBuilds {
                                Button("Show all \(builds.count) builds") { showAllBuilds = true }
                            }
                        }
                    } header: {
                        Text("\(loader.displayName) version")
                    }
                }

                Section {
                    Button {
                        let (l, b, mc) = (loader, build, entry.id)
                        dismiss()
                        Task {
                            if l == .vanilla { await model.install(entry) }
                            else { await model.installLoader(l, build: b, minecraft: mc) }
                        }
                    } label: {
                        Label(loader == .vanilla ? "Install \(entry.id)" : "Install \(loader.displayName) for \(entry.id)",
                              systemImage: "arrow.down.circle")
                    }
                    .disabled(!canInstall)
                }
            }
            .navigationTitle("Install \(entry.id)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task(id: loader) { await loadBuilds() }
            .onAppear { loader = initialLoader.isAvailable ? initialLoader : .vanilla }
        }
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
        case .fabric: "Lightweight mod loader; most performance mods (Sodium, Lithium…)"
        case .quilt: "Fabric-compatible loader; runs most Fabric mods"
        case .forge, .neoforge: "Coming later: its installer needs its own Java run on iOS"
        }
    }
}
