import SwiftUI
import VoxeliumCore

@main
struct VoxeliumApp: App {
    @StateObject private var model = LauncherModel()
    @StateObject private var minecraft = MinecraftLauncher()
    @StateObject private var controls = ControlsModel()
    @StateObject private var accounts = AccountModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(minecraft)
                .environmentObject(controls)
                .environmentObject(accounts)
                .task {
                    #if VOXELIUM_JIT_HELPER_SPIKE
                    _ = NetworkRouteMonitor.shared  // knows the route by the time Play asks
                    #endif
                    await model.start()
                }
                // Keep the Microsoft token current while online, for Play in Airplane Mode.
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    Task { await accounts.refreshEarly() }
                }
                .onChange(of: model.isOffline) { offline in
                    if !offline { Task { await accounts.refreshEarly() } }
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
            #if VOXELIUM_JIT_HELPER_SPIKE
            BuiltInJITView()
                .tabItem { Label("JIT", systemImage: "bolt") }
            #else
            LogView()
                .tabItem { Label("Logs", systemImage: "doc.plaintext") }
            #endif
        }
    }
}
