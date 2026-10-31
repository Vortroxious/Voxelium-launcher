#if VOXELIUM_JIT_HELPER_SPIKE
import SwiftUI
import UniformTypeIdentifiers
import VoxeliumCore

/// Spike (docs/JIT_INTEGRATION_PLAN.md, Phase 2): settings for the built-in JIT helper.
/// The pairing file is kept in the Keychain, never in Documents, and never logged.
enum BuiltInJITSpike {
    private static let keychain = KeychainStore(service: "io.github.voxelium.jithelper")
    private static let pairingAccount = "pairingFile"
    private static let useKey = "VoxeliumBuiltInJIT"

    /// Play asks the helper instead of StikDebug (when a pairing file is imported).
    static var useForPlay: Bool {
        get { UserDefaults.standard.object(forKey: useKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: useKey) }
    }

    static var pairingData: Data? { keychain.read(pairingAccount) }

    /// Reads a pairing file picked in Files and stores it. Returns its size. Any extension is
    /// accepted (.plist, .mobiledevicepairing, …); the content must be a property list.
    static func importPairingFile(from url: URL) throws -> Int {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard (try? PropertyListSerialization.propertyList(from: data, format: nil)) is [String: Any] else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "That file isn't a pairing file (not a property list)."])
        }
        try keychain.write(data, for: pairingAccount)
        return data.count
    }

    static func deletePairingFile() throws { try keychain.delete(pairingAccount) }

    static func stageText(_ stage: Int32) -> String {
        switch stage {
        case 1: "Connecting to this iPhone's developer services…"
        case 2, 5: "Checking the developer disk image…"
        case 3: "Downloading the developer disk image…"
        case 4: "Mounting the developer disk image…"
        case 6: "Attaching to Voxelium…"
        case 7: "Turning on JIT…"
        case 8: "JIT is on"
        default: "Turning on JIT with the built-in helper…"
        }
    }
}

/// The JIT tab (it replaces Logs in the test build; Logs moved to Diagnostics). Also shown
/// as a sheet from Play's "Import a pairing file" problem.
struct BuiltInJITView: View {
    var showsDone = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                JITHelperSpikeSection()
                Section {
                    Label("LocalDevVPN connected", systemImage: "network")
                    Label("Internet the first time (Voxelium downloads the developer disk image once)", systemImage: "arrow.down.circle")
                } header: {
                    Text("Before you tap Play")
                } footer: {
                    Text("The developer disk image adds the debugger service that turns on JIT. It stays mounted until the iPhone restarts; the next Play mounts it again.")
                }
                Section {
                    Text("The pairing file lets Voxelium talk to this iPhone's developer services. Make it once on a computer with the iPhone connected by cable, put it in Files, then import it above. It's kept in the Keychain; you can delete the copy in Files afterwards.")
                        .font(.callout)
                    Link(destination: setupGuideURL) { Label("Setup guide", systemImage: "book") }
                } header: {
                    Text("Getting a pairing file")
                }
            }
            .navigationTitle("JIT")
            .toolbar {
                if showsDone { Button("Done") { dismiss() } }
            }
        }
    }
}

/// The pairing file, the Play switch, and the helper check.
struct JITHelperSpikeSection: View {
    @State private var lines: [String] = []
    @State private var importing = false
    @State private var hasPairing = BuiltInJITSpike.pairingData != nil
    @State private var useForPlay = BuiltInJITSpike.useForPlay

    private var method: String {
        if useForPlay && hasPairing { return "Built-in StikJIT" }
        if JITCoordinator.stikDebugInstalled { return "StikDebug" }
        return useForPlay ? "Nothing yet: import a pairing file" : "Nothing: StikDebug isn't installed"
    }

    var body: some View {
        Section {
            LabeledContent("Play turns on JIT with", value: method)
            LabeledContent("Pairing file", value: hasPairing ? "Imported" : "None")
            Button { importing = true } label: {
                Label(hasPairing ? "Replace the pairing file" : "Import the pairing file", systemImage: "doc.badge.plus")
            }
            if hasPairing {
                Button(role: .destructive) {
                    try? BuiltInJITSpike.deletePairingFile()
                    hasPairing = false
                    Logger.shared.info("jitspike", "Pairing file deleted")
                } label: { Label("Delete the pairing file", systemImage: "trash") }
            }
            Toggle("Use the built-in helper for Play", isOn: Binding(
                get: { useForPlay },
                set: { on in
                    useForPlay = on
                    BuiltInJITSpike.useForPlay = on
                    Logger.shared.info("jitspike", "Built-in helper for Play: \(on)")
                }))
            Button {
                lines = []
                Logger.shared.info("jitspike", "Check started")
                VXJITHelperSpikeRun { line in
                    lines.append(line)
                    Logger.shared.info("jitspike", line)
                }
            } label: {
                Label("Check the JIT helper", systemImage: "stethoscope")
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption.monospaced())
                    .foregroundStyle(line.contains("FAIL") ? Color.red : Color.primary)
            }
        } header: {
            Text("Built-in StikJIT (test)")
        } footer: {
            Text("With a pairing file imported and the switch on, Play turns on JIT here, without StikDebug. Without a pairing file, Play uses StikDebug if it's installed.")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url):
                do {
                    let size = try BuiltInJITSpike.importPairingFile(from: url)
                    hasPairing = true
                    Logger.shared.info("jitspike", "Pairing file imported (\(size) bytes)")
                } catch {
                    lines.append("FAIL: \(error.localizedDescription)")
                    Logger.shared.error("jitspike", "Pairing file import failed: \(error.localizedDescription)")
                }
            case .failure(let error):
                Logger.shared.error("jitspike", "Pairing file picker: \(error.localizedDescription)")
            }
        }
    }
}
#endif
