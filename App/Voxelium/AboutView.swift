import SwiftUI
import UIKit

/// Version, licence, credits and the bundled third-party notices
/// (THIRD_PARTY_NOTICES.txt, made by scripts/collect-licenses.sh).
struct AboutView: View {
    private var versionText: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Version", value: versionText)
                LabeledContent("Licence", value: "GNU GPL v3.0")
            } footer: {
                Text("Voxelium is free software: you can share and change it under the GNU General Public License v3.0. The source code, with the patches and build scripts for everything it bundles, is published with each release.")
            }
            Section("Credits") {
                credit("ZalithLauncher2", "The Android launcher Voxelium is inspired by (GPL-3.0).")
                credit("Amethyst-iOS and PojavLauncher", "Prior art for Minecraft on iOS; the JIT26 scripts come from Amethyst.")
                credit("AngelAuraMC", "OpenJDK runtimes and the LWJGL builds for iOS.")
                credit("MobileGlues", "Desktop OpenGL on OpenGL ES (LGPL-2.1), with Voxelium's fixes.")
                credit("ANGLE", "OpenGL ES on Metal (BSD-3-Clause).")
                credit("gl4es, LWJGL, OpenAL Soft, FreeType, glslang, SPIRV-Cross", "And the other libraries listed under Third-party licences.")
                credit("Modrinth", "Mods, packs and modpacks are browsed through Modrinth's public API.")
            }
            Section {
                NavigationLink("Third-party licences") { NoticesView() }
            } footer: {
                Text("Not affiliated with or endorsed by Mojang Studios, Microsoft, Modrinth or the ZalithLauncher team. Minecraft is a trademark of Mojang Synergies AB; Voxelium does not include Minecraft, which is downloaded from Mojang for your own account.")
            }
        }
        .navigationTitle("About Voxelium")
    }

    private func credit(_ name: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.subheadline.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary)
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
