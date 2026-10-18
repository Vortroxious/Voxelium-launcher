import SwiftUI
import VoxeliumCore

/// Browse Modrinth for one kind of content, filtered to an installed version's
/// Minecraft version and loader, and install with required dependencies.
struct ModrinthBrowseView: View {
    @EnvironmentObject var model: LauncherModel
    let version: InstalledVersion
    let kind: ContentKind
    /// Called after something was installed, so the library can refresh.
    var onInstalled: () -> Void = {}

    @State private var query = ""
    @State private var sort: ModrinthAPI.Sort = .relevance
    @State private var hits: [ModrinthAPI.SearchHit] = []
    @State private var total = 0
    @State private var loading = false
    @State private var error: String?
    @State private var installed: Set<String> = []
    @State private var selected: ModrinthAPI.SearchHit?
    @State private var irisInstalled = true

    static let irisProjectID = "YL57xq9U"
    private var api: ModrinthAPI { ModrinthAPI() }
    private var gameLoader: String? { version.loader?.lowercased() }
    private var manager: ContentManager? { model.gameDirectory(for: version.id).map(ContentManager.init(gameDirectory:)) }

    var body: some View {
        List {
            if kind == .shaderPacks && version.isModded && !irisInstalled {
                Section {
                    Label("Shader packs need the Iris mod.", systemImage: "info.circle")
                    Button("Get Iris (with Sodium)") {
                        selected = ModrinthAPI.SearchHit(projectId: Self.irisProjectID, slug: "iris", title: "Iris Shaders",
                                                          description: "Shader pack loader", author: nil, downloads: 0,
                                                          iconUrl: nil, projectType: "mod", categories: nil)
                    }
                }
            }
            Section {
                Picker("Sort", selection: $sort) {
                    ForEach(ModrinthAPI.Sort.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
            }
            if let error {
                Section {
                    Text(error).foregroundStyle(.red)
                    Button("Try again") { Task { await search(reset: true) } }
                }
            }
            Section {
                ForEach(hits) { hit in
                    Button { selected = hit } label: { HitRow(hit: hit, installed: installed.contains(hit.projectId)) }
                        .buttonStyle(.plain)
                }
                if hits.count < total {
                    HStack {
                        Spacer()
                        if loading { ProgressView() } else { Button("Load more") { Task { await search(reset: false) } } }
                        Spacer()
                    }
                } else if loading && hits.isEmpty {
                    ForEach(0..<8, id: \.self) { ModrinthHitSkeleton(index: $0) }
                }
            } header: {
                Text(total > 0 ? "\(total) on Modrinth for \(version.base)\(gameLoader.map { " · \($0.capitalized)" } ?? "")" : "Modrinth")
            }
        }
        .navigationTitle(kind.title)
        .searchable(text: $query, prompt: "Search Modrinth")
        .onSubmit(of: .search) { Task { await search(reset: true) } }
        .onChange(of: sort) { _ in Task { await search(reset: true) } }
        .task {
            await refreshInstalled()
            await search(reset: true)
        }
        .sheet(item: $selected) { hit in
            NavigationStack {
                ModrinthProjectView(version: version, kind: hit.projectId == Self.irisProjectID ? .mods : kind,
                                    hit: hit, installed: installed) {
                    Task { await refreshInstalled() }
                    onInstalled()
                }
            }
        }
    }

    private func search(reset: Bool) async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let page = try await api.search(query, kind: kind, gameVersion: version.base, gameLoader: gameLoader,
                                            sort: sort, offset: reset ? 0 : hits.count)
            hits = reset ? page.hits : hits + page.hits
            total = page.totalHits
        } catch {
            self.error = model.isOffline || LauncherModel.looksOffline(error)
                ? "No internet connection. Please turn on your internet and try again."
                : "Couldn't reach Modrinth. Please try again in a moment."
            model.log.error("content", "Modrinth search failed: \(error)")
        }
    }

    private func refreshInstalled() async {
        guard let manager else { return }
        let installer = ModrinthInstaller(api: api)
        var ids = Set((try? await installer.installedProjects(manager, kind: kind))?.keys.map { $0 } ?? [])
        if kind == .shaderPacks {
            let mods = (try? await installer.installedProjects(manager, kind: .mods))?.keys.map { $0 } ?? []
            irisInstalled = mods.contains(Self.irisProjectID)
            ids.formUnion(mods)
        }
        installed = ids
    }
}

struct HitRow: View {
    let hit: ModrinthAPI.SearchHit
    let installed: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: hit.iconUrl.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Image(systemName: "shippingbox").foregroundStyle(.secondary)
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(hit.title).font(.headline).lineLimit(1)
                    if installed { Text("Installed").font(.caption2.bold()).foregroundStyle(.green) }
                }
                Text(hit.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text([hit.author.map { "by \($0)" }, "\(hit.downloads.formatted(.number.notation(.compactName))) downloads"]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

/// One project: pick a compatible version, see what it brings in, install.
struct ModrinthProjectView: View {
    @EnvironmentObject var model: LauncherModel
    @Environment(\.dismiss) private var dismiss
    let version: InstalledVersion
    let kind: ContentKind
    let hit: ModrinthAPI.SearchHit
    let installed: Set<String>
    var onInstalled: () -> Void

    @State private var versions: [ModrinthAPI.Version] = []
    @State private var chosenID = ""
    @State private var plan: ModrinthInstallPlan?
    @State private var loading = true
    @State private var installing = false
    @State private var progress: (done: Int, total: Int)?
    @State private var result: (text: String, ok: Bool)?
    /// The version picker opens as its own page, and coming back re-runs .task: without
    /// this the list reloaded and the newest version was chosen again.
    @State private var started = false

    private var installer: ModrinthInstaller { ModrinthInstaller() }
    private var gameLoader: String? { version.loader?.lowercased() }
    private var chosen: ModrinthAPI.Version? { versions.first { $0.id == chosenID } }

    var body: some View {
        Form {
            Section {
                Text(hit.description).font(.callout)
                if installed.contains(hit.projectId) {
                    Label("Installed. Installing again replaces it with the version below.", systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.green)
                }
            }
            Section("Version for \(version.base)") {
                if loading && versions.isEmpty {
                    HStack { ProgressView(); Text("Loading versions…") }
                } else if versions.isEmpty {
                    Text("No version of \(hit.title) for Minecraft \(version.base)\(gameLoader.map { " with \($0.capitalized)" } ?? "").")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Version", selection: $chosenID) {
                        ForEach(versions.prefix(30)) { v in
                            Text(v.versionNumber + (v.versionType == "release" ? "" : " (\(v.versionType))")).tag(v.id)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }
            }
            if let plan {
                Section("Will install") {
                    ForEach(plan.items, id: \.projectID) { item in
                        LabeledContent(item.title + (item.isDependency ? " (required)" : ""),
                                       value: item.version.primaryFile.map { ByteCountFormatter.string(fromByteCount: $0.size, countStyle: .file) } ?? "")
                    }
                    if !plan.alreadyInstalled.isEmpty {
                        Text("\(plan.alreadyInstalled.count) required mod\(plan.alreadyInstalled.count == 1 ? " is" : "s are") already installed.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(plan.unavailable, id: \.self) {
                        Label("Required \($0) has no compatible version.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    ForEach(plan.conflicts, id: \.self) {
                        Label("Conflicts with installed \($0).", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
            } else if chosen != nil {
                Section { HStack { ProgressView(); Text("Checking dependencies…") } }
            }
            Section {
                if let result {
                    Label(result.text, systemImage: result.ok ? "checkmark.circle.fill" : "xmark.octagon")
                        .foregroundStyle(result.ok ? Color.green : Color.red)
                }
                if installing {
                    HStack {
                        ProgressView()
                        Text(progress.map { "Downloading \($0.done)/\($0.total)…" } ?? "Downloading…")
                    }
                } else {
                    Button {
                        Task { await install() }
                    } label: {
                        Label(plan.map { $0.items.count > 1 ? "Install \(hit.title) + \($0.items.count - 1) required" : "Install \(hit.title)" } ?? "Install",
                              systemImage: "arrow.down.circle")
                    }
                    .disabled(plan == nil || result?.ok == true)
                }
            }
        }
        .navigationTitle(hit.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(result?.ok == true ? "Done" : "Cancel") { dismiss() } } }
        .task {
            guard !started else { return }
            started = true
            await loadVersions()
        }
        .onChange(of: chosenID) { _ in Task { await makePlan() } }
    }

    private func loadVersions() async {
        loading = true
        defer { loading = false }
        let loaders = ModrinthAPI.loaders(for: kind, gameLoader: gameLoader)
        versions = (try? await installer.api.versions(project: hit.projectId, loaders: loaders, gameVersion: version.base)) ?? []
        chosenID = ModrinthAPI.preferred(versions)?.id ?? ""
        if chosenID.isEmpty { plan = nil }
    }

    private func makePlan() async {
        guard let chosen else { plan = nil; return }
        plan = nil
        plan = try? await installer.plan(chosen, title: hit.title, kind: kind, gameVersion: version.base,
                                         gameLoader: gameLoader, installed: installed.subtracting([hit.projectId]))
    }

    private func install() async {
        guard let plan, let dir = model.gameDirectory(for: version.id) else { return }
        installing = true
        result = nil
        defer { installing = false }
        let manager = ContentManager(gameDirectory: dir)
        do {
            // Replace an older copy of the same project (found by hash).
            let current = (try? await installer.installedProjects(manager, kind: kind)) ?? [:]
            let report = try await installer.install(plan, kind: kind, into: manager, replacing: current) { p in
                Task { @MainActor in progress = (p.completed, p.total) }
            }
            if report.succeeded {
                result = ("Installed \(plan.items.map(\.title).joined(separator: ", ")).", true)
                model.log.info("content", "Modrinth: installed \(plan.items.map { "\($0.title) \($0.version.versionNumber)" }.joined(separator: ", ")) into \(version.id)")
                onInstalled()
            } else {
                result = ("\(report.failures.count) download\(report.failures.count == 1 ? "" : "s") failed. Nothing was replaced.", false)
                for (item, err) in report.failures { model.log.error("content", "Modrinth download \(item.url.lastPathComponent): \(err)") }
            }
        } catch {
            result = (String(describing: error), false)
        }
    }
}
