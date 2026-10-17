import Foundation

/// An on-screen control layout: the buttons and joystick drawn over the game.
///
/// Stored as JSON in `controls/layout.json` and read by the app's GLFW bridge
/// (ZLGLFW.m) when Minecraft starts, so field names are part of that contract.
/// Positions are fractions of the landscape screen (top-left origin); sizes
/// are in points, as in Amethyst's control files.
public struct ControlLayout: Codable, Sendable, Equatable {
    public var version: Int
    public var buttons: [ControlButton]
    public var joystick: Joystick
    /// How visible the controls are (1 = Amethyst's look, lower = more see-through).
    public var opacity: Double

    public static let opacityRange: ClosedRange<Double> = 0.2...1.0
    public static let joystickSizeRange: ClosedRange<Double> = 120...300

    public init(version: Int = 1, buttons: [ControlButton], joystick: Joystick, opacity: Double = 1) {
        self.version = version
        self.buttons = buttons
        self.joystick = joystick
        self.opacity = opacity
    }

    /// Tolerates missing keys so older files keep loading after new fields are added.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        buttons = try c.decodeIfPresent([ControlButton].self, forKey: .buttons) ?? []
        joystick = try c.decodeIfPresent(Joystick.self, forKey: .joystick) ?? Joystick(x: 0.02326631, y: 0.5, size: 204.8)
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
    }

    public struct Joystick: Codable, Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var size: Double

        public init(x: Double, y: Double, size: Double) {
            self.x = x
            self.y = y
            self.size = size
        }
    }

    /// Every control kept fully on a `width` × `height` pt screen.
    public func clamped(width: Double, height: Double) -> ControlLayout {
        var copy = self
        copy.buttons = buttons.map { $0.clamped(width: width, height: height) }
        copy.opacity = Self.clamp(opacity, Self.opacityRange.lowerBound, Self.opacityRange.upperBound)
        copy.joystick.size = Self.clamp(joystick.size, Self.joystickSizeRange.lowerBound, min(Self.joystickSizeRange.upperBound, height))
        let s = copy.joystick.size
        copy.joystick.x = Self.clamp(joystick.x, 0, max(0, 1 - s / width))
        copy.joystick.y = Self.clamp(joystick.y, 0, max(0, 1 - s / height))
        return copy
    }

    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }

    /// A rectangle in points.
    public struct Rect: Sendable, Equatable {
        public var x, y, width, height: Double
        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }
        public func intersects(_ o: Rect) -> Bool {
            x < o.x + o.width && o.x < x + width && y < o.y + o.height && o.y < y + height
        }
    }

    /// Where a new `w` × `h` button can go without covering another control (or the
    /// `avoiding` areas): the free spot closest to the middle of the screen, as
    /// fractions. Falls back to the middle when the screen is full.
    public func freeSpot(width w: Double, height h: Double, screenWidth W: Double, screenHeight H: Double,
                         avoiding extra: [Rect] = []) -> (x: Double, y: Double) {
        let gap = 4.0
        var taken = buttons.filter { !$0.inDrawer }.map {
            Rect(x: $0.x * W - gap, y: $0.y * H - gap, width: $0.width + 2 * gap, height: $0.height + 2 * gap)
        }
        taken.append(Rect(x: joystick.x * W, y: joystick.y * H, width: joystick.size, height: joystick.size))
        taken += extra
        var best: (Double, Double)?
        var bestDistance = Double.infinity
        let step = 8.0
        for py in stride(from: 0, through: H - h, by: step) {
            for px in stride(from: 0, through: W - w, by: step) {
                let r = Rect(x: px, y: py, width: w, height: h)
                guard !taken.contains(where: { $0.intersects(r) }) else { continue }
                let d = hypot(px + w / 2 - W / 2, py + h / 2 - H / 2)
                if d < bestDistance { bestDistance = d; best = (px, py) }
            }
        }
        let (px, py) = best ?? ((W - w) / 2, (H - h) / 2)
        return (px / W, py / H)
    }
}

/// What a button does when pressed.
public enum ControlSpecial: String, Codable, Sendable, CaseIterable {
    case none
    case runtimeMenu
    case hideGUI
    case keyboard
    case virtualMouse
    case drawer

    public var title: String {
        switch self {
        case .none: "None"
        case .runtimeMenu: "Runtime menu"
        case .hideGUI: "Hide / show controls"
        case .keyboard: "Show iOS keyboard"
        case .virtualMouse: "Virtual mouse on/off"
        case .drawer: "Open / close drawer"
        }
    }
}

public struct ControlButton: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    /// GLFW key codes pressed together (Amethyst allows up to 4).
    public var keys: [Int]
    /// GLFW mouse button (0 left, 1 right, 2 middle), or -1.
    public var mouse: Int
    public var special: ControlSpecial
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    /// Press once to hold, press again to release.
    public var toggle: Bool
    public var showInGame: Bool
    public var showInMenu: Bool
    /// Only shown while the "More" drawer is open.
    public var inDrawer: Bool

    public static let maxKeys = 4

    public init(id: UUID = UUID(), name: String, keys: [Int] = [], mouse: Int = -1, special: ControlSpecial = .none,
                x: Double, y: Double, width: Double = 69.6, height: Double = 69.6, toggle: Bool = false,
                showInGame: Bool = true, showInMenu: Bool = false, inDrawer: Bool = false) {
        self.id = id
        self.name = name
        self.keys = keys
        self.mouse = mouse
        self.special = special
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.toggle = toggle
        self.showInGame = showInGame
        self.showInMenu = showInMenu
        self.inDrawer = inDrawer
    }

    /// Tolerates missing keys so older files keep loading after new fields are added.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        keys = try c.decodeIfPresent([Int].self, forKey: .keys) ?? []
        mouse = try c.decodeIfPresent(Int.self, forKey: .mouse) ?? -1
        special = (try? c.decodeIfPresent(ControlSpecial.self, forKey: .special)) ?? ControlSpecial.none
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0.5
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0.5
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 69.6
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 69.6
        toggle = try c.decodeIfPresent(Bool.self, forKey: .toggle) ?? false
        showInGame = try c.decodeIfPresent(Bool.self, forKey: .showInGame) ?? true
        showInMenu = try c.decodeIfPresent(Bool.self, forKey: .showInMenu) ?? false
        inDrawer = try c.decodeIfPresent(Bool.self, forKey: .inDrawer) ?? false
    }

    /// What the button sends, for lists: "Space", "Left Shift + E", "Right mouse", "Runtime menu".
    public var actionSummary: String {
        if special != .none { return special.title }
        var parts = keys.map(ControlKeys.name(for:))
        if let m = ControlKeys.mouseButtons.first(where: { $0.code == mouse }) { parts.append(m.name) }
        return parts.isEmpty ? "Nothing" : parts.joined(separator: " + ")
    }

    public func clamped(width W: Double, height H: Double) -> ControlButton {
        var b = self
        b.width = ControlLayout.clamp(width, 20, min(400, W))
        b.height = ControlLayout.clamp(height, 20, min(400, H))
        b.x = ControlLayout.clamp(x, 0, max(0, 1 - b.width / W))
        b.y = ControlLayout.clamp(y, 0, max(0, 1 - b.height / H))
        b.keys = Array(keys.prefix(Self.maxKeys))
        return b
    }
}

extension ControlLayout {
    /// Amethyst's default layout (its `generateAndSaveDefaultControl`, evaluated in
    /// points with button_scale 100 and margin 2 pt) for a landscape screen of
    /// `W` × `H` pt, with two changes made at the user's request: Inventory sits
    /// in the right-hand cluster, and Player List uses the free drawer slot
    /// (Amethyst's own expression puts it above the screen).
    public static func amethystDefault(width W: Double, height H: Double) -> ControlLayout {
        let m = 2.0, a = 69.6, b = 104.8, d = 96.0, dh = 40.0, dy = 0.0026855469
        func at(_ px: Double, _ py: Double) -> (Double, Double) { (px / W, py / H) }
        func button(_ name: String, keys: [Int] = [], mouse: Int = -1, special: ControlSpecial = .none,
                    _ p: (Double, Double), w: Double = a, h: Double = a, toggle: Bool = false,
                    game: Bool = true, menu: Bool = false, drawer: Bool = false) -> ControlButton {
            ControlButton(name: name, keys: keys, mouse: mouse, special: special, x: p.0, y: p.1, width: w, height: h,
                          toggle: toggle, showInGame: game, showInMenu: menu, inDrawer: drawer)
        }
        let k = ControlKeys.self
        let buttons = [
            // Right-hand cluster.
            button("Jump", keys: [k.space], at(0.94878495 * W - a, 0.31131014 * H + a + m)),
            button("Shift", keys: [k.leftShift], at(0.94878495 * W - a, 0.31131014 * H), toggle: true, menu: true),
            button("Sprint", keys: [k.leftControl], at(0.94878495 * W - 2 * a - m, 0.31131014 * H), toggle: true),
            button("Right Click", mouse: 1, at(0.8756154 * W - a, 0.8178498 * H - a), menu: true),
            button("Left Click", mouse: 0, at(0.7756397 * W - a, 0.8224885 * H - a), menu: true),
            button("Middle Click", mouse: 2, at(0.83548373 * W - a, 0.67798775 * H - a), menu: true),
            button("Inventory", keys: [k.e], at(0.8756154 * W + m, max(0.8178498 * H - a, 0.31131014 * H + 2 * a + 2 * m))),
            // Top row, packed from the right edge.
            button("Runtime Menu", special: .runtimeMenu, at(W - a - b - m, 0), w: b, h: 39.2, menu: true),
            button("Hide GUI", special: .hideGUI, at(W - a, 0), h: 40, menu: true),
            button("Pause", keys: [k.escape], at(W - a - 2 * b - 2 * m, 0), w: b, h: 39.2),
            button("Exit Menu", keys: [k.escape], at(W - a - 2 * b - 2 * m, 0), w: b, h: 39.2, game: false, menu: true),
            // "More" drawer (top-left) and its items.
            button("More", special: .drawer, at(0, 0), w: d, h: dh, menu: true),
            button("Third person", keys: [k.f5], at(d + m, dy * H), w: d, h: dh, menu: true, drawer: true),
            button("Debug Menu", keys: [k.f3], at(3 * (d + m), dy * H), w: d, h: dh, menu: true, drawer: true),
            button("Mouse Toggle", special: .virtualMouse, at(2 * (d + m), dy * H + dh + m), w: d, h: dh, menu: true, drawer: true),
            button("Chat", keys: [k.t], at(0, dy * H + dh + m), w: d, h: dh, menu: true, drawer: true),
            button("Keyboard", special: .keyboard, at(d + m, dy * H + dh + m), w: d, h: dh, menu: true, drawer: true),
            button("Player List", keys: [k.tab], at(2 * (d + m), dy * H), w: d, h: dh, toggle: true, menu: true, drawer: true),
        ]
        // Stable ids, so the default is the same value every time it is generated.
        let ided = buttons.enumerated().map { i, b in
            var b = b
            b.id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", i + 1))!
            return b
        }
        let stick = 204.8
        let joystick = Joystick(x: 0.02326631, y: (0.9753418 * H - stick) / H, size: stick)
        return ControlLayout(buttons: ided, joystick: joystick).clamped(width: W, height: H)
    }
}

/// Loads and saves the user's layout (controls/layout.json).
public struct ControlLayoutStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }
    public init(paths: AppPaths) { self.url = paths.controlsDir.appendingPathComponent("layout.json") }

    /// The saved layout, or nil when none was saved. A corrupt file is moved
    /// aside (layout.json.corrupt) and nil is returned.
    public func load(log: Logger = .shared) -> ControlLayout? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(ControlLayout.self, from: data)
        } catch {
            log.error("controls", "Corrupt control layout, using the default: \(error)")
            let aside = url.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: url, to: aside)
            return nil
        }
    }

    /// The saved layout, or the default for this screen.
    public func effective(width: Double, height: Double, log: Logger = .shared) -> ControlLayout {
        (load(log: log) ?? .amethystDefault(width: width, height: height)).clamped(width: width, height: height)
    }

    public func save(_ layout: ControlLayout) throws {
        try Self.write(layout, to: url)
    }

    /// Forgets the saved layout, so the default is used again.
    public func reset() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    public static func write(_ layout: ControlLayout, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(layout).write(to: url, options: .atomic)
    }
}

/// GLFW key codes that a control can send, with display names.
public enum ControlKeys {
    public struct Key: Sendable, Hashable, Identifiable {
        public let code: Int
        public let name: String
        public var id: Int { code }
    }

    public static let space = 32, escape = 256, tab = 258, leftShift = 340, leftControl = 341
    public static let e = 69, t = 84, f3 = 292, f5 = 294

    public static let mouseButtons: [Key] = [
        Key(code: 0, name: "Left mouse"), Key(code: 1, name: "Right mouse"), Key(code: 2, name: "Middle mouse"),
    ]

    /// Keyboard keys, in the order the picker shows them.
    public static let all: [Key] = {
        var keys: [Key] = []
        for c in 65...90 { keys.append(Key(code: c, name: String(UnicodeScalar(UInt8(c))))) }  // A-Z
        for c in 48...57 { keys.append(Key(code: c, name: String(UnicodeScalar(UInt8(c))))) }  // 0-9
        keys += [
            Key(code: 32, name: "Space"), Key(code: 256, name: "Escape"), Key(code: 257, name: "Enter"),
            Key(code: 258, name: "Tab"), Key(code: 259, name: "Backspace"), Key(code: 260, name: "Insert"),
            Key(code: 261, name: "Delete"), Key(code: 262, name: "Right arrow"), Key(code: 263, name: "Left arrow"),
            Key(code: 264, name: "Down arrow"), Key(code: 265, name: "Up arrow"), Key(code: 266, name: "Page up"),
            Key(code: 267, name: "Page down"), Key(code: 268, name: "Home"), Key(code: 269, name: "End"),
            Key(code: 280, name: "Caps lock"),
            Key(code: 340, name: "Left Shift"), Key(code: 341, name: "Left Control"), Key(code: 342, name: "Left Alt"),
            Key(code: 344, name: "Right Shift"), Key(code: 345, name: "Right Control"), Key(code: 346, name: "Right Alt"),
        ]
        for i in 1...12 { keys.append(Key(code: 289 + i, name: "F\(i)")) }
        keys += [
            Key(code: 39, name: "' (apostrophe)"), Key(code: 44, name: ", (comma)"), Key(code: 45, name: "- (minus)"),
            Key(code: 46, name: ". (period)"), Key(code: 47, name: "/ (slash)"), Key(code: 59, name: "; (semicolon)"),
            Key(code: 61, name: "= (equals)"), Key(code: 91, name: "[ (left bracket)"), Key(code: 92, name: "\\ (backslash)"),
            Key(code: 93, name: "] (right bracket)"), Key(code: 96, name: "` (grave)"),
        ]
        for i in 0...9 { keys.append(Key(code: 320 + i, name: "Keypad \(i)")) }
        return keys
    }()

    public static func name(for code: Int) -> String {
        all.first { $0.code == code }?.name ?? "Key \(code)"
    }
}
