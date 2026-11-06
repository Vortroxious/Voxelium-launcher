import SwiftUI
import UniformTypeIdentifiers
import VoxeliumCore

/// Controls, in portrait: a small landscape preview of the layout on top (drag to move, tap to
/// select) and the selected control's settings, or the layout's, below it. The full-screen
/// landscape editor is one tap away.
struct ControlsView: View {
    @EnvironmentObject var controls: ControlsModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var mode: ControlsEditorView.Mode = .game
    @State private var selection: Selection?
    @State private var showEditor = false
    @State private var confirmReset = false
    @State private var importing = false
    @State private var importError: String?

    enum Selection: Hashable { case joystick, button(UUID) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 10) {
                    PageHeader("Controls") {
                        Button { showEditor = true } label: {
                            SwiftUI.Label("Full screen", systemImage: "arrow.up.left.and.arrow.down.right")
                        }
                        .buttonStyle(OutlineButtonStyle(tint: VX.onSurface, height: 40))
                    }
                    HStack(spacing: 6) {
                        ForEach(ControlsEditorView.Mode.allCases) { m in
                            ToggleChip(title: m == .drawer ? "Drawer" : m.rawValue, selected: mode == m) {
                                mode = m
                                if case .joystick = selection, m != .game { selection = nil }
                            }
                        }
                    }
                    LayoutPreview(mode: mode, selection: $selection)
                    Text("Drag to move · tap to select").font(.vxCaption).foregroundStyle(VX.onSurfaceVariant)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, VX.margin(sizeClass))
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if let error = controls.saveError { Banner(.error, error) }
                        panel
                    }
                    .padding(.horizontal, VX.margin(sizeClass)).padding(.bottom, 16)
                }
            }
            .padding(.top, 4)
            .frame(maxWidth: 720).frame(maxWidth: .infinity)
            .vxPage()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: UUID.self) { ControlButtonForm(id: $0) }
        }
        .fullScreenCover(isPresented: $showEditor) { ControlsEditorView() }
        .confirmationDialog("Reset all controls to the default layout?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { selection = nil; controls.resetToDefault() }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                try controls.importLayout(from: result.get())
                selection = nil
            } catch {
                importError = error.localizedDescription
            }
        }
        .alert("Not imported", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    @ViewBuilder private var panel: some View {
        switch selection {
        case .button(let id):
            if let b = controls.button(id) { ButtonPanel(button: b, selection: $selection) } else { layoutPanel }
        case .joystick:
            joystickPanel
        case nil:
            layoutPanel
        }
    }

    private var joystickPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelTitle("Joystick", detail: "Moves you around in game") { selection = nil }
            SliderSetting(title: "Size", value: Binding(get: { controls.layout.joystick.size }, set: { controls.setJoystickSize($0) }),
                          range: ControlLayout.joystickSizeRange, step: 8) { "\(Int($0)) pt" }
        }
    }

    private var layoutPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    let id = controls.addButton(inGame: mode == .game, inMenu: mode == .menu, inDrawer: mode == .drawer)
                    selection = .button(id)
                } label: { SwiftUI.Label("Button", systemImage: "plus") }
                .buttonStyle(PrimaryButtonStyle(height: 44))
                Button("Import") { importing = true }.buttonStyle(OutlineButtonStyle(height: 44))
                if let file = controls.layoutFile {
                    ShareLink(item: file) { Image(systemName: "square.and.arrow.up") }
                        .buttonStyle(OutlineButtonStyle(height: 44))
                        .accessibilityLabel("Share the layout")
                }
            }
            SectionLabel("Layout").padding(.top, 6)
            SliderSetting(title: "Button opacity", value: Binding(get: { controls.layout.opacity }, set: { controls.setOpacity($0) }),
                          range: ControlLayout.opacityRange, step: 0.05) { "\(Int(($0 * 100).rounded()))%" }
            SliderSetting(title: "Joystick size", value: Binding(get: { controls.layout.joystick.size }, set: { controls.setJoystickSize($0) }),
                          range: ControlLayout.joystickSizeRange, step: 8) { "\(Int($0)) pt" }
            SettingRow("Default layout", summary: controls.isCustom ? "You're using your own layout." : "You're using the default layout (Amethyst's).") {
                Button("Reset") { confirmReset = true }
                    .buttonStyle(OutlineButtonStyle(tint: VX.error, height: 36))
                    .disabled(!controls.isCustom)
            }
            SectionLabel("Buttons · \(controls.layout.buttons.count)").padding(.top, 6)
            ForEach(controls.layout.buttons) { b in
                NavigationLink(value: b.id) {
                    RowCard {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(b.name.isEmpty ? "Unnamed" : b.name).font(.vxHeadline).foregroundStyle(VX.onSurface).lineLimit(1)
                            Text("\(b.actionSummary) · \(Self.visibility(b))").font(.vxCaption).foregroundStyle(VX.onSurfaceVariant).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(VX.onSurfaceVariant)
                    }
                }
                .buttonStyle(.plain)
            }
            Text("Changes are saved right away and used the next time you start Minecraft.")
                .font(.vxCaption).foregroundStyle(VX.onSurfaceVariant).padding(.top, 4)
        }
    }

    private func panelTitle(_ title: String, detail: String, close: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.vxTitle).foregroundStyle(VX.onSurface).lineLimit(1)
                Text(detail).font(.vxCaption).foregroundStyle(VX.onSurfaceVariant).lineLimit(1)
            }
            Spacer()
            Button("Done", action: close).font(.subheadline.weight(.bold)).frame(minHeight: 44)
        }
    }
}

/// The selected button: its size, where it shows, and the full editor for its action.
private struct ButtonPanel: View {
    @EnvironmentObject var controls: ControlsModel
    let button: ControlButton
    @Binding var selection: ControlsView.Selection?

    private func binding<T>(_ path: WritableKeyPath<ControlButton, T>) -> Binding<T> {
        Binding(get: { (controls.button(button.id) ?? button)[keyPath: path] },
                set: { var b = controls.button(button.id) ?? button; b[keyPath: path] = $0; controls.update(b) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(button.name.isEmpty ? "Unnamed" : button.name).font(.vxTitle).foregroundStyle(VX.onSurface).lineLimit(1)
                    Text("\(button.actionSummary) · \(ControlsView.visibility(button))").font(.vxCaption).foregroundStyle(VX.onSurfaceVariant).lineLimit(1)
                }
                Spacer()
                Button("Done") { selection = nil }.font(.subheadline.weight(.bold)).frame(minHeight: 44)
            }
            NavigationLink(value: button.id) {
                SettingRow("Name and action", summary: "Keys, mouse button or a special action.") {
                    Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(VX.onSurfaceVariant)
                }
            }
            .buttonStyle(.plain)
            SliderSetting(title: "Width", value: binding(\.width), range: 20...300, step: 4) { "\(Int($0)) pt" }
            SliderSetting(title: "Height", value: binding(\.height), range: 20...300, step: 4) { "\(Int($0)) pt" }
            SwitchSetting(title: "Only in the More drawer", isOn: binding(\.inDrawer))
            if !button.inDrawer {
                SwitchSetting(title: "Show in game", isOn: binding(\.showInGame))
                SwitchSetting(title: "Show in menus", isOn: binding(\.showInMenu))
            }
            Button("Delete button") {
                selection = nil
                controls.delete(button.id)
            }
            .buttonStyle(OutlineButtonStyle(tint: VX.error, height: 44))
            .padding(.top, 4)
        }
    }
}

/// The layout at the landscape screen's ratio, scaled to the page's width.
private struct LayoutPreview: View {
    @EnvironmentObject var controls: ControlsModel
    let mode: ControlsEditorView.Mode
    @Binding var selection: ControlsView.Selection?
    @State private var dragging: ControlsView.Selection?
    @State private var dragOffset: CGSize = .zero

    var body: some View {
        let screen = controls.screen
        GeometryReader { geo in
            let k = geo.size.width / screen.width
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(white: 0.24), Color(white: 0.1)], startPoint: .top, endPoint: .bottom)
                    .contentShape(Rectangle())
                    .onTapGesture { selection = nil }
                if mode == .game { joystick(k) }
                ForEach(ControlsEditorView.visible(controls.layout.buttons, in: mode)) { chip($0, k) }
            }
            .clipShape(RoundedRectangle(cornerRadius: VX.Radius.medium))
            .overlay { RoundedRectangle(cornerRadius: VX.Radius.medium).stroke(VX.outline, lineWidth: 1) }
        }
        .aspectRatio(screen.width / screen.height, contentMode: .fit)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Layout preview")
    }

    private func offset(_ s: ControlsView.Selection) -> CGSize { dragging == s ? dragOffset : .zero }

    /// Drags in the preview move the control by the same distance on the real screen.
    private func drag(_ s: ControlsView.Selection, _ k: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in dragging = s; dragOffset = v.translation; selection = s }
            .onEnded { v in
                let d = CGSize(width: v.translation.width / k, height: v.translation.height / k)
                switch s {
                case .joystick: controls.move(nil, by: d)
                case .button(let id): controls.move(id, by: d)
                }
                dragging = nil
                dragOffset = .zero
            }
    }

    private func chip(_ b: ControlButton, _ k: CGFloat) -> some View {
        let s = ControlsView.Selection.button(b.id)
        let o: CGSize = offset(s)
        let w: CGFloat = b.width * k
        let h: CGFloat = b.height * k
        let selected: Bool = selection == s
        let W: CGFloat = controls.screen.width * k
        let H: CGFloat = controls.screen.height * k
        let x: CGFloat = b.x * W + w / 2 + o.width
        let y: CGFloat = b.y * H + h / 2 + o.height
        let shape = RoundedRectangle(cornerRadius: min(w, h) / 2)
        let stroke: Color = selected ? VX.primary : Color.white.opacity(0.6)
        let label = Text(b.name)
            .font(.system(size: max(7, 13 * k), weight: .medium))
            .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.5)
            .foregroundStyle(.white)
            .padding(2)
            .frame(width: w, height: h)
        return label
            .background(Color.black.opacity(0.35), in: shape)
            .opacity(controls.layout.opacity)
            .overlay(shape.stroke(stroke, lineWidth: selected ? 2 : 1))
            .position(x: x, y: y)
            .onTapGesture { selection = s }
            .gesture(drag(s, k))
            .accessibilityLabel(b.name.isEmpty ? "Unnamed button" : b.name)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func joystick(_ k: CGFloat) -> some View {
        let j = controls.layout.joystick
        let o: CGSize = offset(.joystick)
        let size: CGFloat = j.size * k
        let selected: Bool = selection == .joystick
        let x: CGFloat = j.x * controls.screen.width * k + size / 2 + o.width
        let y: CGFloat = j.y * controls.screen.height * k + size / 2 + o.height
        let stroke: Color = selected ? VX.primary : Color.white.opacity(0.6)
        return Circle()
            .fill(Color.black.opacity(0.35))
            .overlay(Circle().stroke(stroke, lineWidth: selected ? 2 : 1))
            .overlay(Image(systemName: "dpad").font(.system(size: max(9, 22 * k))).foregroundStyle(.white.opacity(0.8)))
            .frame(width: size, height: size)
            .opacity(controls.layout.opacity)
            .position(x: x, y: y)
            .onTapGesture { selection = .joystick }
            .gesture(drag(.joystick, k))
            .accessibilityLabel("Joystick")
    }
}
