import Foundation

/// How Minecraft draws on the phone (the experimental build's Play menu).
public enum GameRenderer: String, Codable, Sendable, CaseIterable {
    /// Desktop OpenGL through MobileGlues on ANGLE (Metal): 1.17 – 26.1.2.
    case mobileGlues
    /// Vulkan on KosmicKrisp (Mesa's Vulkan on Metal 4): through Zink (desktop GL on
    /// Vulkan) for 1.17 – 26.1.2, or the game's own Vulkan renderer for 26.3+.
    case vulkan
}

/// Which renderers a version can be started with.
public enum RendererChoice: Equatable, Sendable {
    /// One way to start, as before: Minecraft up to 1.16.5 (Java 8, gl4es), and 26.2,
    /// which the launcher refuses with its reason.
    case single
    /// Minecraft 1.17 – 26.1.2: MobileGlues, or Vulkan through Zink.
    case mobileGluesOrVulkan
    /// Minecraft 26.3+ (SDL3): its own Vulkan renderer; MobileGlues cannot run it.
    case vulkanOnly

    public static func of(_ version: VersionInfo) -> RendererChoice {
        let modules = GameRuntime.lwjglArtifacts(of: version)
        if modules.contains("lwjgl-sdl") { return .vulkanOnly }
        if modules.contains("lwjgl-vulkan") { return .single }
        if GameRuntime.javaMajor(for: version) <= 8 { return .single }
        return .mobileGluesOrVulkan
    }
}
