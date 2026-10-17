import SwiftUI
import ZalithCore

struct VersionsView: View {
    @EnvironmentObject var model: LauncherModel
    @EnvironmentObject var minecraft: MinecraftLauncher

    var body: some View {
        NavigationStack {
            List {
                switch minecraft.state {
                case .idle:
                    EmptyView()
                case .starting(let m), .running(let m):
                    Section { HStack { ProgressView(); Text(m).font(.callout) } }
                case .finished(let ok, let m):
                    Section {
                        Label(ok ? "Minecraft exited" : "Minecraft did not start", systemImage: ok ? "checkmark.circle" : "xmark.octagon")
                            .foregroundStyle(ok ? Color.primary : Color.red)
                        Text(m).font(.caption)
                    }
                }
                if let error = model.manifestError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                        Button("Retry") { Task { await model.loadManifest() } }
                    }
                }
                Section {
                    Toggle("Show snapshots", isOn: $model.settings.showSnapshots)
                }
                Section("Versions") {
                    ForEach(model.visibleVersions) { entry in
                        VersionRow(entry: entry)
                    }
                }
            }
            .overlay { if model.loadingManifest && model.manifest == nil { ProgressView("Loading versions…") } }
            .refreshable { await model.loadManifest() }
            .navigationTitle("Minecraft Versions")
        }
    }
}

struct VersionRow: View {
    @EnvironmentObject var model: LauncherModel
    @EnvironmentObject var minecraft: MinecraftLauncher
    @EnvironmentObject var accounts: AccountModel
    let entry: VersionManifest.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading) {
                    Text(entry.id).font(.headline)
                    Text(entry.releaseTime, style: .date).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                action
            }
            status
        }
    }

    @ViewBuilder var action: some View {
        switch model.installState[entry.id] {
        case .preparing, .downloading:
            ProgressView()
        default:
            if model.installed.contains(entry.id) {
                Menu {
                    Button("Launch Minecraft (experimental, needs JIT)") {
                        if let paths = model.paths {
                            Task { await minecraft.launch(versionID: entry.id, paths: paths, settings: model.settings, accounts: accounts) }
                        }
                    }
                    Button("Verify / repair files") { Task { await model.install(entry) } }
                    Button("Prepare launch plan") { model.preparePlan(entry.id) }
                } label: { Label("Installed", systemImage: "checkmark.circle.fill") }
            } else {
                Button("Install") { Task { await model.install(entry) } }.buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder var status: some View {
        switch model.installState[entry.id] {
        case .downloading(let stage, let done, let total, let failed):
            ProgressView(value: Double(done), total: Double(max(total, 1))) {
                Text("\(stage): \(done)/\(total)\(failed > 0 ? " · \(failed) failed" : "")").font(.caption)
            }
        case .finished(let ok, let failed):
            Text(failed == 0 ? "All \(ok) files verified" : "\(failed) files failed — see Logs")
                .font(.caption).foregroundStyle(failed == 0 ? Color.green : Color.red)
        case .failed(let msg):
            Text(msg).font(.caption).foregroundStyle(.red)
        default:
            EmptyView()
        }
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
                } header: {
                    Text("Game")
                } footer: {
                    Text("Lower resolution runs faster and uses less battery. Memory is capped at 40% of what iOS allows the app. Both apply the next time you launch Minecraft.")
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
        let s = UIScreen.main.bounds.size, k = UIScreen.main.nativeScale * scale
        return "\(Int((max(s.width, s.height) * k).rounded()))×\(Int((min(s.width, s.height) * k).rounded())) px"
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject var model: LauncherModel
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
                    Text("This build downloads and verifies game files and starts Minecraft Java (Java 17 versions, offline profile) in the app. Starting the game needs JIT: open the app from StikDebug.")
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

struct LogView: View {
    @EnvironmentObject var model: LauncherModel
    @State private var entries: [LogEntry] = []

    var body: some View {
        NavigationStack {
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
    }

    func color(_ l: LogLevel) -> Color {
        switch l {
        case .error: .red
        case .warning: .orange
        default: .secondary
        }
    }
}
