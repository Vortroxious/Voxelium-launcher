import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VoxeliumCore

/// The worlds of one installed version (its own game folder for modded versions, the
/// shared one for vanilla): import a world folder or .zip from Files, share one as a
/// .zip, delete.
struct WorldsView: View {
    @EnvironmentObject var model: LauncherModel
    @Environment(\.dismiss) private var dismiss
    let version: InstalledVersion

    @State private var worlds: [WorldItem] = []
    @State private var importing = false
    @State private var working: String?
    @State private var message: (text: String, isError: Bool)?
    @State private var pendingDelete: WorldItem?
    @State private var shared: SharedFile?

    private var manager: WorldManager? { model.gameDirectory(for: version.id).map(WorldManager.init(gameDirectory:)) }

    var body: some View {
        NavigationStack {
            List {
                if let working {
                    HStack(spacing: 8) { ProgressView(); Text(working).font(.callout) }
                }
                if let message {
                    Text(message.text).font(.callout).foregroundStyle(message.isError ? Color.red : Color.green)
                }
                Section {
                    if worlds.isEmpty {
                        Text("No worlds yet. Tap + to import a world folder or .zip from Files, or create one in Minecraft.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(worlds) { world in
                        row(world)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { pendingDelete = world } label: { Label("Delete", systemImage: "trash") }
                                Button { share(world) } label: { Label("Share", systemImage: "square.and.arrow.up") }.tint(.blue)
                            }
                            .contextMenu {
                                Button { share(world) } label: { Label("Share as .zip", systemImage: "square.and.arrow.up") }
                                Button(role: .destructive) { pendingDelete = world } label: { Label("Delete", systemImage: "trash") }
                            }
                    }
                } header: {
                    Text("Worlds (\(worlds.count))")
                } footer: {
                    Text("You can also drop world folders into Files → On My iPhone → Voxelium → \(savesPath). Copy worlds only while Minecraft is closed.")
                }
            }
            .navigationTitle("Worlds")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { importing = true } label: { Label("Import", systemImage: "plus") }
                        .disabled(working != nil)
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.folder, .zip], allowsMultipleSelection: true) { result in
                importWorlds(result)
            }
            .confirmationDialog(pendingDelete.map { "Delete \($0.name)?" } ?? "", isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
                Button("Delete world", role: .destructive) { if let world = pendingDelete { delete(world) } }
            } message: {
                Text("The world is deleted from this version's saves folder. Share it as a .zip first if you want a copy.")
            }
            .sheet(item: $shared) { file in ActivitySheet(url: file.url) }
            .onAppear { reload() }
        }
    }

    private func row(_ world: WorldItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(world.name).font(.body.weight(.medium))
            Text([world.lastPlayed.map { "Played \($0.formatted(date: .abbreviated, time: .shortened))" },
                  ByteCountFormatter.string(fromByteCount: world.size, countStyle: .file)]
                    .compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var savesPath: String {
        version.isModded ? "minecraft → versions → \(version.id) → saves" : "minecraft → saves"
    }

    private func reload() {
        worlds = manager?.list() ?? []
    }

    private func importWorlds(_ result: Result<[URL], Error>) {
        guard let manager else { return }
        switch result {
        case .failure(let error):
            message = ("Import failed: \(error.localizedDescription)", true)
        case .success(let urls):
            working = "Importing…"
            message = nil
            let log = model.log, versionID = version.id
            Task {
                let (added, failed) = await Task.detached(priority: .userInitiated) { () -> ([String], [String]) in
                    var added: [String] = [], failed: [String] = []
                    for url in urls {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        do {
                            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                            let world = isFolder ? try manager.importFolder(url) : try manager.importZip(url)
                            added.append(world.name)
                            log.info("worlds", "Imported \(url.lastPathComponent) as saves/\(world.name) into \(versionID)")
                        } catch {
                            failed.append(String(describing: error))
                            log.error("worlds", "Import of \(url.lastPathComponent) into \(versionID) failed: \(error)")
                        }
                    }
                    return (added, failed)
                }.value
                working = nil
                if !failed.isEmpty {
                    message = ((added.isEmpty ? "" : "Imported \(added.joined(separator: ", ")). ") + failed.joined(separator: " "), true)
                } else {
                    message = ("Imported \(added.joined(separator: ", ")).", false)
                }
                reload()
            }
        }
    }

    private func delete(_ world: WorldItem) {
        do {
            try manager?.delete(world)
            message = ("Deleted \(world.name).", false)
            model.log.info("worlds", "Deleted saves/\(world.name) from \(version.id)")
        } catch {
            message = ("Could not delete \(world.name): \(error.localizedDescription)", true)
            model.log.error("worlds", "Delete of saves/\(world.name) from \(version.id) failed: \(error)")
        }
        pendingDelete = nil
        reload()
    }

    /// Zips the world folder (iOS does it when a folder is read "for uploading") into a
    /// temporary file and opens the share sheet.
    private func share(_ world: WorldItem) {
        working = "Zipping \(world.name)…"
        message = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try Self.zip(world) } }.value
            working = nil
            switch result {
            case .success(let url):
                model.log.info("worlds", "Shared saves/\(world.name) from \(version.id) as \(url.lastPathComponent)")
                shared = SharedFile(url: url)
            case .failure(let error):
                message = ("Could not zip \(world.name): \(error.localizedDescription)", true)
                model.log.error("worlds", "Zipping saves/\(world.name) from \(version.id) failed: \(error)")
            }
        }
    }

    private nonisolated static func zip(_ world: WorldItem) throws -> URL {
        let fm = FileManager.default
        let outDir = fm.temporaryDirectory.appendingPathComponent("SharedWorlds", isDirectory: true)
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        let dest = outDir.appendingPathComponent("\(world.name).zip")
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: world.url, options: .forUploading, error: &coordinationError) { zipURL in
            do {
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.copyItem(at: zipURL, to: dest)
            } catch {
                copyError = error
            }
        }
        if let error = coordinationError ?? copyError { throw error }
        return dest
    }
}

private struct SharedFile: Identifiable {
    let url: URL
    var id: String { url.path }
}

private struct ActivitySheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
