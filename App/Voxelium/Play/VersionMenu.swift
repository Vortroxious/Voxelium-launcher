import SwiftUI
import VoxeliumCore

/// What else a version offers besides Play: its content, worlds, the launch plan, delete.
struct VersionMenu<Label: View>: View {
    @EnvironmentObject var model: LauncherModel
    @EnvironmentObject var minecraft: MinecraftLauncher
    let version: InstalledVersion
    @ViewBuilder var label: () -> Label
    @State private var showContent = false
    @State private var showWorlds = false
    @State private var confirmDelete = false
    @State private var deleteError: String?

    var body: some View {
        Menu {
            Button { showContent = true } label: {
                SwiftUI.Label(version.isModded ? "Mods & packs" : "Resource packs", systemImage: "square.stack.3d.up")
            }
            Button { showWorlds = true } label: { SwiftUI.Label("Worlds", systemImage: "globe.americas") }
            Button { model.preparePlan(version.id) } label: { SwiftUI.Label("Prepare launch plan", systemImage: "list.bullet.rectangle") }
            Divider()
            Button(role: .destructive) {
                let blockers = model.versionsBuilding(on: version.id)
                if blockers.isEmpty { confirmDelete = true }
                else { deleteError = VersionDeleteError.neededBy(version.id, blockers).description }
            } label: { SwiftUI.Label("Delete version…", systemImage: "trash") }
            .disabled(minecraft.gameActive)
        } label: { label() }
        .confirmationDialog("Delete \(version.title)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { deleteError = await model.deleteVersion(version.id) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
        .alert("Not deleted", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
        }
        .sheet(isPresented: $showContent) { ContentLibraryView(version: version) }
        .sheet(isPresented: $showWorlds) { WorldsView(version: version) }
    }

    private var deleteMessage: String {
        guard version.isModded else {
            return "Removes Minecraft \(version.id). Worlds, resource packs and settings of vanilla versions are shared and stay."
        }
        let worlds = model.paths.map { VersionDeleter(paths: $0).worldCount(of: version.id) } ?? 0
        let worldText = worlds == 0 ? "its worlds" : "its \(worlds) world\(worlds == 1 ? "" : "s")"
        return "This also deletes \(worldText), mods, shader packs and settings in its game folder. To keep a world, share it from Worlds first. This can't be undone."
    }
}
