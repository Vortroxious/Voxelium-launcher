import SwiftUI
import VoxeliumCore

/// Starting a version from any Play button: the shader render-distance check first, then
/// `launchVersion`. The same steps the Installed row's Play menu always took.
@MainActor
final class LaunchFlow: ObservableObject {
    @Published var advice: ShaderLaunchAdvice?
    private var pendingID: String?
    private var pendingRenderer: GameRenderer?

    func play(_ id: String, renderer: GameRenderer? = nil, model: LauncherModel, minecraft: MinecraftLauncher, accounts: AccountModel) {
        pendingID = id
        pendingRenderer = renderer
        if let renderer { RendererMemory.remember(renderer, for: id) }
        if let dir = model.gameDirectory(for: id), let found = ShaderLaunchAdvice.check(gameDirectory: dir) {
            model.log.info("launch", "Shader render-distance warning shown for \(id): \(found.shaderPack) at render distance \(found.renderDistance)")
            advice = found
        } else {
            start(model: model, minecraft: minecraft, accounts: accounts)
        }
    }

    func lowerAndPlay(model: LauncherModel, minecraft: MinecraftLauncher, accounts: AccountModel) {
        guard let id = pendingID else { return }
        if let dir = model.gameDirectory(for: id) {
            do {
                try ShaderLaunchAdvice.applySuggestion(gameDirectory: dir)
                model.log.info("launch", "Render distance lowered to \(ShaderLaunchAdvice.suggestedRenderDistance) for \(id) (shaders on)")
            } catch {
                model.log.error("launch", "Could not change options.txt for \(id): \(error)")
            }
        }
        start(model: model, minecraft: minecraft, accounts: accounts)
    }

    func playAnyway(model: LauncherModel, minecraft: MinecraftLauncher, accounts: AccountModel) {
        guard let id = pendingID else { return }
        model.log.info("launch", "Shader render-distance warning for \(id): played anyway at \(advice?.renderDistance ?? 0)")
        start(model: model, minecraft: minecraft, accounts: accounts)
    }

    func cancel(model: LauncherModel) {
        if let id = pendingID { model.log.info("launch", "Shader render-distance warning for \(id): cancelled") }
        pendingID = nil
    }

    private func start(model: LauncherModel, minecraft: MinecraftLauncher, accounts: AccountModel) {
        guard let id = pendingID else { return }
        pendingID = nil
        launchVersion(id, model: model, minecraft: minecraft, accounts: accounts, renderer: pendingRenderer)
    }
}

/// The shader warning for a page that holds a `LaunchFlow`.
struct LaunchFlowDialogs: ViewModifier {
    @ObservedObject var flow: LaunchFlow
    @EnvironmentObject var model: LauncherModel
    @EnvironmentObject var minecraft: MinecraftLauncher
    @EnvironmentObject var accounts: AccountModel

    func body(content: Content) -> some View {
        content.confirmationDialog("Render distance \(flow.advice?.renderDistance ?? 0) with shaders", isPresented: Binding(
            get: { flow.advice != nil }, set: { if !$0 { flow.advice = nil } }), titleVisibility: .visible) {
            Button("Lower to \(ShaderLaunchAdvice.suggestedRenderDistance) and play") { flow.lowerAndPlay(model: model, minecraft: minecraft, accounts: accounts) }
            Button("Play anyway") { flow.playAnyway(model: model, minecraft: minecraft, accounts: accounts) }
            Button("Cancel", role: .cancel) { flow.cancel(model: model) }
        } message: {
            Text("With the shader pack \(flow.advice?.shaderPack ?? "") on, render distances above \(ShaderLaunchAdvice.comfortableRenderDistance) can use more memory than iOS allows, and the game closes. \(ShaderLaunchAdvice.suggestedRenderDistance)–\(ShaderLaunchAdvice.comfortableRenderDistance) works well on iPhone.")
        }
    }
}

extension View {
    func launchFlowDialogs(_ flow: LaunchFlow) -> some View { modifier(LaunchFlowDialogs(flow: flow)) }
}

/// How an installed version is named on Voxelium's pages (the same rules as before).
extension InstalledVersion {
    /// Loader installs are named like "fabric-loader-0.19.5-1.21.11", "neoforge-21.1.264"
    /// or "1.20.1-forge-47.4.10"; anything else modded is a modpack named after itself.
    var isModpack: Bool {
        isModded && !id.hasPrefix("fabric-loader-") && !id.hasPrefix("quilt-loader-")
            && !id.hasPrefix("neoforge-") && !id.contains("-forge-")
    }
    var loaderLine: String { "\(loader ?? "Modded") \(base)" }
    var title: String { isModpack ? id : isModded ? loaderLine : id }
    var subtitle: String { isModpack ? "Modpack · \(loaderLine)" : isModded ? id : "Vanilla" }
}

/// One JVM per app launch: while a game starts or runs, versions can't be launched or deleted.
extension MinecraftLauncher {
    var gameActive: Bool {
        switch state {
        case .starting, .running, .waitingForJIT: true
        default: false
        }
    }
}

/// A Play control for one version. In builds with the renderer experiment it asks which
/// renderer to use, as the Installed row's menu did.
struct PlayControl<Label: View>: View {
    @EnvironmentObject var model: LauncherModel
    @EnvironmentObject var minecraft: MinecraftLauncher
    @EnvironmentObject var accounts: AccountModel
    let version: InstalledVersion
    @ObservedObject var flow: LaunchFlow
    @ViewBuilder var label: () -> Label
    @State private var rendererChoice: RendererChoice = .single

    var body: some View {
        Group {
            #if VOXELIUM_ZINK_EXPERIMENT
            if rendererChoice == .single {
                Button { play(nil) } label: { label() }
            } else {
                Menu { rendererButtons } label: { label() }
            }
            #else
            Button { play(nil) } label: { label() }
            #endif
        }
        .disabled(minecraft.gameActive)
        #if VOXELIUM_ZINK_EXPERIMENT
        .task(id: version.id) {
            if let paths = model.paths, let resolved = try? VersionResolver(paths: paths).resolve(version.id) {
                rendererChoice = RendererChoice.of(resolved.info)
            }
        }
        #endif
    }

    private func play(_ renderer: GameRenderer?) {
        flow.play(version.id, renderer: renderer, model: model, minecraft: minecraft, accounts: accounts)
    }

    #if VOXELIUM_ZINK_EXPERIMENT
    @ViewBuilder private var rendererButtons: some View {
        let last = RendererMemory.last(for: version.id)
        switch rendererChoice {
        case .single:
            Button("Play") { play(nil) }
        case .vulkanOnly:
            Section {
                rendererButton("Play with Vulkan", .vulkan, last: last)
            } footer: {
                Text("Minecraft 26.3 and later draw with Vulkan; MobileGlues can't run them.")
            }
        case .mobileGluesOrVulkan:
            Section {
                rendererButton("Play with MobileGlues", .mobileGlues, last: last).disabled(mobileGluesBlocked != nil)
                rendererButton("Play with Vulkan", .vulkan, last: last).disabled(vulkanBlocked != nil)
            } footer: {
                if let reason = vulkanBlocked ?? mobileGluesBlocked { Text(reason) }
            }
        }
    }

    private func rendererButton(_ title: String, _ renderer: GameRenderer, last: GameRenderer?) -> some View {
        Button { play(renderer) } label: {
            if last == renderer { SwiftUI.Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    /// Why "Play with Vulkan" (Zink on KosmicKrisp) can't be used now, or nil.
    private var vulkanBlocked: String? {
        if !VXZinkBundled() { return "Vulkan (Zink) is not in this build." }
        if !ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)) {
            return "Vulkan needs iOS 26 or later (Metal 4)."
        }
        if ZinkSession.used || SDLVulkanSession.used { return "Restart Voxelium to switch renderer (Vulkan was set up for a test in this launch)." }
        return nil
    }

    /// Why "Play with MobileGlues" can't be used now, or nil.
    private var mobileGluesBlocked: String? {
        MobileGluesSession.used ? "Restart Voxelium to switch renderer (MobileGlues ran in this launch)." : nil
    }
    #endif
}
