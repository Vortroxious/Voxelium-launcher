import Foundation
import Testing
@testable import ZalithCore

@Suite struct ControlLayoutTests {
    // Landscape iPhone sizes in points (15 Pro Max, 16 Pro Max, 15 Pro, SE).
    static let screens: [(Double, Double)] = [(932, 430), (956, 440), (852, 393), (667, 375)]

    @Test(arguments: screens)
    func defaultFitsOnScreen(_ screen: (Double, Double)) {
        let (W, H) = screen
        let layout = ControlLayout.amethystDefault(width: W, height: H)
        #expect(layout.buttons.count == 18)
        for b in layout.buttons {
            #expect(b.x >= 0 && b.x * W + b.width <= W + 0.001, "\(b.name) x")
            #expect(b.y >= 0 && b.y * H + b.height <= H + 0.001, "\(b.name) y")
        }
        let j = layout.joystick
        #expect(j.x * W + j.size <= W && j.y * H + j.size <= H + 0.001)
    }

    @Test func defaultMatchesTheOverlayPositions() throws {
        // Same numbers the built-in ZLGLFW layout produced on the user's phone
        // (jvm.log, build 202610170113: Jump 815,205  Shift 815,134  Right Click 746,282).
        let (W, H) = (932.0, 430.0)
        let layout = ControlLayout.amethystDefault(width: W, height: H)
        func origin(_ name: String) throws -> (Int, Int) {
            let b = try #require(layout.buttons.first { $0.name == name })
            return (Int((b.x * W).rounded()), Int((b.y * H).rounded()))
        }
        #expect(try origin("Jump") == (815, 205))
        #expect(try origin("Shift") == (815, 134))
        #expect(try origin("Sprint") == (743, 134))
        #expect(try origin("Right Click") == (746, 282))
        #expect(try origin("Inventory") == (818, 282))
        #expect(try origin("Hide GUI") == (862, 0))
    }

    @Test func storeRoundTripAndReset() throws {
        let tmp = try TempDir()
        let store = ControlLayoutStore(paths: tmp.paths)
        #expect(store.load(log: Logger()) == nil)
        var layout = ControlLayout.amethystDefault(width: 932, height: 430)
        layout.buttons.append(ControlButton(name: "Drop", keys: [ControlKeys.all.first { $0.name == "Q" }!.code], x: 0.5, y: 0.5))
        try store.save(layout)
        #expect(store.load(log: Logger()) == layout)
        try store.reset()
        #expect(store.load(log: Logger()) == nil)
        #expect(store.effective(width: 932, height: 430, log: Logger()) == .amethystDefault(width: 932, height: 430))
    }

    @Test func corruptFileFallsBackToDefault() throws {
        let tmp = try TempDir()
        let store = ControlLayoutStore(paths: tmp.paths)
        try FileManager.default.createDirectory(at: tmp.paths.controlsDir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: store.url)
        #expect(store.load(log: Logger()) == nil)
        #expect(FileManager.default.fileExists(atPath: store.url.path + ".corrupt"))
    }

    @Test func toleratesMissingFields() throws {
        let json = #"{"version":1,"joystick":{"x":0,"y":0.5,"size":200},"buttons":[{"name":"Drop","keys":[81]}]}"#
        let layout = try JSONDecoder().decode(ControlLayout.self, from: Data(json.utf8))
        let b = try #require(layout.buttons.first)
        #expect(b.keys == [81] && b.mouse == -1 && b.special == .none && b.showInGame && !b.showInMenu)
        #expect(b.actionSummary == "Q")
    }

    @Test func olderFilesWithoutOpacityStillLoad() throws {
        let json = #"{"version":1,"joystick":{"x":0.9,"y":0.9,"size":900},"buttons":[]}"#
        let layout = try JSONDecoder().decode(ControlLayout.self, from: Data(json.utf8)).clamped(width: 932, height: 430)
        #expect(layout.opacity == 1)
        #expect(layout.joystick.size == 300)
        #expect(layout.joystick.x * 932 + 300 <= 932.001 && layout.joystick.y * 430 + 300 <= 430.001)
        var faint = layout
        faint.opacity = 0
        #expect(faint.clamped(width: 932, height: 430).opacity == ControlLayout.opacityRange.lowerBound)
    }

    @Test func clampingKeepsButtonsOnScreen() {
        let b = ControlButton(name: "X", keys: [1, 2, 3, 4, 5], x: 1.5, y: -1, width: 5, height: 900)
            .clamped(width: 932, height: 430)
        #expect(b.width == 20 && b.height == 400 && b.keys.count == ControlButton.maxKeys)
        #expect(b.x * 932 + b.width <= 932.001 && b.y == 0)
    }

    @Test func newButtonsGoToFreeSpots() {
        let (W, H) = (932.0, 430.0)
        let toolbar = ControlLayout.Rect(x: W / 2 - 170, y: H * 0.45 - 65, width: 340, height: 130)
        var layout = ControlLayout.amethystDefault(width: W, height: H)
        var added: [ControlLayout.Rect] = []
        for i in 0..<4 {
            let (x, y) = layout.freeSpot(width: 69.6, height: 69.6, screenWidth: W, screenHeight: H, avoiding: [toolbar])
            let r = ControlLayout.Rect(x: x * W, y: y * H, width: 69.6, height: 69.6)
            #expect(!r.intersects(toolbar), "button \(i) under the toolbar")
            #expect(r.x >= 0 && r.y >= 0 && r.x + r.width <= W && r.y + r.height <= H)
            for b in layout.buttons where !b.inDrawer {
                #expect(!r.intersects(.init(x: b.x * W, y: b.y * H, width: b.width, height: b.height)), "button \(i) covers \(b.name)")
            }
            added.append(r)
            layout.buttons.append(ControlButton(name: "New \(i)", x: x, y: y))
        }
        #expect(Set(added.map { "\($0.x),\($0.y)" }).count == 4)
    }

    @Test func keyTableIsUnique() {
        #expect(Set(ControlKeys.all.map(\.code)).count == ControlKeys.all.count)
        #expect(ControlKeys.name(for: 32) == "Space" && ControlKeys.name(for: 294) == "F5")
    }
}
