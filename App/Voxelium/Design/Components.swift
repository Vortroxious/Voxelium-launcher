import SwiftUI

// Voxelium's building blocks, the same ones Voxelium for Android uses (ui/voxelium/components).

/// A page's large title with optional trailing controls.
struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.vxLargeTitle).foregroundStyle(VX.onSurface)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle { Text(subtitle).font(.vxCaption).foregroundStyle(VX.onSurfaceVariant) }
            }
            Spacer(minLength: 8)
            trailing()
        }
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.vxLabel).foregroundStyle(VX.onSurfaceVariant).accessibilityAddTraits(.isHeader)
    }
}

/// The coloured loader tag ("FABRIC").
struct LoaderBadge: View {
    let loader: String?
    var isModpack = false
    var body: some View {
        let (bg, fg) = VX.loaderColors(loader, isModpack: isModpack)
        Text((isModpack ? "Modpack" : loader ?? "Vanilla").uppercased())
            .font(.vxBadge).foregroundStyle(fg)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(bg, in: RoundedRectangle(cornerRadius: VX.Radius.extraSmall))
    }
}

/// A rounded row container; highlighted when selected.
struct RowCard<Content: View>: View {
    var selected = false
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(spacing: 10) { content() }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? VX.primaryContainer : VX.surface, in: RoundedRectangle(cornerRadius: VX.Radius.medium))
            .overlay {
                if selected { RoundedRectangle(cornerRadius: VX.Radius.medium).stroke(VX.primary.opacity(0.6), lineWidth: 1) }
            }
    }
}

/// The round Play button on version rows.
struct RoundPlayButton: View {
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "play.fill").font(.system(size: 17, weight: .bold)).foregroundStyle(VX.primary)
                .frame(width: 44, height: 44)
                .background(VX.secondaryContainer, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// A small filled chip ("24 mods").
struct InfoChip: View {
    let text: String
    var body: some View {
        Text(text).font(.vxCaption).foregroundStyle(VX.onSecondaryContainer)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(VX.secondaryContainer, in: RoundedRectangle(cornerRadius: VX.Radius.small))
    }
}

/// A filter or tab chip.
struct ToggleChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(selected ? .vxLabel : .footnote.weight(.semibold))
                .foregroundStyle(selected ? VX.onPrimaryContainer : VX.onSurfaceVariant)
                .padding(.horizontal, 14).frame(minHeight: 36)
                .background(selected ? VX.primaryContainer : .clear, in: Capsule())
                .overlay { Capsule().stroke(selected ? VX.primary : VX.outline, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The big green action button.
struct PrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = 52
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.heavy)).foregroundStyle(VX.onPrimary)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(VX.primary.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
    }
}

/// An outlined secondary button.
struct OutlineButtonStyle: ButtonStyle {
    var tint: Color = VX.onSurface
    var height: CGFloat = 46
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.bold)).foregroundStyle(tint)
            .padding(.horizontal, 16).frame(minHeight: height)
            .background(configuration.isPressed ? VX.surfaceHigh : .clear, in: Capsule())
            .overlay { Capsule().stroke(VX.outline, lineWidth: 1) }
    }
}

/// A coloured notice above a page's content (JIT, updates, problems).
struct Banner<Actions: View>: View {
    enum Kind { case info, warning, error, progress }
    let kind: Kind
    let title: String
    var message: String?
    @ViewBuilder var actions: () -> Actions

    init(_ kind: Kind, _ title: String, message: String? = nil, @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }) {
        self.kind = kind
        self.title = title
        self.message = message
        self.actions = actions
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon.frame(width: 22)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold))
                if let message { Text(message).font(.vxCaption).foregroundStyle(fg.opacity(0.85)) }
                actions()
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(fg)
        .padding(12)
        .background(bg, in: RoundedRectangle(cornerRadius: VX.Radius.medium))
    }

    @ViewBuilder private var icon: some View {
        switch kind {
        case .progress: ProgressView().tint(fg)
        case .info: Image(systemName: "info.circle.fill")
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(VX.tertiary)
        case .error: Image(systemName: "xmark.octagon.fill").foregroundStyle(VX.error)
        }
    }
    private var bg: Color {
        switch kind {
        case .warning: VX.tertiaryContainer
        case .error: VX.errorContainer
        case .info, .progress: VX.surface
        }
    }
    private var fg: Color {
        switch kind {
        case .warning: VX.onTertiaryContainer
        case .error, .info, .progress: VX.onSurface
        }
    }
}

// MARK: Settings rows

/// One setting on a card: title, optional explanation, and its control.
struct SettingRow<Control: View>: View {
    let title: String
    var summary: String?
    @ViewBuilder var control: () -> Control

    init(_ title: String, summary: String? = nil, @ViewBuilder control: @escaping () -> Control = { EmptyView() }) {
        self.title = title
        self.summary = summary
        self.control = control
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.vxHeadline).foregroundStyle(VX.onSurface)
                if let summary { Text(summary).font(.vxCaption).foregroundStyle(VX.onSurfaceVariant) }
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .background(VX.surface, in: RoundedRectangle(cornerRadius: VX.Radius.medium))
    }
}

struct SwitchSetting: View {
    let title: String
    var summary: String?
    @Binding var isOn: Bool
    var body: some View {
        SettingRow(title, summary: summary) { Toggle(title, isOn: $isOn).labelsHidden().tint(VX.primary) }
    }
}

/// A slider with its value on the right.
struct SliderSetting: View {
    let title: String
    var summary: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let label: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.vxHeadline).foregroundStyle(VX.onSurface)
                    if let summary { Text(summary).font(.vxCaption).foregroundStyle(VX.onSurfaceVariant) }
                }
                Spacer(minLength: 8)
                Text(label(value)).font(.vxLabel).foregroundStyle(VX.onSurface).monospacedDigit()
            }
            Slider(value: $value, in: range, step: step).tint(VX.primary)
                .accessibilityLabel(title).accessibilityValue(label(value))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(VX.surface, in: RoundedRectangle(cornerRadius: VX.Radius.medium))
    }
}

/// A choice from a short list, as a menu.
struct ChoiceSetting<Value: Hashable>: View {
    let title: String
    var summary: String?
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String

    var body: some View {
        SettingRow(title, summary: summary) {
            Menu {
                Picker(title, selection: $selection) {
                    ForEach(options, id: \.self) { Text(label($0)).tag($0) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(label(selection)).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
                .font(.subheadline).foregroundStyle(VX.onSurface)
                .padding(.horizontal, 12).frame(minHeight: 36)
                .overlay { RoundedRectangle(cornerRadius: VX.Radius.small).stroke(VX.outline, lineWidth: 1) }
            }
        }
    }
}

/// A one-line text setting.
struct TextSetting: View {
    let title: String
    var summary: String?
    @Binding var text: String
    var placeholder = ""
    var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.vxHeadline).foregroundStyle(VX.onSurface)
            if let summary { Text(summary).font(.vxCaption).foregroundStyle(VX.onSurfaceVariant) }
            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(.horizontal, 12).frame(minHeight: 44)
                .background(VX.background, in: RoundedRectangle(cornerRadius: VX.Radius.small + 2))
                .overlay { RoundedRectangle(cornerRadius: VX.Radius.small + 2).stroke(error == nil ? VX.outline : VX.error, lineWidth: 1) }
                .accessibilityLabel(title)
            if let error { Text(error).font(.vxCaption).foregroundStyle(VX.error) }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(VX.surface, in: RoundedRectangle(cornerRadius: VX.Radius.medium))
    }
}

/// One option of a list, with a check when chosen.
struct PickRow: View {
    let title: String
    var summary: String?
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            RowCard(selected: selected) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.vxHeadline).foregroundStyle(VX.onSurface)
                    if let summary { Text(summary).font(.vxCaption).foregroundStyle(selected ? VX.onPrimaryContainer : VX.onSurfaceVariant).lineLimit(2) }
                }
                Spacer()
                if selected { Image(systemName: "checkmark").font(.body.weight(.bold)).foregroundStyle(VX.primary) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The Voxelium mark: the cube on its green tile.
struct VoxeliumMark: View {
    var size: CGFloat = 36
    var body: some View {
        Image(systemName: "cube")
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(VX.onPrimary)
            .frame(width: size, height: size)
            .background(VX.primary, in: RoundedRectangle(cornerRadius: size * 0.28))
            .accessibilityHidden(true)
    }
}

extension View {
    /// The page background, behind the safe areas too.
    func vxPage() -> some View {
        background(VX.background.ignoresSafeArea())
    }

    /// A `List` or `Form` on Voxelium's background with its rows on cards.
    func vxList() -> some View {
        scrollContentBackground(.hidden)
            .background(VX.background.ignoresSafeArea())
            .tint(VX.primary)
    }

    /// A row of a `vxList`.
    func vxRow() -> some View {
        listRowBackground(VX.surface)
    }
}
