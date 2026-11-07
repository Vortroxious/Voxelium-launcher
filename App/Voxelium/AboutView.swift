import SwiftUI
import UIKit

/// Settings → About: version and updates, licence, credits and the bundled third-party
/// notices (THIRD_PARTY_NOTICES.txt, made by scripts/collect-licenses.sh).
struct AboutView: View {
    @EnvironmentObject var updates: UpdateModel

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    VoxeliumMark(size: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Voxelium").font(.vxTitle).foregroundStyle(VX.onSurface)
                        Text("Version \(versionText)").font(.vxCaption).foregroundStyle(VX.onSurfaceVariant)
                    }
                }
                .padding(.vertical, 4)
                Link(destination: URL(string: "https://github.com/Vortroxious/Voxelium-launcher")!) {
                    Label("Voxelium on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: setupGuideURL) { Label("Setup guide", systemImage: "book") }
            }
            .vxRow()
            Section {
                Button { Task { await updates.check() } } label: { Label("Check for updates", systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(updates.status == .checking)
                switch updates.status {
                case .idle: EmptyView()
                case .checking: HStack(spacing: 8) { ProgressView(); Text("Checking GitHub…").font(.callout) }
                case .upToDate: Text("Voxelium is up to date.").font(.callout)
                case .available(let r):
                    Link(destination: r.htmlUrl) { Label("Voxelium \(r.version) is available", systemImage: "arrow.down.app") }
                case .failed(let why): Text("Couldn't check: \(why)").font(.callout).foregroundStyle(VX.error)
                }
                Toggle("Check for updates automatically", isOn: $updates.automatic)
            } header: {
                Text("Updates")
            } footer: {
                Text("Voxelium asks GitHub once a day for the latest release. Nothing about you is sent, and nothing is downloaded or installed by itself.")
            }
            .vxRow()
            Section {
                LabeledContent("Licence", value: "GNU GPL v3.0")
            } footer: {
                Text("Voxelium is free software: you can share and change it under the GNU General Public License v3.0. The source code, with the patches and build scripts for everything it bundles, is published with each release.")
            }
            .vxRow()
            Section("Credits") {
                credit("ZalithLauncher2", "The Android launcher Voxelium is inspired by (GPL-3.0).")
                credit("Amethyst-iOS and PojavLauncher", "Prior art for Minecraft on iOS; the JIT26 scripts come from Amethyst.")
                credit("AngelAuraMC", "OpenJDK runtimes and the LWJGL builds for iOS.")
                credit("MobileGlues", "Desktop OpenGL on OpenGL ES (LGPL-2.1), with Voxelium's fixes.")
                credit("ANGLE", "OpenGL ES on Metal (BSD-3-Clause).")
                credit("gl4es, LWJGL, OpenAL Soft, FreeType, glslang, SPIRV-Cross", "And the other libraries listed under Third-party licences.")
                credit("Modrinth", "Mods, packs and modpacks are browsed through Modrinth's public API.")
            }
            .vxRow()
            Section {
                NavigationLink("Third-party licences") { NoticesView() }
            } footer: {
                Text("Not affiliated with or endorsed by Mojang Studios, Microsoft, Modrinth or the ZalithLauncher team. Minecraft is a trademark of Mojang Synergies AB; Voxelium does not include Minecraft, which is downloaded from Mojang for your own account.")
            }
            .vxRow()
        }
        .vxList()
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func credit(_ name: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.subheadline.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(VX.onSurfaceVariant)
        }
    }
}

/// The full notices text; a UITextView keeps several thousand lines smooth.
private struct NoticesView: View {
    var body: some View {
        NoticesText()
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Third-party licences")
            .navigationBarTitleDisplayMode(.inline)
    }
}

private struct NoticesText: UIViewRepresentable {
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 24, right: 10)
        let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "txt")
        view.text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "The notices file is missing from this build."
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {}
}
