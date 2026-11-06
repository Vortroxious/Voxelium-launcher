import SwiftUI
import VoxeliumCore

@main
struct VoxeliumApp: App {
    @UIApplicationDelegateAdaptor(VoxeliumAppDelegate.self) private var appDelegate
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

/// The five places of the tab bar.
enum AppTab: Hashable { case play, install, accounts, controls, settings }

struct ContentView: View {
    @EnvironmentObject var minecraft: MinecraftLauncher
    @State private var tab: AppTab = .play

    var body: some View {
        TabView(selection: $tab) {
            PlayView(tab: $tab)
                .tabItem { Label("Play", systemImage: "play.fill") }.tag(AppTab.play)
            InstallView()
                .tabItem { Label("Install", systemImage: "arrow.down.circle") }.tag(AppTab.install)
            AccountView()
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }.tag(AppTab.accounts)
            ControlsView()
                .tabItem { Label("Controls", systemImage: "gamecontroller") }.tag(AppTab.controls)
            InterimSettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }.tag(AppTab.settings)
        }
        .tint(VX.primary)
        // Back to portrait once the game's landscape window is gone.
        .onChange(of: minecraft.gameActive) { active in
            if !active { OrientationLock.restorePortrait() }
        }
    }
}

/// Settings until its own pages arrive: JIT and Diagnostics, as before.
struct InterimSettingsView: View {
    @State private var showJIT = false
    @State private var showDiagnostics = false

    var body: some View {
        NavigationStack {
            List {
                Button { showJIT = true } label: { Label("JIT", systemImage: "bolt") }
                Button { showDiagnostics = true } label: { Label("Diagnostics", systemImage: "stethoscope") }
            }
            .navigationTitle("Settings")
        }
        .sheet(isPresented: $showJIT) { BuiltInJITView(showsDone: true) }
        .sheet(isPresented: $showDiagnostics) { DiagnosticsView() }
    }
}
