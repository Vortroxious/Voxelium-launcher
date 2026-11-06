import SwiftUI
import UniformTypeIdentifiers
import VoxeliumCore

/// One kind of content (mods, resource packs or shader packs) of one installed version, a
/// tab of the version page (its own game folder for modded versions, the shared one for
/// vanilla): browse or import, switch on/off, update, remove.
struct ContentPane: View {
    @EnvironmentObject var model: LauncherModel
    let version: InstalledVersion
    let kind: ContentKind

    @State private var items: [ContentItem] = []
    @State private var importing = false
    @State private var message: (text: String, isError: Bool)?
    @State private var pendingDelete: ContentItem?
    @State private var browsing = false
    @State private var browsingCurseForge = false
    @State private var iris: IrisSettings?
    /// Newer Modrinth versions of installed files, by file path.
    @State private var updates: [String: ModUpdate] = [:]
    @State private var checkingUpdates = false
    @State private var updating: Set<String> = []

    private var manager: ContentManager? { model.gameDirectory(for: version.id).map(ContentManager.init(gameDirectory:)) }
    private var loaderID: String? { version.loader.map { $0.lowercased() } }

    var body: some View {
        List {
            Section {
                HStack(spacing: 8) {
                    addButton("Modrinth", "globe") { browsing = true }
                    addButton("CurseForge", "flame") { browsingCurseForge = true }
                    addButton("Import file", "folder") { importing = true }
                }
                .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            }
            if let message {
                Text(message.text).font(.callout).foregroundStyle(message.isError ? VX.error : VX.primary).vxRow()
            }
            if kind == .shaderPacks, let iris, iris.exists {
                Section {
                    Toggle(isOn: Binding(get: { iris.shadersEnabled }, set: { setShaders($0) })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Shaders in game").font(.vxHeadline)
                            Text(iris.shaderPack.map { "Iris pack: \($0)" } ?? "No pack chosen in Iris yet")
                                .font(.caption).foregroundStyle(VX.onSurfaceVariant)
                        }
                    }
                    .vxRow()
                } footer: {
                    Text("If a shader pack leaves the screen black, switch this off and start again. Choose packs in Minecraft's Options → Video Settings → Shader Packs.")
                }
            }
            if !updates.isEmpty || checkingUpdates {
                Section {
                    if checkingUpdates && updates.isEmpty {
                        HStack(spacing: 8) { ProgressView(); Text("Checking Modrinth for updates…").font(.callout) }.vxRow()
                    } else {
                        HStack {
                            Label("\(updates.count) update\(updates.count == 1 ? "" : "s") available", systemImage: "arrow.down.circle")
                            Spacer()
                            if updates.count > 1 {
                                Button("Update all") { Task { await installUpdates(Array(updates.values)) } }
                                    .font(.footnote.weight(.bold)).disabled(!updating.isEmpty)
                            }
                        }
                        .vxRow()
                    }
                }
            }
            Section {
                if items.isEmpty {
                    Text("No \(kind.title.lowercased()) yet. Browse Modrinth or CurseForge, or import .\(kind.fileExtension) files from Files.")
                        .foregroundStyle(VX.onSurfaceVariant).vxRow()
                }
                ForEach(items) { item in row(item).vxRow() }
                    .onDelete { offsets in pendingDelete = offsets.first.map { items[$0] } }
            } header: {
                Text("\(kind.title) · \(items.filter(\.isEnabled).count) of \(items.count) on")
            } footer: {
                Text(footer + (items.isEmpty ? "" : " Swipe left to remove one."))
            }
        }
        .vxList()
        .navigationDestination(isPresented: $browsing) {
            ModrinthBrowseView(version: version, kind: kind) { reload() }
        }
        .navigationDestination(isPresented: $browsingCurseForge) {
            CurseForgeBrowseView(version: version, kind: kind) { reload() }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: allowedTypes, allowsMultipleSelection: true) { result in
            importFiles(result)
        }
        .confirmationDialog(pendingDelete.map { "Remove \($0.name)?" } ?? "", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) { if let item = pendingDelete { remove(item) } }
        } message: {
            Text("The file is deleted from this version's \(kind.folderName) folder.")
        }
        .onAppear {
            reload()
            Task { await checkUpdates() }
        }
    }

    private func addButton(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.body.weight(.semibold)).foregroundStyle(VX.primary)
                Text(title).font(.caption.weight(.bold)).foregroundStyle(VX.onSurface)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(VX.surfaceHigh, in: RoundedRectangle(cornerRadius: VX.Radius.small + 2))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func row(_ item: ContentItem) -> some View {
        Toggle(isOn: Binding(get: { item.isEnabled }, set: { setEnabled(item, $0) })) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.body.weight(.medium)).foregroundStyle(item.isEnabled ? VX.onSurface : VX.onSurfaceVariant)
                Text([item.version, ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file), item.isFolder ? "folder" : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                if let d = item.description, !d.isEmpty {
                    Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if let update = updates[item.url.path] {
                    if updating.contains(update.projectID) {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Updating…").font(.caption) }
                    } else {
                        Button {
                            Task { await installUpdates([update]) }
                        } label: {
                            Label("Update to \(update.latest.versionNumber)", systemImage: "arrow.down.circle.fill").font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .disabled(!updating.isEmpty)
                    }
                }
                if let w = ContentManager.compatibilityWarning(item, loader: loaderID) {
                    Label(w, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                if let p = item.problem {
                    Label(p, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    private var allowedTypes: [UTType] {
        kind == .mods ? [UTType(filenameExtension: "jar") ?? .data, .zip] : [.zip]
    }

    private var footer: String {
        switch kind {
        case .mods:
            "Changes apply the next time you start this version. Only mods for this version's loader can be added (Quilt also loads Fabric mods). Mods that bundle desktop-only native code won't work on iPhone."
        case .resourcePacks:
            "Turn packs on in Minecraft's Options → Resource Packs. Switching one off here hides it from the game."
        case .shaderPacks:
            "Shader packs need the Iris mod (Fabric, Quilt, NeoForge) or Oculus (Forge). Packs that use compute shaders (such as Photon) cannot run on the iPhone's OpenGL ES 3.0. With shaders, keep the render distance at 8–10: more runs out of memory."
        }
    }

    /// Asks Modrinth which installed files have newer versions (quietly: no message when
    /// offline or when nothing came from Modrinth).
    private func checkUpdates() async {
        guard let manager, !model.isOffline, !checkingUpdates else { return }
        let checkedKind = kind
        checkingUpdates = true
        defer { checkingUpdates = false }
        do {
            let found = try await ModrinthInstaller().checkUpdates(manager, kind: checkedKind, gameVersion: version.base, gameLoader: loaderID)
            guard checkedKind == kind else { return }
            updates = Dictionary(found.map { ($0.file.path, $0) }, uniquingKeysWith: { a, _ in a })
            if !found.isEmpty { model.log.info("content", "Updates for \(version.id): \(found.map { "\($0.name) \($0.current.versionNumber) → \($0.latest.versionNumber)" }.joined(separator: ", "))") }
        } catch {
            model.log.warning("content", "Update check for \(version.id) failed: \(error)")
        }
    }

    /// Installs the newer versions (with any new required mods), replacing the old files
    /// once every download is verified.
    private func installUpdates(_ list: [ModUpdate]) async {
        guard let manager, !list.isEmpty else { return }
        let installer = ModrinthInstaller()
        updating = Set(list.map(\.projectID))
        defer { updating = [] }
        let installedMods = Set(((try? await installer.installedProjects(manager, kind: .mods)) ?? [:]).keys)
        var done: [String] = [], failed: [String] = []
        for update in list {
            do {
                let plan = try await installer.plan(update.latest, title: update.name, kind: kind, gameVersion: version.base,
                                                    gameLoader: loaderID, installed: installedMods.subtracting([update.projectID]),
                                                    installedModIDs: manager.installedModIDs())
                let report = try await installer.install(plan, kind: kind, into: manager, replacing: [update.projectID: [update.file]])
                if report.succeeded {
                    done.append(update.name)
                    model.log.info("content", "Updated \(update.name) \(update.current.versionNumber) → \(update.latest.versionNumber) in \(version.id)")
                } else {
                    failed.append(update.name)
                    for (item, err) in report.failures { model.log.error("content", "Update download \(item.url.lastPathComponent): \(err)") }
                }
            } catch {
                failed.append(update.name)
                model.log.error("content", "Update of \(update.name) failed: \(error)")
            }
        }
        if failed.isEmpty {
            message = ("Updated \(done.joined(separator: ", ")). Changes apply the next time you start this version.", false)
        } else {
            message = ((done.isEmpty ? "" : "Updated \(done.joined(separator: ", ")). ") + "Could not update \(failed.joined(separator: ", ")); the old version was kept.", true)
        }
        reload()
        updates = [:]
        await checkUpdates()
    }

    private func reload() {
        items = manager?.list(kind) ?? []
        iris = model.gameDirectory(for: version.id).map(IrisSettings.init(gameDirectory:))
    }

    private func setShaders(_ on: Bool) {
        guard var settings = iris else { return }
        do {
            try settings.setShadersEnabled(on)
            message = ("Shaders \(on ? "on" : "off") from the next start.", false)
            model.log.info("content", "Iris shaders \(on ? "on" : "off") for \(version.id) (pack: \(settings.shaderPack ?? "none"))")
        } catch {
            message = ("Could not change Iris settings: \(error.localizedDescription)", true)
        }
        reload()
    }

    private func setEnabled(_ item: ContentItem, _ on: Bool) {
        do {
            try manager?.setEnabled(item, on)
            message = nil
        } catch {
            message = ("Could not \(on ? "enable" : "disable") \(item.name): \(error.localizedDescription)", true)
        }
        reload()
    }

    private func remove(_ item: ContentItem) {
        do {
            try manager?.remove(item)
            message = ("Removed \(item.name).", false)
            model.log.info("content", "Removed \(kind.folderName)/\(item.fileName) from \(version.id)")
        } catch {
            message = ("Could not remove \(item.name): \(error.localizedDescription)", true)
        }
        pendingDelete = nil
        reload()
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        guard let manager else { return }
        switch result {
        case .failure(let error):
            message = ("Import failed: \(error.localizedDescription)", true)
        case .success(let urls):
            var added: [String] = [], failed: [String] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let item = try manager.add(url, as: kind, loader: loaderID)
                    added.append(item.name)
                    model.log.info("content", "Added \(kind.folderName)/\(item.fileName) to \(version.id)")
                } catch {
                    failed.append(String(describing: error))
                    model.log.info("content", "Did not add \(url.lastPathComponent) to \(version.id): \(error)")
                }
            }
            if !failed.isEmpty {
                message = ((added.isEmpty ? "" : "Added \(added.joined(separator: ", ")). ") + failed.joined(separator: " "), true)
            } else {
                message = ("Added \(added.joined(separator: ", ")).", false)
            }
            reload()
        }
    }
}
