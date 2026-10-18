import SwiftUI
import UniformTypeIdentifiers
import VoxeliumCore

/// Mods, resource packs and shader packs of one installed version (its own game
/// folder for modded versions, the shared one for vanilla): add from Files, switch
/// on/off, remove.
struct ContentLibraryView: View {
    @EnvironmentObject var model: LauncherModel
    @Environment(\.dismiss) private var dismiss
    let version: InstalledVersion

    @State private var kind: ContentKind = .mods
    @State private var items: [ContentItem] = []
    @State private var importing = false
    @State private var message: (text: String, isError: Bool)?
    @State private var pendingDelete: ContentItem?

    private var kinds: [ContentKind] { version.isModded ? ContentKind.allCases : [.resourcePacks] }
    private var manager: ContentManager? { model.gameDirectory(for: version.id).map(ContentManager.init(gameDirectory:)) }
    private var loaderID: String? { version.loader.map { $0.lowercased() } }

    var body: some View {
        NavigationStack {
            List {
                if kinds.count > 1 {
                    Picker("Show", selection: $kind) {
                        ForEach(kinds) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                }
                if let message {
                    Text(message.text).font(.callout).foregroundStyle(message.isError ? Color.red : Color.green)
                }
                Section {
                    if items.isEmpty {
                        Text("No \(kind.title.lowercased()) yet. Tap Add to import .\(kind.fileExtension) files from Files.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(items) { item in row(item) }
                        .onDelete { offsets in pendingDelete = offsets.first.map { items[$0] } }
                } header: {
                    Text("\(kind.title) (\(items.filter(\.isEnabled).count) of \(items.count) on)")
                } footer: {
                    Text(footer)
                }
            }
            .navigationTitle(version.isModded ? "\(version.loader ?? "Modded") \(version.base)" : version.id)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { importing = true } label: { Label("Add", systemImage: "plus") }
                }
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
                if !kinds.contains(kind) { kind = kinds[0] }
                reload()
            }
            .onChange(of: kind) { _ in
                message = nil
                reload()
            }
        }
    }

    @ViewBuilder private func row(_ item: ContentItem) -> some View {
        Toggle(isOn: Binding(get: { item.isEnabled }, set: { setEnabled(item, $0) })) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.body.weight(.medium)).foregroundStyle(item.isEnabled ? Color.primary : Color.secondary)
                Text([item.version, ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file), item.isFolder ? "folder" : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                if let d = item.description, !d.isEmpty {
                    Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2)
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
            "Changes apply the next time you start this version. Quilt also loads Fabric mods. Mods that bundle desktop-only native code won't work on iPhone."
        case .resourcePacks:
            "Turn packs on in Minecraft's Options → Resource Packs. Switching one off here hides it from the game."
        case .shaderPacks:
            "Shader packs need the Iris mod (Fabric or Quilt). Many may not render yet on iPhone's OpenGL ES 3.0."
        }
    }

    private func reload() {
        items = manager?.list(kind) ?? []
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
                    let item = try manager.add(url, as: kind)
                    added.append(item.name)
                    model.log.info("content", "Added \(kind.folderName)/\(item.fileName) to \(version.id)")
                } catch {
                    failed.append(String(describing: error))
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
