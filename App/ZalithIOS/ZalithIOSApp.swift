import SwiftUI
import ZalithCore

@main
struct ZalithIOSApp: App {
    @StateObject private var model = LauncherModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
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
            DiagnosticsView()
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
            LogView()
                .tabItem { Label("Logs", systemImage: "doc.plaintext") }
        }
    }
}
