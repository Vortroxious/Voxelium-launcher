import SwiftUI
import UniformTypeIdentifiers
import VoxeliumCore

/// Modrinth modpacks that run on Fabric or Quilt, plus "Import .mrpack" from Files.
/// A pack installs as its own version with its own game folder.
struct ModpackBrowseView: View {
    @EnvironmentObject var model: LauncherModel
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var sort: ModrinthAPI.Sort = .relevance
    @State private var hits: [ModrinthAPI.SearchHit] = []
    @State private var total = 0
    @State private var loading = false
    @State private var error: String?
    @State private var selected: ModrinthAPI.SearchHit?
    @State private var importing = false
    @State private var importedFile: ImportedPack?

    private var api: ModrinthAPI { ModrinthAPI() }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Sort", selection: $sort) {
                        ForEach(ModrinthAPI.Sort.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                } footer: {
                    Text("Modpacks bring many mods at once. iPhones have limited memory: smaller packs and render distance 8–10 work best.")
                }
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red)
                        Button("Try again") { Task { await search(reset: true) } }
                    }
                }
                Section {
                    ForEach(hits) { hit in
                        Button { selected = hit } label: { HitRow(hit: hit, installed: false) }
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
                    Text(total > 0 ? "\(total) Fabric and Quilt modpacks on Modrinth" : "Modrinth modpacks")
                }
            }
            .navigationTitle("Modpacks")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search modpacks")
            .onSubmit(of: .search) { Task { await search(reset: true) } }
            .onChange(of: sort) { _ in Task { await search(reset: true) } }
            .task { await search(reset: true) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { importing = true } label: { Label("Import .mrpack", systemImage: "square.and.arrow.down") }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "mrpack") ?? .zip, .zip]) { result in
                importFile(result)
            }
            .sheet(item: $selected) { hit in
                NavigationStack { ModpackDetailView(hit: hit) }
            }
            .sheet(item: $importedFile) { file in
                NavigationStack { ModpackImportView(file: file.url) }
            }
        }
    }

    private func search(reset: Bool) async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let page = try await api.searchModpacks(query, sort: sort, offset: reset ? 0 : hits.count)
            hits = reset ? page.hits : hits + page.hits
            total = page.totalHits
        } catch {
            self.error = model.isOffline || LauncherModel.looksOffline(error)
                ? "No internet connection. Please turn on your internet and try again."
                : "Couldn't reach Modrinth. Please try again in a moment."
            model.log.error("modpack", "Modrinth modpack search failed: \(error)")
        }
    }

    /// Copies the picked file out of its security scope before installing.
    private func importFile(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("modpacks", isDirectory: true)
            .appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: url, to: copy)
            importedFile = ImportedPack(url: copy)
        } catch {
            self.error = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}

struct ImportedPack: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// The install button, progress and result, shared by Modrinth and imported packs.
private struct ModpackInstallSection: View {
    @EnvironmentObject var model: LauncherModel
    let title: String
    let canInstall: Bool
    let install: () async -> Void

    var body: some View {
        Section {
            switch model.modpackState {
            case .working(let stage, let done, let total):
                VStack(alignment: .leading, spacing: 6) {
                    Text(stage).font(.callout)
                    if total > 1 {
                        ProgressView(value: Double(done), total: Double(total)) {
                            Text("\(done) of \(total)").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        ProgressView()
                    }
                }
            case .finished(let id, let mods):
                Label("Installed as \(id). Find it under Installed on the Versions page.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if mods > ModpackIndex.largeModCount {
                    Label("It has \(mods) mods. Packs this large are unlikely to fit in an iPhone's memory and may close while loading.",
                          systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                installButton
            case .idle:
                installButton
            }
        }
    }

    private var installButton: some View {
        Button { Task { await install() } } label: { Label("Install \(title)", systemImage: "arrow.down.circle") }
            .disabled(!canInstall)
    }
}

/// One Modrinth modpack: pick a version (Fabric or Quilt), install it.
struct ModpackDetailView: View {
    @EnvironmentObject var model: LauncherModel
    @Environment(\.dismiss) private var dismiss
    let hit: ModrinthAPI.SearchHit

    @State private var versions: [ModrinthAPI.Version] = []
    @State private var chosenID = ""
    @State private var loading = true
    @State private var error: String?
    /// The version picker opens as its own page, and coming back re-runs onAppear and
    /// .task: without this the list reloaded and the newest version was chosen again.
    @State private var started = false

    private var chosen: ModrinthAPI.Version? { versions.first { $0.id == chosenID } }

    var body: some View {
        Form {
            Section {
                Text(hit.description).font(.callout)
            }
            Section("Version") {
                if loading && versions.isEmpty {
                    ForEach(0..<2, id: \.self) { VersionRowSkeleton(index: $0) }
                } else if let error {
                    Text(error).foregroundStyle(.red)
                } else if versions.isEmpty {
                    Text("No Fabric or Quilt version of this modpack.").foregroundStyle(.secondary)
                } else {
                    Picker("Version", selection: $chosenID) {
                        ForEach(versions.prefix(40)) { v in
                            Text("\(v.versionNumber) · \(v.gameVersions.joined(separator: ", "))").tag(v.id)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    if let chosen {
                        LabeledContent("Minecraft", value: chosen.gameVersions.joined(separator: ", "))
                        LabeledContent("Loader", value: chosen.loaders.map(\.capitalized).joined(separator: ", "))
                        if let file = chosen.primaryFile {
                            LabeledContent("Download", value: ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file) + " + mods")
                        }
                    }
                }
            }
            ModpackInstallSection(title: hit.title, canInstall: chosen != nil) {
                if let chosen { await model.installModpack(chosen) }
            }
        }
        .navigationTitle(hit.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(isFinished ? "Done" : "Close") { dismiss() }.disabled(isWorking)
            }
        }
        .interactiveDismissDisabled(isWorking)
        .task {
            guard !started else { return }
            started = true
            model.resetModpackState()
            await loadVersions()
        }
    }

    private var isWorking: Bool { if case .working = model.modpackState { return true } else { return false } }
    private var isFinished: Bool { if case .finished = model.modpackState { return true } else { return false } }

    private func loadVersions() async {
        loading = true
        defer { loading = false }
        do {
            versions = try await ModrinthAPI().modpackVersions(project: hit.projectId)
            chosenID = ModrinthAPI.preferred(versions)?.id ?? ""
        } catch {
            self.error = model.isOffline || LauncherModel.looksOffline(error)
                ? "No internet connection. Please turn on your internet and try again."
                : "Couldn't load this modpack's versions. Please try again in a moment."
            model.log.error("modpack", "Versions of \(hit.slug) failed: \(error)")
        }
    }
}

/// A .mrpack picked in the Files app: show what it is, then install it.
struct ModpackImportView: View {
    @EnvironmentObject var model: LauncherModel
    @Environment(\.dismiss) private var dismiss
    let file: URL

    @State private var index: ModpackIndex?
    @State private var problem: String?

    var body: some View {
        Form {
            if let index {
                Section {
                    LabeledContent("Modpack", value: index.name)
                    LabeledContent("Version", value: index.versionId)
                    LabeledContent("Minecraft", value: index.minecraft ?? "?")
                    LabeledContent("Loader", value: index.loader.map { "\($0.loader.displayName) \($0.version)" } ?? "None")
                    LabeledContent("Mods", value: "\(index.clientModCount)")
                    if index.clientModCount > ModpackIndex.largeModCount {
                        Label("This pack has \(index.clientModCount) mods. Packs this large are unlikely to fit in an iPhone's memory and may close while loading.",
                              systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                    if let summary = index.summary, !summary.isEmpty { Text(summary).font(.callout) }
                }
                ModpackInstallSection(title: index.name, canInstall: true) { await model.installModpackFile(file) }
            } else if let problem {
                Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }
        }
        .navigationTitle(file.deletingPathExtension().lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }.disabled(isWorking)
            }
        }
        .interactiveDismissDisabled(isWorking)
        .onAppear {
            model.resetModpackState()
            do { index = try ModpackInstaller.read(file).index } catch {
                problem = (error as? ModpackError)?.description ?? "This file could not be read as a modpack."
            }
        }
    }

    private var isWorking: Bool { if case .working = model.modpackState { return true } else { return false } }
}
