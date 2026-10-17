import SwiftUI
import ZalithCore

/// The user's on-screen control layout. Every change is saved to
/// controls/layout.json right away; Minecraft reads it when it starts.
@MainActor
final class ControlsModel: ObservableObject {
    @Published var layout: ControlLayout {
        didSet { if !loading { persist() } }
    }
    @Published private(set) var isCustom = false
    @Published private(set) var saveError: String?

    /// The landscape screen the layout is made for, in points.
    let screen: CGSize
    private let store: ControlLayoutStore?
    private let log = Logger.shared
    private var loading = false

    init() {
        let b = UIScreen.main.bounds.size
        screen = CGSize(width: max(b.width, b.height), height: min(b.width, b.height))
        store = (try? AppPaths.applicationDefault()).map(ControlLayoutStore.init(paths:))
        layout = .amethystDefault(width: screen.width, height: screen.height)
        reload()
    }

    func reload() {
        loading = true
        defer { loading = false }
        if let saved = store?.load(log: log) {
            layout = saved.clamped(width: screen.width, height: screen.height)
            isCustom = true
        } else {
            layout = .amethystDefault(width: screen.width, height: screen.height)
            isCustom = false
        }
    }

    func resetToDefault() {
        do {
            try store?.reset()
            log.info("controls", "Control layout reset to the default")
        } catch {
            saveError = "Could not reset: \(error.localizedDescription)"
        }
        reload()
    }

    private func persist() {
        guard let store else { return }
        do {
            try store.save(layout)
            isCustom = true
            saveError = nil
        } catch {
            saveError = "Could not save: \(error.localizedDescription)"
            log.error("controls", "Saving the control layout failed: \(error)")
        }
    }

    func button(_ id: UUID) -> ControlButton? { layout.buttons.first { $0.id == id } }

    func update(_ button: ControlButton) {
        guard let i = layout.buttons.firstIndex(where: { $0.id == button.id }) else { return }
        layout.buttons[i] = button.clamped(width: screen.width, height: screen.height)
    }

    func delete(_ id: UUID) { layout.buttons.removeAll { $0.id == id } }

    func setOpacity(_ value: Double) {
        var l = layout
        l.opacity = value
        layout = l.clamped(width: screen.width, height: screen.height)
    }

    /// Resizes the joystick around its centre.
    func setJoystickSize(_ size: Double) {
        var l = layout
        let old = l.joystick.size
        l.joystick.x -= (size - old) / 2 / screen.width
        l.joystick.y -= (size - old) / 2 / screen.height
        l.joystick.size = size
        layout = l.clamped(width: screen.width, height: screen.height)
    }

    /// The editor's floating toolbar, centred at (W/2, 0.45 H); new buttons are kept clear of it.
    static let toolbarSize = CGSize(width: 340, height: 130)
    var toolbarRect: ControlLayout.Rect {
        let t = Self.toolbarSize
        return .init(x: screen.width / 2 - t.width / 2, y: screen.height * 0.45 - t.height / 2, width: t.width, height: t.height)
    }

    /// Adds a button in a free spot (not covering another control or the editor
    /// toolbar) and returns its id.
    func addButton(inGame: Bool = true, inMenu: Bool = false, inDrawer: Bool = false) -> UUID {
        let size = 69.6
        let spot = layout.freeSpot(width: size, height: size, screenWidth: screen.width, screenHeight: screen.height,
                                   avoiding: [toolbarRect])
        let b = ControlButton(name: "Button", x: spot.x, y: spot.y,
                              width: size, height: size, showInGame: inGame || inDrawer, showInMenu: inMenu || inDrawer, inDrawer: inDrawer)
        layout.buttons.append(b)
        return b.id
    }

    /// Moves a button (or the joystick, when id is nil) by a distance in points.
    func move(_ id: UUID?, by d: CGSize) {
        let W = screen.width, H = screen.height
        if let id, var b = button(id) {
            b.x += d.width / W
            b.y += d.height / H
            update(b)
        } else if id == nil {
            var j = layout.joystick
            j.x += d.width / W
            j.y += d.height / H
            layout.joystick = j
            layout = layout.clamped(width: W, height: H)
        }
    }
}

// MARK: - Controls tab

struct ControlsView: View {
    @EnvironmentObject var controls: ControlsModel
    @State private var showEditor = false
    @State private var confirmReset = false
    @State private var newButton: UUID?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { showEditor = true } label: {
                        Label("Edit layout on screen", systemImage: "rectangle.and.hand.point.up.left")
                    }
                } footer: {
                    Text("Drag buttons into place in landscape. Changes are saved right away and used the next time you launch Minecraft.")
                }
                if let error = controls.saveError {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
                Section {
                    ForEach(controls.layout.buttons) { b in
                        NavigationLink {
                            ControlButtonForm(id: b.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(b.name.isEmpty ? "Unnamed" : b.name)
                                Text("\(b.actionSummary) · \(Self.visibility(b))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { controls.layout.buttons[$0].id }
                        ids.forEach(controls.delete)
                    }
                    Button { newButton = controls.addButton() } label: { Label("Add button", systemImage: "plus.circle") }
                } header: {
                    Text("Buttons (\(controls.layout.buttons.count))")
                }
                Section {
                    VStack(alignment: .leading) {
                        Text("Button opacity: \(Int((controls.layout.opacity * 100).rounded()))%")
                        Slider(value: Binding(get: { controls.layout.opacity }, set: { controls.setOpacity($0) }),
                               in: ControlLayout.opacityRange, step: 0.05)
                    }
                    Stepper("Joystick size: \(Int(controls.layout.joystick.size)) pt",
                            value: Binding(get: { controls.layout.joystick.size }, set: { controls.setJoystickSize($0) }),
                            in: ControlLayout.joystickSizeRange, step: 8)
                } header: {
                    Text("Appearance")
                }
                Section {
                    Button("Reset to default layout", role: .destructive) { confirmReset = true }
                        .disabled(!controls.isCustom)
                } footer: {
                    Text(controls.isCustom ? "Using your saved layout." : "Using the default layout (Amethyst's).")
                }
            }
            .navigationTitle("Controls")
            .navigationDestination(isPresented: Binding(get: { newButton != nil }, set: { if !$0 { newButton = nil } })) {
                if let id = newButton { ControlButtonForm(id: id) }
            }
            .confirmationDialog("Reset all controls to the default layout?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset", role: .destructive) { controls.resetToDefault() }
            }
            .fullScreenCover(isPresented: $showEditor) { ControlsEditorView() }
        }
    }

    static func visibility(_ b: ControlButton) -> String {
        if b.inDrawer { return "in the More drawer" }
        switch (b.showInGame, b.showInMenu) {
        case (true, true): return "game and menus"
        case (true, false): return "in game"
        case (false, true): return "in menus"
        case (false, false): return "hidden"
        }
    }
}

// MARK: - One button

struct ControlButtonForm: View {
    @EnvironmentObject var controls: ControlsModel
    @Environment(\.dismiss) private var dismiss
    let id: UUID

    enum ActionKind: String, CaseIterable, Identifiable {
        case keys = "Keyboard keys", mouse = "Mouse button", special = "Special"
        var id: String { rawValue }
    }

    private var button: Binding<ControlButton> {
        Binding(
            get: { controls.button(id) ?? ControlButton(name: "", x: 0, y: 0) },
            set: { controls.update($0) }
        )
    }

    private var kind: Binding<ActionKind> {
        Binding(
            get: {
                let b = button.wrappedValue
                return b.special != .none ? .special : (b.mouse >= 0 ? .mouse : .keys)
            },
            set: { k in
                var b = button.wrappedValue
                switch k {
                case .keys: b.special = .none; b.mouse = -1
                case .mouse: b.special = .none; b.keys = []; b.mouse = max(b.mouse, 0)
                case .special: b.keys = []; b.mouse = -1; if b.special == .none { b.special = .runtimeMenu }
                }
                button.wrappedValue = b
            }
        )
    }

    private func keyBinding(_ i: Int) -> Binding<Int> {
        Binding(
            get: { let k = button.wrappedValue.keys; return i < k.count ? k[i] : 0 },
            set: { code in if i < button.wrappedValue.keys.count { button.wrappedValue.keys[i] = code } }
        )
    }

    var body: some View {
        Form {
            if controls.button(id) == nil {
                Text("This button was deleted.").foregroundStyle(.secondary)
            } else {
                Section("Name") {
                    TextField("Shown on the button", text: button.name)
                }
                Section {
                    Picker("Sends", selection: kind) {
                        ForEach(ActionKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    switch kind.wrappedValue {
                    case .keys:
                        ForEach(button.wrappedValue.keys.indices, id: \.self) { i in
                            Picker(i == 0 ? "Key" : "Key \(i + 1)", selection: keyBinding(i)) {
                                ForEach(ControlKeys.all) { Text($0.name).tag($0.code) }
                            }
                            .pickerStyle(.navigationLink)
                        }
                        .onDelete { button.wrappedValue.keys.remove(atOffsets: $0) }
                        if button.wrappedValue.keys.count < ControlButton.maxKeys {
                            Button {
                                button.wrappedValue.keys.append(ControlKeys.all.first { $0.name == "Q" }?.code ?? 81)
                            } label: {
                                Label(button.wrappedValue.keys.isEmpty ? "Choose a key" : "Add another key", systemImage: "plus")
                            }
                        }
                    case .mouse:
                        Picker("Button", selection: button.mouse) {
                            ForEach(ControlKeys.mouseButtons) { Text($0.name).tag($0.code) }
                        }
                    case .special:
                        Picker("Action", selection: button.special) {
                            ForEach(ControlSpecial.allCases.filter { $0 != .none }, id: \.self) { Text($0.title).tag($0) }
                        }
                    }
                } header: {
                    Text("Action")
                } footer: {
                    if kind.wrappedValue == .keys {
                        Text("Several keys are pressed together, e.g. Left Shift + E. Swipe a key to remove it.")
                    }
                }
                Section("Behaviour") {
                    Toggle("Toggle (tap to hold, tap again to release)", isOn: button.toggle)
                        .disabled(kind.wrappedValue == .special)
                    Toggle("Only in the More drawer", isOn: button.inDrawer)
                    if !button.wrappedValue.inDrawer {
                        Toggle("Show in game", isOn: button.showInGame)
                        Toggle("Show in menus", isOn: button.showInMenu)
                    }
                }
                Section("Size") {
                    Stepper("Width: \(Int(button.wrappedValue.width)) pt", value: button.width, in: 20...300, step: 4)
                    Stepper("Height: \(Int(button.wrappedValue.height)) pt", value: button.height, in: 20...300, step: 4)
                }
                Section {
                    Button("Delete button", role: .destructive) {
                        controls.delete(id)
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle(button.wrappedValue.name.isEmpty ? "Button" : button.wrappedValue.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - On-screen editor

struct ControlsEditorView: View {
    @EnvironmentObject var controls: ControlsModel
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable, Identifiable {
        case game = "In game", menu = "In menus", drawer = "Drawer open"
        var id: String { rawValue }
    }

    struct EditTarget: Identifiable { let id: UUID }

    @State private var mode: Mode = .game
    @State private var lastAdded: UUID?
    @State private var editing: EditTarget?
    @State private var dragID: UUID??          // .some(nil) = joystick
    @State private var dragOffset: CGSize = .zero

    private var visible: [ControlButton] {
        controls.layout.buttons.filter { b in
            switch mode {
            case .game: b.showInGame && !b.inDrawer
            case .menu: b.showInMenu && !b.inDrawer
            case .drawer: b.inDrawer || (b.special == .drawer && b.showInGame)
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(white: 0.22), Color(white: 0.1)], startPoint: .top, endPoint: .bottom)
                if W < H {
                    Text("Rotate your iPhone to landscape to edit the layout.")
                        .foregroundStyle(.white).padding()
                        .frame(width: W, height: H)
                } else {
                    // Toolbar underneath, so a control can never hide behind it.
                    toolbar.position(x: W / 2, y: H * 0.45)
                    if mode == .game { joystick(W: W, H: H) }
                    ForEach(visible) { b in chip(b, W: W, H: H) }
                }
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear { Self.requestOrientation(.landscape) }
        .onDisappear { Self.requestOrientation(.portrait) }
        .sheet(item: $editing) { target in
            NavigationStack {
                ControlButtonForm(id: target.id)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { editing = nil } } }
            }
            .environmentObject(controls)
        }
    }

    private func offset(for id: UUID?) -> CGSize { dragID == .some(id) ? dragOffset : .zero }

    private func drag(_ id: UUID?) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { v in dragID = .some(id); dragOffset = v.translation }
            .onEnded { v in
                controls.move(id, by: v.translation)
                dragID = nil
                dragOffset = .zero
            }
    }

    private func chip(_ b: ControlButton, W: CGFloat, H: CGFloat) -> some View {
        let o = offset(for: b.id)
        let highlighted = dragID == .some(b.id) || lastAdded == b.id
        return Text(b.name)
            .font(.system(size: 13, weight: .medium))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.5)
            .foregroundStyle(.white)
            .padding(4)
            .frame(width: b.width, height: b.height)
            .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: min(b.width, b.height) / 2))
            .opacity(controls.layout.opacity)
            .overlay(RoundedRectangle(cornerRadius: min(b.width, b.height) / 2)
                .stroke(highlighted ? Color.accentColor : Color.white.opacity(0.6), lineWidth: highlighted ? 2 : 1))
            .position(x: b.x * W + b.width / 2 + o.width, y: b.y * H + b.height / 2 + o.height)
            .onTapGesture { editing = EditTarget(id: b.id) }
            .gesture(drag(b.id))
    }

    private func joystick(W: CGFloat, H: CGFloat) -> some View {
        let j = controls.layout.joystick, o = offset(for: nil)
        return Circle()
            .fill(Color.black.opacity(0.3))
            .overlay(Circle().stroke(Color.white.opacity(0.6)))
            .overlay(Text("Joystick").font(.caption).foregroundStyle(.white.opacity(0.8)))
            .frame(width: j.size, height: j.size)
            .opacity(controls.layout.opacity)
            .position(x: j.x * W + j.size / 2 + o.width, y: j.y * H + j.size / 2 + o.height)
            .gesture(drag(nil))
    }

    private var toolbar: some View {
        VStack(spacing: 8) {
            Picker("Show", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 300)
            HStack(spacing: 12) {
                Button {
                    let id = controls.addButton(inGame: mode == .game, inMenu: mode == .menu, inDrawer: mode == .drawer)
                    lastAdded = id
                    editing = EditTarget(id: id)
                } label: { Label("Add", systemImage: "plus") }
                Button { dismiss() } label: { Label("Done", systemImage: "checkmark") }.bold()
            }
            .buttonStyle(.borderedProminent)
            Text("Drag to move · tap to edit").font(.caption2).foregroundStyle(.white.opacity(0.7))
        }
        .padding(10)
        .frame(maxWidth: ControlsModel.toolbarSize.width, maxHeight: ControlsModel.toolbarSize.height)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .environment(\.colorScheme, .dark)
    }

    static func requestOrientation(_ mask: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
            Logger.shared.warning("controls", "Orientation request failed: \(error)")
        }
    }
}
