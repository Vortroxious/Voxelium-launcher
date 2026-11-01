import SwiftUI
import VoxeliumCore

/// CurseForge API keys, never logged: Voxelium's own (added to Info.plist by
/// scripts/build-ipa.sh from the git-ignored Config/curseforge.key), else one the player
/// entered, kept in the Keychain.
enum CurseForgeKey {
    private static let keychain = KeychainStore(service: "io.github.voxelium.curseforge")
    private static let account = "apiKey"

    /// Voxelium's key, in release builds.
    static var builtIn: String? {
        (Bundle.main.object(forInfoDictionaryKey: "VoxeliumCurseForgeKey") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
    /// The player's own key.
    static var value: String? { keychain.read(account).flatMap { String(data: $0, encoding: .utf8) } }
    static func save(_ key: String) throws { try keychain.write(Data(key.utf8), for: account) }
    static func delete() { try? keychain.delete(account) }
}

/// Browse CurseForge for one kind of content, filtered to an installed version's
/// Minecraft version and loader, and install with required dependencies. Files whose
/// author doesn't allow downloads in other apps get a link to CurseForge instead.
struct CurseForgeBrowseView: View {
    @EnvironmentObject var model: LauncherModel
    let version: InstalledVersion
    let kind: ContentKind
    var onInstalled: () -> Void = {}

    @State private var key = CurseForgeKey.value
    /// CurseForge refused Voxelium's own key this session (revoked): fall back to the player's.
    @State private var builtInRejected = false

    var body: some View {
        Group {
            if let builtIn = CurseForgeKey.builtIn, !builtInRejected {
                CurseForgeSearchView(version: version, kind: kind, api: CurseForgeAPI(key: builtIn), onInstalled: onInstalled,
                                     usingBuiltInKey: true) {
                    builtInRejected = true
                    model.log.error("content", "CurseForge refused Voxelium's built-in API key; asking for the player's own")
                }
            } else if let key {
                CurseForgeSearchView(version: version, kind: kind, api: CurseForgeAPI(key: key), onInstalled: onInstalled)
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Menu {
                                Button("Remove API key", role: .destructive) {
                                    CurseForgeKey.delete()
                                    self.key = nil
                                    model.log.info("content", "CurseForge API key removed")
                                }
                            } label: { Label("CurseForge", systemImage: "ellipsis.circle") }
                        }
                    }
            } else {
                CurseForgeKeyView(builtInRejected: builtInRejected) { self.key = $0 }
            }
        }
        .navigationTitle(kind.title)
    }
}

/// Asks for the player's own API key and checks it before saving.
struct CurseForgeKeyView: View {
    @EnvironmentObject var model: LauncherModel
    /// Voxelium's own key stopped working, so the player's is needed for now.
    var builtInRejected = false
    var onSaved: (String) -> Void

    @State private var entered = ""
    @State private var checking = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Text(builtInRejected
                     ? "CurseForge isn't accepting Voxelium's API key right now. Until a Voxelium update fixes that, you can browse with your own key, which CurseForge gives out for free."
                     : "CurseForge only lets apps browse it with an API key. This copy of Voxelium has none built in, so it uses your own, which CurseForge gives out for free.")
                    .font(.callout)
                Link(destination: URL(string: "https://console.curseforge.com/")!) {
                    Label("Get a key at console.curseforge.com", systemImage: "key")
                }
            } footer: {
                Text("Sign in there, create an API key, copy it, and paste it below. It's kept in the iOS Keychain on this iPhone.")
            }
            Section("API key") {
                SecureField("Paste your API key", text: $entered)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if let error {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
                if checking {
                    HStack(spacing: 8) { ProgressView(); Text("Checking the key…") }
                } else {
                    Button("Save") { Task { await save() } }
                        .disabled(entered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() async {
        let key = entered.trimmingCharacters(in: .whitespacesAndNewlines)
        checking = true
        error = nil
        defer { checking = false }
        do {
            // A one-result search: also catches keys CurseForge won't let search.
            _ = try await CurseForgeAPI(key: key).search("", kind: .mods, gameVersion: "1.21.11", gameLoader: nil, pageSize: 1)
            try CurseForgeKey.save(key)
            model.log.info("content", "CurseForge API key saved")
            onSaved(key)
        } catch let e as CurseForgeError {
            error = e.description
        } catch {
            self.error = LauncherModel.looksOffline(error)
                ? "No internet connection. Please turn on your internet and try again."
                : "Couldn't reach CurseForge. Please try again in a moment."
        }
    }
}

struct CurseForgeSearchView: View {
    @EnvironmentObject var model: LauncherModel
    let version: InstalledVersion
    let kind: ContentKind
    let api: CurseForgeAPI
    var onInstalled: () -> Void
    /// Voxelium's own key, not the player's: problems with it are worded for the player.
    var usingBuiltInKey = false
    /// CurseForge refused the key, or the player chose their own instead.
    var onKeyRejected: () -> Void = {}

    @State private var query = ""
    @State private var sort: CurseForgeAPI.Sort = .popularity
    @State private var mods: [CurseForgeAPI.Mod] = []
    @State private var total = 0
    @State private var loading = false
    @State private var error: String?
    /// The built-in key works but CurseForge doesn't let it search: offer the player's own key.
    @State private var offerOwnKey = false
    @State private var installed: Set<Int> = []
    @State private var selected: CurseForgeAPI.Mod?

    private var gameLoader: String? { version.loader?.lowercased() }
    private var manager: ContentManager? { model.gameDirectory(for: version.id).map(ContentManager.init(gameDirectory:)) }

    var body: some View {
        List {
            if kind == .shaderPacks && version.isModded {
                Section {
                    Label("Shader packs need the \(gameLoader == "forge" ? "Oculus" : "Iris") mod. If it isn't installed yet, get it from Browse Modrinth.",
                          systemImage: "info.circle").font(.callout)
                }
            }
            Section {
                Picker("Sort", selection: $sort) {
                    ForEach(CurseForgeAPI.Sort.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            if let error {
                Section {
                    Text(error).foregroundStyle(.red)
                    Button("Try again") { Task { await search(reset: true) } }
                    if offerOwnKey {
                        Button("Use my own API key instead") { onKeyRejected() }
                    }
                }
            }
            Section {
                ForEach(mods) { mod in
                    Button { selected = mod } label: {
                        HitRow(title: mod.name, description: mod.summary, author: mod.authors?.first?.name,
                               downloads: Int(mod.downloadCount), iconURL: mod.logo?.thumbnailUrl.flatMap(URL.init(string:)),
                               installed: installed.contains(mod.id))
                    }
                    .buttonStyle(.plain)
                }
                if mods.count < total {
                    HStack {
                        Spacer()
                        if loading { ProgressView() } else { Button("Load more") { Task { await search(reset: false) } } }
                        Spacer()
                    }
                } else if loading && mods.isEmpty {
                    ForEach(0..<8, id: \.self) { ModrinthHitSkeleton(index: $0) }
                }
            } header: {
                Text(total > 0 ? "\(total) on CurseForge for \(version.base)\(gameLoader.map { " · \($0.capitalized)" } ?? "")" : "CurseForge")
            }
        }
        .searchable(text: $query, prompt: "Search CurseForge")
        .onSubmit(of: .search) { Task { await search(reset: true) } }
        .onChange(of: sort) { _ in Task { await search(reset: true) } }
        .task {
            refreshInstalled()
            await search(reset: true)
        }
        .sheet(item: $selected) { mod in
            NavigationStack {
                CurseForgeProjectView(version: version, kind: kind, mod: mod, api: api, installed: installed) {
                    refreshInstalled()
                    onInstalled()
                }
            }
        }
    }

    private func search(reset: Bool) async {
        loading = true
        error = nil
        offerOwnKey = false
        defer { loading = false }
        do {
            // CurseForge pages by index; it caps index + pageSize at 10,000.
            let page = try await api.search(query, kind: kind, gameVersion: version.base, gameLoader: gameLoader,
                                            sort: sort, index: reset ? 0 : mods.count)
            mods = reset ? page.mods : mods + page.mods.filter { m in !mods.contains { $0.id == m.id } }
            total = min(page.totalCount, 10_000)
        } catch let e as CurseForgeError {
            model.log.error("content", "CurseForge search failed: \(e)")
            switch e {
            case .invalidKey where usingBuiltInKey:
                onKeyRejected()
            case .searchNotAllowed where usingBuiltInKey:
                error = "CurseForge isn't letting Voxelium search right now. Please try again later, or browse with your own CurseForge API key."
                offerOwnKey = true
            default:
                error = e.description
            }
        } catch {
            self.error = model.isOffline || LauncherModel.looksOffline(error)
                ? "No internet connection. Please turn on your internet and try again."
                : "Couldn't reach CurseForge. Please try again in a moment."
            model.log.error("content", "CurseForge search failed: \(error)")
        }
    }

    private func refreshInstalled() {
        guard let manager else { return }
        installed = Set(CurseForgeIndex.load(manager).installed(manager).keys)
    }
}

/// One CurseForge project: pick a compatible file, see what it brings in, install.
struct CurseForgeProjectView: View {
    @EnvironmentObject var model: LauncherModel
    @Environment(\.dismiss) private var dismiss
    let version: InstalledVersion
    let kind: ContentKind
    let mod: CurseForgeAPI.Mod
    let api: CurseForgeAPI
    let installed: Set<Int>
    var onInstalled: () -> Void

    @State private var files: [CurseForgeAPI.File] = []
    @State private var chosenID = 0
    @State private var plan: CurseForgeInstallPlan?
    @State private var loading = true
    @State private var installing = false
    @State private var progress: (done: Int, total: Int)?
    @State private var result: (text: String, ok: Bool)?
    @State private var started = false

    private var installer: CurseForgeInstaller { CurseForgeInstaller(api: api) }
    private var gameLoader: String? { version.loader?.lowercased() }
    private var chosen: CurseForgeAPI.File? { files.first { $0.id == chosenID } }
    /// The chosen file itself can't be downloaded here (only on CurseForge's website).
    private var chosenBlocked: Bool { chosen.map { $0.downloadURL == nil } ?? false }

    var body: some View {
        Form {
            Section {
                Text(mod.summary).font(.callout)
                if let url = mod.websiteURL {
                    Link(destination: url) { Label("Open on CurseForge", systemImage: "safari") }
                }
                if installed.contains(mod.id) {
                    Label("Installed. Installing again replaces it with the file below.", systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.green)
                }
            }
            Section("File for \(version.base)") {
                if loading && files.isEmpty {
                    HStack { ProgressView(); Text("Loading files…") }
                } else if files.isEmpty {
                    Text("No file of \(mod.name) for Minecraft \(version.base)\(kind == .mods ? gameLoader.map { " with \($0.capitalized)" } ?? "" : "").")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("File", selection: $chosenID) {
                        ForEach(files.prefix(30)) { f in
                            Text(f.displayName + (f.releaseType == 1 ? "" : " (\(f.releaseName))")).tag(f.id)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }
            }
            if let plan {
                Section("Will install") {
                    ForEach(plan.downloadable, id: \.mod.id) { item in
                        LabeledContent(item.mod.name + (item.isDependency ? " (required)" : ""),
                                       value: ByteCountFormatter.string(fromByteCount: item.file.fileLength, countStyle: .file))
                    }
                    if !plan.alreadyInstalled.isEmpty {
                        Text("\(plan.alreadyInstalled.count) required mod\(plan.alreadyInstalled.count == 1 ? " is" : "s are") already installed.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(plan.unavailable, id: \.self) {
                        Label("Required \($0) has no compatible file.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    ForEach(plan.conflicts, id: \.self) {
                        Label("Conflicts with installed \($0).", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
                if !plan.blocked.isEmpty {
                    Section {
                        ForEach(plan.blocked, id: \.mod.id) { item in
                            if let url = item.mod.websiteURL.map({ $0.appendingPathComponent("files").appendingPathComponent("\(item.file.id)") }) {
                                Link(destination: url) {
                                    Label("\(item.mod.name): \(item.file.displayName)", systemImage: "safari")
                                }
                            } else {
                                Text("\(item.mod.name): \(item.file.displayName)")
                            }
                        }
                    } header: {
                        Text("Only on CurseForge's website")
                    } footer: {
                        Text("These authors only allow downloads on CurseForge's website. Download the file there, then add it with + → Import from Files.")
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
                        Label(plan.map { $0.downloadable.count > 1 ? "Install \(mod.name) + \($0.downloadable.count - 1) required" : "Install \(mod.name)" } ?? "Install",
                              systemImage: "arrow.down.circle")
                    }
                    .disabled(plan == nil || chosenBlocked || result?.ok == true)
                }
            }
        }
        .navigationTitle(mod.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(result?.ok == true ? "Done" : "Cancel") { dismiss() } } }
        .task {
            guard !started else { return }
            started = true
            await loadFiles()
        }
        .onChange(of: chosenID) { _ in Task { await makePlan() } }
    }

    private func loadFiles() async {
        loading = true
        defer { loading = false }
        do {
            files = try await api.files(modID: mod.id, kind: kind, gameVersion: version.base, gameLoader: gameLoader)
        } catch {
            result = ((error as? CurseForgeError)?.description ?? "Couldn't load the files from CurseForge.", false)
            model.log.error("content", "CurseForge files for \(mod.id) failed: \(error)")
        }
        chosenID = CurseForgeAPI.preferred(files)?.id ?? 0
        if chosenID == 0 { plan = nil }
    }

    private func makePlan() async {
        guard let chosen else { plan = nil; return }
        plan = nil
        plan = try? await installer.plan(chosen, of: mod, gameVersion: version.base, gameLoader: gameLoader,
                                         installed: installed.subtracting([mod.id]))
    }

    private func install() async {
        guard let plan, let dir = model.gameDirectory(for: version.id) else { return }
        installing = true
        result = nil
        defer { installing = false }
        let manager = ContentManager(gameDirectory: dir)
        do {
            let report = try await installer.install(plan, kind: kind, into: manager) { p in
                Task { @MainActor in progress = (p.completed, p.total) }
            }
            let names = plan.downloadable.map(\.mod.name)
            if report.succeeded {
                let skipped = plan.blocked.isEmpty ? "" : " \(plan.blocked.count) more only on CurseForge's website."
                result = ("Installed \(names.joined(separator: ", ")).\(skipped)", true)
                model.log.info("content", "CurseForge: installed \(plan.downloadable.map { "\($0.mod.name) \($0.file.displayName)" }.joined(separator: ", ")) into \(version.id)")
                onInstalled()
            } else {
                result = ("\(report.failures.count) download\(report.failures.count == 1 ? "" : "s") failed. Nothing was replaced.", false)
                for (item, err) in report.failures { model.log.error("content", "CurseForge download \(item.url.lastPathComponent): \(err)") }
            }
        } catch {
            result = (String(describing: error), false)
        }
    }
}
