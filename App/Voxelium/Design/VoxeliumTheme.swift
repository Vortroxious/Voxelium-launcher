import SwiftUI
import UIKit

/// Voxelium's colours, shared with Voxelium for Android: dark slate surfaces with one green
/// accent. Every colour follows the system's light or dark appearance.
enum VX {
    // MARK: Colours (dark / light, the same values as the Android app). The accent colours
    // (primary, secondary, highlight) follow Settings → Appearance; see Design/Accent.swift.
    static var primary: Color { AccentStore.palette.primary }
    static var onPrimary: Color { AccentStore.palette.onPrimary }
    static var primaryContainer: Color { AccentStore.palette.primaryContainer }
    static var onPrimaryContainer: Color { AccentStore.palette.onPrimaryContainer }
    static var secondary: Color { AccentStore.palette.secondary }
    static var secondaryContainer: Color { AccentStore.palette.secondaryContainer }
    static var onSecondaryContainer: Color { AccentStore.palette.onSecondaryContainer }
    static let tertiary = dynamic(0xF2B84B, 0x8A5A00)
    static let tertiaryContainer = dynamic(0x3A3524, 0xFFE1A8)
    static let onTertiaryContainer = dynamic(0xF2DFA6, 0x3A2A00)

    static let background = dynamic(0x0E1214, 0xF4F7F6)
    static let onSurface = dynamic(0xE8EEF0, 0x12181B)
    static let onSurfaceVariant = dynamic(0x9AA8AE, 0x4E5B60)
    static let surfaceLowest = dynamic(0x0B0F11, 0xFFFFFF)
    static let surfaceLow = dynamic(0x12171A, 0xF0F4F3)
    static let surface = dynamic(0x161B1E, 0xEAF0EE)
    static let surfaceHigh = dynamic(0x1B2124, 0xE4EBE9)
    static let surfaceHighest = dynamic(0x222A2E, 0xDDE5E3)
    static let outline = dynamic(0x2C353A, 0xC3CDD0)
    static let outlineVariant = dynamic(0x222A2E, 0xDCE3E1)
    static let error = dynamic(0xFF9C9C, 0xB3261E)
    static let errorContainer = dynamic(0x5A2E2E, 0xF9DEDC)

    /// The Last played card.
    static var highlight: Color { AccentStore.palette.highlight }
    static var onHighlight: Color { AccentStore.palette.onHighlight }
    static var highlightBorder: Color { AccentStore.palette.highlightBorder }

    // MARK: Corners
    enum Radius {
        static let extraSmall: CGFloat = 6
        static let small: CGFloat = 10
        static let medium: CGFloat = 14
        static let large: CGFloat = 18
        static let extraLarge: CGFloat = 22
    }

    /// Side margin of every page; wider on iPad.
    static func margin(_ size: UserInterfaceSizeClass?) -> CGFloat { size == .regular ? 32 : 16 }

    // MARK: Loader badges (background, text)
    static func loaderColors(_ loader: String?, isModpack: Bool) -> (Color, Color) {
        if isModpack { return (dynamic(0x23423A, 0xD7EDE3), dynamic(0xCFE9DD, 0x0C2E23)) }
        switch loader?.lowercased() {
        case "fabric": return (dynamic(0x2D2A45, 0xE6E2FF), dynamic(0xC9C2FF, 0x3B3189))
        case "quilt": return (dynamic(0x3A3524, 0xF6EBC4), dynamic(0xF2DFA6, 0x5A4500))
        case "forge": return (dynamic(0x3A2B26, 0xF8E0D4), dynamic(0xF5C3A9, 0x6B2E12))
        case "neoforge": return (dynamic(0x45302A, 0xFFDCD0), dynamic(0xFFC9B8, 0x7A2A10))
        case nil: return (dynamic(0x22343F, 0xD6ECF8), dynamic(0xB5DDF5, 0x0E4A6B))
        default: return (dynamic(0x23423A, 0xD7EDE3), dynamic(0xCFE9DD, 0x0C2E23))
        }
    }

    private static func dynamic(_ dark: UInt32, _ light: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Voxelium's type scale on Dynamic Type styles, so text still follows the user's size setting.
extension Font {
    static let vxLargeTitle = Font.largeTitle.weight(.heavy)
    static let vxTitle = Font.title2.weight(.heavy)
    static let vxTitleSmall = Font.title3.weight(.heavy)
    static let vxHeadline = Font.headline.weight(.bold)
    static let vxBody = Font.subheadline
    static let vxCaption = Font.caption
    static let vxLabel = Font.footnote.weight(.bold)
    static let vxBadge = Font.caption2.weight(.heavy)
}
