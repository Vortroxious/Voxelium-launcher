import SwiftUI
import UIKit
import VoxeliumCore

/// One accent colour the player can choose in Settings → Appearance. Each has a shade for dark
/// mode and one for light mode, so buttons stay readable on both backgrounds; the cards, chips
/// and highlights are mixed from it.
struct Accent: Identifiable, Hashable {
    let id: String
    let name: String
    let dark: UInt32
    let light: UInt32

    static let voxelium = Accent(id: "voxelium", name: "Voxelium green", dark: 0x3DDC97, light: 0x0F7B5A)

    /// 25 colours people use everywhere, in rainbow order, then the neutrals.
    static let all: [Accent] = [
        voxelium,
        Accent(id: "red", name: "Red", dark: 0xFF6B6B, light: 0xC62828),
        Accent(id: "crimson", name: "Crimson", dark: 0xFF5C7A, light: 0xA4123F),
        Accent(id: "coral", name: "Coral", dark: 0xFF8A65, light: 0xC2410C),
        Accent(id: "orange", name: "Orange", dark: 0xFF9F43, light: 0xC2570A),
        Accent(id: "amber", name: "Amber", dark: 0xFFC145, light: 0x9A6200),
        Accent(id: "gold", name: "Gold", dark: 0xE6C35C, light: 0x8D6E00),
        Accent(id: "yellow", name: "Yellow", dark: 0xFFE14D, light: 0x7F6A00),
        Accent(id: "lime", name: "Lime", dark: 0xA6E35A, light: 0x4F7A00),
        Accent(id: "green", name: "Green", dark: 0x5BD66B, light: 0x2E7D32),
        Accent(id: "mint", name: "Mint", dark: 0x6FE3C1, light: 0x00796B),
        Accent(id: "teal", name: "Teal", dark: 0x2EC4C4, light: 0x00737A),
        Accent(id: "cyan", name: "Cyan", dark: 0x4DD8F0, light: 0x00788A),
        Accent(id: "sky", name: "Sky blue", dark: 0x6CC4FF, light: 0x0369A1),
        Accent(id: "blue", name: "Blue", dark: 0x5B9DFF, light: 0x1E5BD8),
        Accent(id: "navy", name: "Navy", dark: 0x7C9CFF, light: 0x1A2A80),
        Accent(id: "indigo", name: "Indigo", dark: 0x8C8CFF, light: 0x3F3DB5),
        Accent(id: "purple", name: "Purple", dark: 0xB48CFF, light: 0x6A1B9A),
        Accent(id: "violet", name: "Violet", dark: 0xD08CFF, light: 0x8E24AA),
        Accent(id: "magenta", name: "Magenta", dark: 0xFF6FD8, light: 0xAD1457),
        Accent(id: "pink", name: "Pink", dark: 0xFF8FB8, light: 0xC2185B),
        Accent(id: "brown", name: "Brown", dark: 0xC89B7B, light: 0x6D4C41),
        Accent(id: "gray", name: "Gray", dark: 0xB0BAC0, light: 0x546E7A),
        // White would vanish on light backgrounds and black on dark ones, so each keeps its
        // look where it can and turns to charcoal or graphite where it can't.
        Accent(id: "white", name: "White", dark: 0xFFFFFF, light: 0x2B3135),
        Accent(id: "black", name: "Black", dark: 0x59636A, light: 0x111416),
    ]

    static func named(_ id: String?) -> Accent { all.first { $0.id == id } ?? voxelium }
}

/// The accent's colours for every part of the interface (see `VX`).
struct AccentPalette {
    let primary, onPrimary, primaryContainer, onPrimaryContainer: Color
    let secondary, secondaryContainer, onSecondaryContainer: Color
    let highlight, onHighlight, highlightBorder: Color
    let uiPrimary: UIColor

    init(_ accent: Accent) {
        if accent == .voxelium {
            // The original values, shared with Voxelium for Android.
            primary = Self.color(0x3DDC97, 0x0F7B5A)
            onPrimary = Self.color(0x04241A, 0xFFFFFF)
            primaryContainer = Self.color(0x1F3A31, 0xC9F0DE)
            onPrimaryContainer = Self.color(0xCFE9DD, 0x00382A)
            secondary = Self.color(0x7CEBBB, 0x2F6B55)
            secondaryContainer = Self.color(0x23423A, 0xD7EDE3)
            onSecondaryContainer = Self.color(0xCFE9DD, 0x0C2E23)
            highlight = Self.color(0x1A2F28, 0xDDF3E9)
            onHighlight = Self.color(0xB6C6BF, 0x2F4A40)
            highlightBorder = Self.color(0x2A4A3E, 0xB4DDC9)
            uiPrimary = Self.ui(0x3DDC97, 0x0F7B5A)
            return
        }
        let d = UIColor(hex: accent.dark), l = UIColor(hex: accent.light)
        let black = UIColor.black, white = UIColor.white
        let darkSurface = UIColor(hex: 0x161B1E), darkBackground = UIColor(hex: 0x0E1214)
        let darkText = UIColor(hex: 0xE8EEF0), lightText = UIColor(hex: 0x12181B)

        primary = Self.color(d, l)
        onPrimary = Self.color(d.luminance > 0.4 ? d.mixed(black, 0.84) : white,
                               l.luminance > 0.5 ? l.mixed(black, 0.84) : white)
        primaryContainer = Self.color(darkSurface.mixed(d, 0.18), white.mixed(l, 0.22))
        onPrimaryContainer = Self.color(darkText.mixed(d, 0.25), l.mixed(black, 0.55))
        secondary = Self.color(d.mixed(white, 0.35), l.mixed(lightText, 0.3))
        secondaryContainer = Self.color(darkSurface.mixed(d, 0.22), white.mixed(l, 0.16))
        onSecondaryContainer = Self.color(darkText.mixed(d, 0.25), l.mixed(black, 0.65))
        highlight = Self.color(darkBackground.mixed(d, 0.13), white.mixed(l, 0.14))
        onHighlight = Self.color(UIColor(hex: 0xB0B8BC).mixed(d, 0.2), l.mixed(lightText, 0.6))
        highlightBorder = Self.color(darkSurface.mixed(d, 0.28), white.mixed(l, 0.30))
        uiPrimary = Self.ui(d, l)
    }

    private static func ui(_ dark: UIColor, _ light: UIColor) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }
    private static func ui(_ dark: UInt32, _ light: UInt32) -> UIColor { ui(UIColor(hex: dark), UIColor(hex: light)) }
    private static func color(_ dark: UIColor, _ light: UIColor) -> Color { Color(ui(dark, light)) }
    private static func color(_ dark: UInt32, _ light: UInt32) -> Color { Color(ui(dark, light)) }
}

/// The colours `VX` reads while views draw; written only by `AppearanceModel` on the main thread.
enum AccentStore {
    static let key = "VoxeliumAccent"
    nonisolated(unsafe) static var palette = AccentPalette(Accent.named(UserDefaults.standard.string(forKey: key)))
}

/// The chosen accent, kept in UserDefaults. Changing it redraws the launcher (ContentView
/// rebuilds its tabs with the new colours) and retints UIKit's alerts and menus.
@MainActor
final class AppearanceModel: ObservableObject {
    private static let key = AccentStore.key

    @Published private(set) var accent = Accent.named(UserDefaults.standard.string(forKey: key))
    @Published var showPicker = false

    func choose(_ new: Accent) {
        guard new != accent else { return }
        UserDefaults.standard.set(new.id, forKey: Self.key)
        AccentStore.palette = AccentPalette(new)
        accent = new
        applyToWindows()
        Logger.shared.info("appearance", "Accent colour: \(new.name)")
    }

    /// UIKit parts SwiftUI's tint doesn't reach (alerts, menus, share sheets).
    func applyToWindows() {
        let tint = AccentStore.palette.uiPrimary
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows { window.tintColor = tint }
        }
    }
}

extension UIColor {
    /// This colour moved `amount` (0–1) of the way to `other`.
    func mixed(_ other: UIColor, _ amount: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * amount, green: g1 + (g2 - g1) * amount,
                       blue: b1 + (b2 - b1) * amount, alpha: 1)
    }

    /// Relative luminance (0 black – 1 white), to pick dark or white text on the colour.
    var luminance: CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        func lin(_ c: CGFloat) -> CGFloat { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }
}
