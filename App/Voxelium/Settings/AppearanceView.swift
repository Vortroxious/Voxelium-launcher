import SwiftUI

/// Settings → Appearance: the accent colour, picked from 25 swatches with a live preview.
/// A sheet held by ContentView, so it stays open while the launcher redraws in the new colour.
struct AppearanceSheet: View {
    @EnvironmentObject var appearance: AppearanceModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass

    private let columns = [GridItem(.adaptive(minimum: 64), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    preview
                    SectionLabel("Accent colour · \(appearance.accent.name)")
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(Accent.all) { accent in Swatch(accent: accent, selected: accent == appearance.accent) {
                            appearance.choose(accent)
                        } }
                    }
                    Text("Used for buttons, highlights and the tab bar. Light and dark mode each get a shade that stays easy to read.")
                        .font(.vxCaption).foregroundStyle(VX.onSurfaceVariant)
                }
                .padding(.horizontal, VX.margin(sizeClass)).padding(.vertical, 12)
                .frame(maxWidth: 720).frame(maxWidth: .infinity)
                // Redrawn with the new colours when the accent changes.
                .id(appearance.accent.id)
            }
            .vxPage()
            .navigationTitle("Appearance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() }.fontWeight(.bold) }
            .tint(VX.primary)
        }
    }

    /// A small Play card in the chosen colour.
    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LAST PLAYED").font(.caption2.weight(.bold)).kerning(0.8).foregroundStyle(VX.secondary)
            HStack(spacing: 8) {
                Text("Fabric 1.21.11").font(.vxTitle).foregroundStyle(VX.onSurface)
                LoaderBadge(loader: "Fabric")
            }
            HStack(spacing: 6) {
                InfoChip(text: "12 mods")
                InfoChip(text: "3 worlds")
            }
            HStack(spacing: 10) {
                SwiftUI.Label("Play", systemImage: "play.fill")
                    .font(.headline.weight(.heavy)).foregroundStyle(VX.onPrimary)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(VX.primary, in: Capsule())
                Image(systemName: "ellipsis").font(.title3.weight(.bold)).foregroundStyle(VX.onSecondaryContainer)
                    .frame(width: 48, height: 48)
                    .overlay { Circle().stroke(VX.highlightBorder, lineWidth: 1) }
            }
            .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VX.highlight, in: RoundedRectangle(cornerRadius: VX.Radius.extraLarge))
        .overlay { RoundedRectangle(cornerRadius: VX.Radius.extraLarge).stroke(VX.highlightBorder, lineWidth: 1) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview in \(appearance.accent.name)")
    }
}

/// One colour: a filled circle with its name, checked when chosen.
private struct Swatch: View {
    let accent: Accent
    let selected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let hex = scheme == .dark ? accent.dark : accent.light
        let fill = Color(UIColor(hex: hex))
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(fill)
                    Circle().stroke(VX.outline, lineWidth: 1)
                    if selected {
                        Circle().stroke(VX.onSurface, lineWidth: 3).padding(-5)
                        Image(systemName: "checkmark").font(.body.weight(.heavy))
                            .foregroundStyle(UIColor(hex: hex).luminance > 0.4 ? Color.black : Color.white)
                    }
                }
                .frame(width: 44, height: 44)
                .padding(5)
                Text(accent.name).font(.caption2.weight(selected ? .bold : .regular))
                    .foregroundStyle(selected ? VX.onSurface : VX.onSurfaceVariant)
                    .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accent.name)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
