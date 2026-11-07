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
