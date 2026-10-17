import SwiftUI
import ZalithCore

@main
struct ZalithIOSApp: App {
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
                .task { await model.start() }
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
            LogView()
                .tabItem { Label("Logs", systemImage: "doc.plaintext") }
        }
    }
}
