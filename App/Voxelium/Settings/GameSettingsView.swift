import SwiftUI
import VoxeliumCore

/// Settings → Game: memory, resolution and the large interface. All apply the next time
/// Minecraft starts.
struct GameSettingsView: View {
    @EnvironmentObject var model: LauncherModel
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                SliderSetting(title: "Memory", summary: "Capped at 40% of what iOS allows the app.",
                              value: Binding(get: { Double(model.settings.maxMemoryMB) },
                                             set: { model.settings.maxMemoryMB = Int($0) }),
                              range: 512...8192, step: 256) { mb in
                    Int(mb) % 1024 == 0 ? "\(Int(mb) / 1024) GB" : "\(Int(mb)) MB"
                }
                SliderSetting(title: "Resolution", summary: "Lower runs faster and uses less battery.",
                              value: $model.settings.renderScale, range: LauncherSettings.renderScaleRange, step: 0.05) { s in
                    "\(Int((s * 100).rounded()))% · \(Self.renderPixels(s))"
                }
                SwitchSetting(title: "Large interface",
                              summary: "Uses the nearest resolution where Minecraft can show its biggest hotbar and menus, and sets GUI Scale to Auto.",
                              isOn: $model.settings.largeInterface)
                if model.settings.largeInterface {
                    let used = Self.effectiveRenderScale(model.settings)
                    SettingRow("Resolution used") {
                        Text("\(Int((used * 100).rounded()))% · \(Self.renderPixels(used))")
                            .font(.vxLabel).foregroundStyle(VX.onSurface).monospacedDigit()
                    }
                }
                Text("These apply the next time you start Minecraft.")
                    .font(.vxCaption).foregroundStyle(VX.onSurfaceVariant).padding(.top, 4)
            }
            .padding(.horizontal, VX.margin(sizeClass)).padding(.vertical, 12)
            .frame(maxWidth: 720).frame(maxWidth: .infinity)
        }
        .vxPage()
        .navigationTitle("Game")
        .navigationBarTitleDisplayMode(.inline)
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
