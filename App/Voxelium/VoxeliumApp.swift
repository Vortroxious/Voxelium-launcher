import SwiftUI
import VoxeliumCore

@main
struct VoxeliumApp: App {
    @StateObject private var model = LauncherModel()
    @StateObject private var minecraft = MinecraftLauncher()
    @StateObject private var controls = ControlsModel()
    @StateObject private var accounts = AccountModel()
    @StateObject private var updates = UpdateModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(minecraft)
                .environmentObject(controls)
                .environmentObject(accounts)
                .environmentObject(updates)
                .task {
                    _ = NetworkRouteMonitor.shared  // knows the route by the time Play asks
                    await model.start()
                    await updates.checkIfDue(offline: model.isOffline)
                }
                // Keep the Microsoft token current while online, for Play in Airplane Mode.
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    Task { await accounts.refreshEarly() }
                }
                .onChange(of: model.isOffline) { offline in
                    if !offline {
                        Task { await accounts.refreshEarly() }
                        Task { await updates.checkIfDue(offline: false) }
                    }
                }
        }
    }
}

struct ContentView: View {
    var body: some View {
        TabView {
            VersionsView()
                .tabItem { Label("Versions", systemImage: "square.stack.3d.up") }
            AccountView()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
            ControlsView()
                .tabItem { Label("Controls", systemImage: "gamecontroller") }
            DiagnosticsView()
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
            BuiltInJITView()
                .tabItem { Label("JIT", systemImage: "bolt") }
        }
    }
}
