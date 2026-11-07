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
    @StateObject private var appearance = AppearanceModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(minecraft)
                .environmentObject(controls)
                .environmentObject(accounts)
                .environmentObject(updates)
                .environmentObject(appearance)
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
    @EnvironmentObject var appearance: AppearanceModel
    @State private var tab: AppTab = .play
    /// Minecraft reached `.running` in this launch, so a failure after it is the game's own.
    @State private var gameWasRunning = false
    @State private var gameEnded: GameEnded?

    struct GameEnded: Identifiable { let id = UUID(); let message: String }

    var body: some View {
        TabView(selection: $tab) {
            PlayView(tab: $tab)
                .tabItem { Label("Play", systemImage: "play.fill") }.tag(AppTab.play)
            InstallView()
                .tabItem { Label("Install", systemImage: "arrow.down.circle") }.tag(AppTab.install)
            AccountsView()
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }.tag(AppTab.accounts)
            ControlsView()
                .tabItem { Label("Controls", systemImage: "gamecontroller") }.tag(AppTab.controls)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }.tag(AppTab.settings)
        }
        .tint(VX.primary)
        // A new accent colour redraws every tab (the selected tab stays).
        .id(appearance.accent.id)
        .sheet(isPresented: $appearance.showPicker) { AppearanceSheet() }
        .onAppear { appearance.applyToWindows() }
        // Back to portrait once the game's landscape window is gone.
        .onChange(of: minecraft.gameActive) { active in
            if !active { OrientationLock.restorePortrait() }
        }
        // A game that ran and then ended with an error gets the game-ended sheet; problems
        // before it starts are shown on Play.
        .onChange(of: minecraft.state) { state in
            switch state {
            case .running: gameWasRunning = true
            case .finished(let ok, let message):
                if gameWasRunning && !ok { gameEnded = GameEnded(message: message) }
                gameWasRunning = false
            default: break
            }
        }
        .sheet(item: $gameEnded) { GameEndedSheet(message: $0.message) }
    }
}
