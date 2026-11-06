import SwiftUI
import VoxeliumCore

/// README section on installing Voxelium and LocalDevVPN and making the pairing file.
let setupGuideURL = URL(string: "https://github.com/Vortroxious/Voxelium-launcher#installing-on-your-iphone")!

/// Starts Minecraft for an installed version (vanilla or modded).
@MainActor
func launchVersion(_ id: String, model: LauncherModel, minecraft: MinecraftLauncher, accounts: AccountModel,
                   renderer: GameRenderer? = nil) {
    guard let paths = model.paths else { return }
    model.settings.selectedVersion = id  // the Play page's "Last played"
    let renderer = renderer ?? RendererMemory.last(for: id) ?? .mobileGlues
    Task { await minecraft.launch(versionID: id, paths: paths, settings: model.settings, accounts: accounts, renderer: renderer) }
}

/// The renderer last chosen for each version (experimental Play menu).
enum RendererMemory {
    private static func key(_ id: String) -> String { "VoxeliumRenderer." + id }
    static func last(for id: String) -> GameRenderer? {
        UserDefaults.standard.string(forKey: key(id)).flatMap(GameRenderer.init(rawValue:))
    }
    static func remember(_ renderer: GameRenderer, for id: String) {
        UserDefaults.standard.set(renderer.rawValue, forKey: key(id))
    }
}

struct AccountView: View {
    @EnvironmentObject var model: LauncherModel
    @EnvironmentObject var accounts: AccountModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Form {
                microsoftSection
                if accounts.account != nil {
                    Section {
                        Picker("Play as", selection: $model.settings.useMicrosoftAccount) {
                            Text(accounts.account?.username ?? "Microsoft account").tag(true)
                            Text("Offline: \(model.settings.playerName)").tag(false)
                        }
                    }
                }
                Section {
                    TextField("Player name", text: $model.settings.playerName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !OfflineIdentity.isValidName(model.settings.playerName) {
                        Text("3–16 characters: letters, digits, underscore").font(.caption).foregroundStyle(.red)
                    }
                } header: {
                    Text("Offline profile")
                } footer: {
                    Text("Offline profiles cannot join online-mode servers or Realms.")
                }
                Section {
                    Stepper("Max memory: \(model.settings.maxMemoryMB) MB", value: $model.settings.maxMemoryMB, in: 512...8192, step: 256)
                    VStack(alignment: .leading) {
                        Text("Resolution: \(Int((model.settings.renderScale * 100).rounded()))% (\(Self.renderPixels(model.settings.renderScale)))")
                        Slider(value: $model.settings.renderScale, in: LauncherSettings.renderScaleRange, step: 0.05)
                    }
                    Toggle("Large interface (bigger hotbar)", isOn: $model.settings.largeInterface)
                    if model.settings.largeInterface {
                        let used = Self.effectiveRenderScale(model.settings)
                        LabeledContent("Resolution used", value: "\(Int((used * 100).rounded()))% (\(Self.renderPixels(used)))")
                    }
                } header: {
                    Text("Game")
                } footer: {
                    Text("Lower resolution runs faster and uses less battery. Large interface moves the resolution to the nearest step where Minecraft can show its biggest hotbar and menus, and sets Minecraft's GUI Scale to Auto. Memory is capped at 40% of what iOS allows the app. All apply the next time you launch Minecraft.")
                }
                if let plan = model.lastPlan {
                    Section("Last launch plan (not executed)") {
                        LabeledContent("Main class", value: plan.mainClass)
                        LabeledContent("Java", value: plan.requiredJavaMajor.map(String.init) ?? "?")
                        LabeledContent("Classpath entries", value: "\(plan.classpath.count)")
                        LabeledContent("Missing files", value: "\(plan.missingFiles.count)")
                    }
                }
            }
            .navigationTitle("Account & Game")
        }
    }

    @ViewBuilder var microsoftSection: some View {
        Section {
            if let acc = accounts.account {
                LabeledContent("Signed in as", value: acc.username)
                Button("Sign out", role: .destructive) { accounts.signOut() }
            } else {
                switch accounts.signIn {
                case .idle:
                    Button { accounts.startSignIn() } label: { Label("Sign in with Microsoft", systemImage: "person.badge.key") }
                case .working(let m):
                    HStack { ProgressView(); Text(m) }
                    Button("Cancel", role: .cancel) { accounts.cancelSignIn() }
                case .waitingForUser(let code):
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Enter this code at \(code.verificationURL.host ?? "microsoft.com/link"):").font(.callout)
                        Text(code.userCode).font(.system(.title, design: .monospaced).bold()).textSelection(.enabled)
                        HStack { ProgressView(); Text("Waiting for you to approve…").font(.caption).foregroundStyle(.secondary) }
                    }
                    Button {
                        UIPasteboard.general.string = code.userCode
                        openURL(code.verificationURL)
                    } label: { Label("Copy code and open the sign-in page", systemImage: "safari") }
                    Button("Cancel", role: .cancel) { accounts.cancelSignIn() }
                case .failed(let m):
                    Text(m).font(.callout).foregroundStyle(.red)
                    Button("Try again") { accounts.startSignIn() }
                }
            }
        } header: {
            Text("Microsoft account")
        } footer: {
            Text("Needed for online servers and Realms; the account must own Minecraft: Java Edition. Signs in on Microsoft's own page; tokens are kept in the iOS Keychain.")
        }
    }

    /// The landscape framebuffer the game will render at, e.g. "1398×645 px".
    static func renderPixels(_ scale: Double) -> String {
        let a = gameArea(), k = UIScreen.main.nativeScale * scale
        return "\(Int((a.width * k).rounded()))×\(Int((a.height * k).rounded())) px"
    }

    /// The landscape game area (the whole screen) in points.
    static func gameArea() -> (width: Double, height: Double) {
        let s = UIScreen.main.bounds.size
        return (Double(max(s.width, s.height)), Double(min(s.width, s.height)))
    }

    static func effectiveRenderScale(_ settings: LauncherSettings) -> Double {
        let a = gameArea()
        return LauncherSettings.effectiveRenderScale(requested: settings.renderScale, largeInterface: settings.largeInterface,
                                                     gameWidth: a.width, gameHeight: a.height,
                                                     nativeScale: Double(UIScreen.main.nativeScale))
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject var model: LauncherModel
    @EnvironmentObject var updates: UpdateModel
    @StateObject private var javaTest = JavaTestModel()
    @StateObject private var graphicsTest = GraphicsTestModel()

    var body: some View {
        NavigationStack {
            List {
                Section("Device") {
                    LabeledContent("System", value: DeviceInfo.systemDescription)
                    LabeledContent("Physical memory", value: ByteCountFormatter.string(fromByteCount: Int64(DeviceInfo.physicalMemory), countStyle: .memory))
                    if let avail = DeviceInfo.availableMemory {
                        LabeledContent("Available to app", value: ByteCountFormatter.string(fromByteCount: Int64(avail), countStyle: .memory))
                    }
                    LabeledContent("Debugger attached (JIT prerequisite)", value: DeviceInfo.isDebuggerAttached ? "Yes" : "No")
                }
                Section {
                    LabeledContent("Voxelium", value: UpdateModel.currentVersion)
                    Button { Task { await updates.check() } } label: { Label("Check for updates", systemImage: "arrow.triangle.2.circlepath") }
                        .disabled(updates.status == .checking)
                    switch updates.status {
                    case .idle: EmptyView()
                    case .checking: HStack(spacing: 8) { ProgressView(); Text("Checking GitHub…").font(.callout) }
                    case .upToDate: Text("Voxelium is up to date.").font(.callout)
                    case .available(let r):
                        Link(destination: r.htmlUrl) { Label("Voxelium \(r.version) is available", systemImage: "arrow.down.app") }
                    case .failed(let why): Text("Couldn't check: \(why)").font(.callout).foregroundStyle(.red)
                    }
                    Toggle("Check for updates automatically", isOn: $updates.automatic)
                } header: {
                    Text("Updates")
                } footer: {
                    Text("Voxelium asks GitHub once a day for the latest release. Nothing about you is sent, and nothing is downloaded or installed by itself.")
                }
                Section("JIT") {
                    LabeledContent("get-task-allow", value: ["Unknown", "Missing", "Yes"][Int(JITCoordinator.getTaskAllow) + 1])
                    LabeledContent("JIT script needed (TXM)", value: VXJITNeedsScript() ? "Yes" : "No")
                    LabeledContent("StikDebug installed", value: JITCoordinator.stikDebugInstalled ? "Yes" : "No")
                    Link(destination: setupGuideURL) { Label("Setup guide", systemImage: "book") }
                }
                Section {
                    NavigationLink { LogList() } label: { Label("Logs", systemImage: "doc.plaintext") }
                    NavigationLink { AboutView() } label: { Label("About Voxelium & licences", systemImage: "info.circle") }
                }
                JavaTestSection(test: javaTest, paths: model.paths)
                GraphicsTestSection(test: graphicsTest, paths: model.paths)
                Section("Downloaded Java runtimes") {
                    if model.runtimes.isEmpty {
                        Text("None downloaded. The test above uses the runtime bundled in the app.").foregroundStyle(.secondary)
                    }
                    ForEach(model.runtimes, id: \.home) { rt in
                        LabeledContent(rt.name, value: "Java \(rt.javaVersion)")
                    }
                }
                Section("Status") {
                    Text("This build downloads and verifies game files and starts Minecraft Java (Java 17 versions, offline profile) in the app. Starting the game needs JIT: Play turns it on with the built-in helper (JIT tab) or asks StikDebug, or open Voxelium from StikDebug.")
                        .font(.footnote)
                }
                if let root = model.paths?.root {
                    Section("Data directory") { Text(root.path).font(.caption.monospaced()).textSelection(.enabled) }
                }
            }
            .navigationTitle("Diagnostics")
        }
    }
}

/// The log, newest first; pushed from Diagnostics.
struct LogList: View {
    @EnvironmentObject var model: LauncherModel
    @State private var entries: [LogEntry] = []

    var body: some View {
        List(Array(entries.enumerated().reversed()), id: \.offset) { _, e in
            VStack(alignment: .leading) {
                Text("[\(e.level.description)] \(e.category)").font(.caption.bold()).foregroundStyle(color(e.level))
                Text(e.message).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
        .navigationTitle("Logs")
        .toolbar { Button("Refresh") { entries = model.log.snapshot } }
        .onAppear { entries = model.log.snapshot }
    }

    func color(_ l: LogLevel) -> Color {
        switch l {
        case .error: .red
        case .warning: .orange
        default: .secondary
        }
    }
}
