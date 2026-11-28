#if !targetEnvironment(macCatalyst)
import UIKit
import XCTest
@testable import rootshellVNC
@testable import DeskLink

@MainActor final class ToolbarTests: XCTestCase {
    func testDeviceProfilesInheritLegacyFieldsUntilEachDeviceEditsThem() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("floating", forKey: SyncedPreference.style.rawValue)
        defaults.set("extraLarge", forKey: SyncedPreference.size.rawValue)
        defaults.set("f12,spacer,tab", forKey: SyncedPreference.buttons.rawValue)
        defaults.set(true, forKey: SyncedPreference.keyboardTrailing.rawValue)

        for device in ToolbarProfileDevice.allCases {
            let profile = ToolbarProfile(device: device, store: defaults)
            XCTAssertEqual(profile.style, .floating)
            XCTAssertEqual(profile.size, .extraLarge)
            XCTAssertEqual(profile.buttons, "f12,spacer,tab")
            XCTAssertTrue(profile.keyboardTrailing)
        }
        XCTAssertNil(defaults.object(forKey: SyncedPreference.phoneToolbarStyle.rawValue))
        XCTAssertNil(defaults.object(forKey: SyncedPreference.padToolbarStyle.rawValue))

        let phone = ToolbarProfile(device: .iPhone, store: defaults)
        phone.style = .docked
        phone.size = .small
        phone.buttons = ""
        phone.keyboardTrailing = false
        let pad = ToolbarProfile(device: .iPad, store: defaults)
        pad.style = .carousel
        pad.buttons = "enter"
        defaults.set("large", forKey: SyncedPreference.size.rawValue)

        let reloadedPhone = ToolbarProfile(device: .iPhone, store: defaults)
        XCTAssertEqual(reloadedPhone.style, .docked)
        XCTAssertEqual(reloadedPhone.size, .small)
        XCTAssertEqual(reloadedPhone.buttons, "")
        XCTAssertFalse(reloadedPhone.keyboardTrailing)
        let reloadedPad = ToolbarProfile(device: .iPad, store: defaults)
        XCTAssertEqual(reloadedPad.style, .carousel)
        XCTAssertEqual(reloadedPad.size, .large)
        XCTAssertEqual(reloadedPad.buttons, "enter")
        XCTAssertTrue(reloadedPad.keyboardTrailing)
        XCTAssertEqual(defaults.string(forKey: SyncedPreference.style.rawValue), "floating")
    }

    func testHardwareRepeatTimingStopsOnReleaseAndCanBeDisabled() async throws {
        var wire = [Bool]()
        let input = HardwareKeyboardController(keyboardHandler: KeyboardInputHandler { down, _ in wire.append(down) })
        let symbol = KeyboardInputHandler.keysymTab
        input.keyRepeat = VNCKeyRepeat(enabled: false)
        XCTAssertTrue(input.press(usage: 0x2b, keysym: symbol))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(input.release(usage: 0x2b))
        XCTAssertEqual(wire, [true, false])
        wire.removeAll()
        input.keyRepeat = VNCKeyRepeat(delay: 0.15, interval: 0.05)
        XCTAssertTrue(input.press(usage: 0x2b, keysym: symbol))
        let limit = ContinuousClock.now + .seconds(2)
        while wire.count < 3, ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertGreaterThanOrEqual(wire.count, 3)
        XCTAssertTrue(input.release(usage: 0x2b))
        let released = wire
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(try XCTUnwrap(wire.last))
        XCTAssertEqual(wire, released)
        XCTAssertEqual(VNCKeyRepeat(delay: .nan, interval: -1), VNCKeyRepeat())
    }

    func testToolbarRepeatStopsWhenAnotherWindowBecomesKey() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.keyWindow
        let owner = UIWindow(windowScene: scene)
        let other = UIWindow(windowScene: scene)
        owner.rootViewController = UIViewController()
        other.rootViewController = UIViewController()
        let button = RepeatKeyButton.Control(type: .system)
        defer {
            button.cancelHold()
            owner.isHidden = true
            other.isHidden = true
            previous?.makeKey()
        }
        owner.rootViewController?.view.addSubview(button)
        owner.makeKeyAndVisible()
        XCTAssertTrue(owner.isKeyWindow)
        XCTAssertTrue(button.window === owner)
        var taps = 0
        button.actionForPress = { { taps += 1 } }
        button.timing = VNCKeyRepeat(delay: 0.15, interval: 0.05)
        button.beginHold()
        try await waitForToolbarRepeat { taps > 0 }

        let beforeUnrelatedWindow = taps
        NotificationCenter.default.post(name: UIWindow.didResignKeyNotification, object: other)
        try await waitForToolbarRepeat { taps > beforeUnrelatedWindow }
        other.makeKeyAndVisible()
        XCTAssertTrue(other.isKeyWindow)
        XCTAssertFalse(owner.isKeyWindow)
        let tapsAtFocusChange = taps
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(taps, tapsAtFocusChange, "The old window continued holding the remote key")

        owner.makeKey()
        button.beginHold()
        button.activate()
        XCTAssertEqual(taps, tapsAtFocusChange + 1, "A new short press should still reach the remote")
    }

    func testToolbarRepeatStopsWhenItsSceneDeactivatesOrTheButtonLeavesItsWindow() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.keyWindow
        let owner = UIWindow(windowScene: scene)
        owner.rootViewController = UIViewController()
        let button = RepeatKeyButton.Control(type: .system)
        defer {
            button.cancelHold()
            owner.isHidden = true
            previous?.makeKey()
        }
        owner.rootViewController?.view.addSubview(button)
        owner.makeKeyAndVisible()
        XCTAssertTrue(button.window === owner)
        var taps = 0
        button.actionForPress = { { taps += 1 } }
        button.timing = VNCKeyRepeat(delay: 0.15, interval: 0.05)
        button.beginHold()
        try await waitForToolbarRepeat { taps > 0 }
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
        let tapsAtDeactivation = taps
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(taps, tapsAtDeactivation, "The inactive scene continued holding the remote key")

        let beforeNewHold = taps
        button.beginHold()
        try await waitForToolbarRepeat { taps > beforeNewHold }
        button.removeFromSuperview()
        XCTAssertNil(button.window)
        let tapsAtRemoval = taps
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(taps, tapsAtRemoval, "The detached button continued holding the remote key")
    }

    private func waitForToolbarRepeat(_ received: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !received(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(15)) }
        XCTAssertTrue(received(), "The held toolbar key never started repeating")
    }

    func testIndividualFunctionKeysRetainTheirOrderAndMatchTheFunctionMenu() {
        let keys = DeskToolbarButton.buttons(in: "f12,left,enter,f1,f7")
        XCTAssertEqual(keys.map(\.title), ["F12", "向左", "Return", "F1", "F7"])
        XCTAssertEqual(keys.compactMap(\.keysym), [0xffc9, 0xff51, 0xff0d, 0xffbe, 0xffc4])
        XCTAssertEqual(keys.filter(\.supportsRepeat), [.left, .enter])
    }

    func testFnConvertsNavigationWithoutSendingAnExtraModifier() {
        XCTAssertEqual(DeskToolbarButton.buttons(in: "fn,left,up").first?.modifier, .fn)
        let pairs: [(UInt32, UInt32, UInt32)] = [
            (0xff08, 0xffff, 0x4c), (0xff51, 0xff50, 0x4a), (0xff53, 0xff57, 0x4d),
            (0xff52, 0xff55, 0x4b), (0xff54, 0xff56, 0x4e)
        ]
        var wire: [Int] = []
        let keyboard = KeyboardInputHandler { pressed, key in wire.append(pressed ? Int(key) : -Int(key)) }
        for (key, expected, usage) in pairs {
            wire.removeAll()
            XCTAssertTrue(keyboard.handleKeysymTap(key, supplementalModifiers: [.fn, .shift]))
            XCTAssertEqual(wire, [0xffe1, Int(expected), -Int(expected), -0xffe1])
            XCTAssertEqual(KeyboardInputHandler.functionEquivalent(for: key, modifiers: .fn)?.usage, usage)
            XCTAssertNil(KeyboardInputHandler.functionEquivalent(for: key, modifiers: .shift))
        }
        wire.removeAll()
        XCTAssertTrue(keyboard.handleKeyTap("a", supplementalModifiers: .fn))
        XCTAssertEqual(wire, [0x61, -0x61])
    }

    func testFnUsesTheSameOneShotAndLockBehaviorAsOtherToolbarModifiers() {
        let toolbar = DeskToolbarState()
        let start = ContinuousClock.now
        toolbar.press(.fn, now: start)
        XCTAssertTrue(toolbar.keyboard.supplementalModifiers.contains(.fn))
        toolbar.consume()
        XCTAssertFalse(toolbar.keyboard.supplementalModifiers.contains(.fn))
        toolbar.press(.fn, now: start.advanced(by: .seconds(1)))
        toolbar.press(.fn, now: start.advanced(by: .milliseconds(1100)))
        XCTAssertTrue(toolbar.locked.contains(.fn))
        toolbar.press(.shift, now: start.advanced(by: .seconds(2)))
        toolbar.consume()
        XCTAssertEqual(toolbar.keyboard.supplementalModifiers, .fn)
        toolbar.reset()
        XCTAssertTrue(toolbar.keyboard.supplementalModifiers.isEmpty)
    }

    func testFnPhysicalKeyDownAndUpUseTheSameRemotePosition() throws {
        struct Event: Equatable {
            let down: Bool
            let usage: UInt32
            let keysym: UInt32
        }
        var wire: [Event] = []
        let handler = KeyboardInputHandler(sendKeyEvent: { _, _ in XCTFail("Expected a physical key") },
            sendPhysicalKeyEvent: { wire.append(Event(down: $0, usage: $1, keysym: $2)) })
        let keyboard = HardwareKeyboardController(keyboardHandler: handler)
        let keys: [(UInt32, UInt32)] = [(0x2a, 0xff08), (0x50, 0xff51), (0x4f, 0xff53), (0x52, 0xff52), (0x51, 0xff54)]
        for (source, key) in keys {
            let target = try XCTUnwrap(KeyboardInputHandler.functionEquivalent(for: key, modifiers: .fn))
            wire.removeAll()
            XCTAssertTrue(keyboard.press(usage: source, keysym: target.keysym, sendingAs: target.usage))
            XCTAssertTrue(keyboard.release(usage: source))
            XCTAssertEqual(wire, [
                Event(down: true, usage: target.usage, keysym: target.keysym),
                Event(down: false, usage: target.usage, keysym: target.keysym),
            ])
        }
    }

    func testHoldDelayAndMomentumRoundTripOlderAndNewerSettings() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = SyncedPreference.holdDuration.rawValue
        XCTAssertNil(SyncedPreference.snapshot(defaults)[key])
        SyncedPreference.apply([key: .speed(0.75)], to: defaults)
        XCTAssertEqual(SyncedPreference.snapshot(defaults)[key], .speed(0.75))
        SyncedPreference.apply([key: .speed(2)], to: defaults)
        XCTAssertEqual(defaults.double(forKey: key), 0.75)
        var computer = Computer(endpoint: try Endpoint(address: "test.invalid"))
        let old = try LibraryArchive.read(LibraryArchive(computers: [computer]).encoded())
        XCTAssertNil(try XCTUnwrap(old.computers.first).momentumScrolling)
        computer.momentumScrolling = false
        let updated = try LibraryArchive.read(LibraryArchive(computers: [computer]).encoded())
        XCTAssertEqual(updated.computers.first?.momentumScrolling, false)
    }

    func testOneShotAndLockedModifiersAreConsumedIndependently() {
        let toolbar = DeskToolbarState()
        let start = ContinuousClock.now
        toolbar.press(.shift, now: start)
        toolbar.press(.shift, now: start + .milliseconds(200))
        toolbar.press(.control, now: start + .milliseconds(400))
        XCTAssertEqual(toolbar.keyboard.supplementalModifiers, [.shift, .control])
        toolbar.keyboard.onSupplementalModifiersConsumed?()
        XCTAssertEqual(toolbar.keyboard.supplementalModifiers, .shift)
        toolbar.press(.shift, now: start + .seconds(2))
        XCTAssertTrue(toolbar.keyboard.supplementalModifiers.isEmpty)
        toolbar.press(.command)
        toolbar.reset()
        XCTAssertTrue(toolbar.locked.isEmpty)
        XCTAssertTrue(toolbar.keyboard.supplementalModifiers.isEmpty)
    }

    func testPencilToolbarActionsRespectStyleAndTipPosition() {
        let toolbar = DeskToolbarState()
        let tip = CGPoint(x: 0.23, y: 0.66)
        toolbar.handle(.toggleExpandedToolbar, at: tip, style: .docked)
        XCTAssertTrue(toolbar.expanded)
        toolbar.handle(.toggleExpandedToolbar, at: tip, style: .floating)
        XCTAssertFalse(toolbar.expanded)
        toolbar.handle(.toggleToolbar, at: .zero, style: .carousel)
        XCTAssertFalse(toolbar.visible)
        toolbar.handle(.toggleToolbar, at: tip, style: .carousel)
        XCTAssertEqual(toolbar.anchor, tip)
        XCTAssertTrue(toolbar.visible)
        XCTAssertEqual(DeskToolbarButton.buttons(in: "tab,spacer,removed,spacer,arrows"), [.tab, .spacer, .spacer, .arrows])
    }

    #if !os(visionOS)
    func testPencilKeyboardActionsToggleOnlyTheActiveDesktopAndRespectSystemPreferences() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let other = UIWindow(windowScene: scene)
        defer {
            other.isHidden = true
            window.isHidden = true
            previous?.makeKey()
        }
        let keyboard = VNCKeyboardCapture(isCaptured: false)
        let input = RemoteInputUIView(
            touchHandler: TouchInputHandler(sendPointerEvent: { _, _, _ in XCTFail("The keyboard action must not click") }),
            keyboardHandler: KeyboardInputHandler(sendKeyEvent: { _, _ in XCTFail("The keyboard action must not send remote keys") }),
            keyboardCapture: keyboard, requestPasswordSend: {}, requestDictation: {}, toggleFullScreen: nil, disconnect: {})
        let host = UIViewController()
        window.rootViewController = host
        other.rootViewController = UIViewController()
        input.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        host.view.addSubview(input)
        window.makeKeyAndVisible()
        XCTAssertTrue(window.isKeyWindow)
        let tip = CGPoint(x: 20, y: 20)

        input.dispatchPencil(.toggleKeyboard, preference: .ignore, hover: tip)
        input.dispatchPencil(.toggleKeyboard, preference: .runSystemShortcut, hover: tip)
        input.dispatchPencil(.toggleKeyboard, preference: .switchEraser, hover: CGPoint(x: 101, y: 10))
        input.dispatchPencil(.toggleKeyboard, preference: .switchEraser, hover: nil)
        XCTAssertFalse(keyboard.softwareKeyboardRequested)
        XCTAssertFalse(keyboard.isCaptured)

        input.dispatchPencil(.toggleKeyboard, preference: .switchEraser, hover: tip)
        XCTAssertTrue(keyboard.softwareKeyboardRequested)
        XCTAssertTrue(keyboard.isCaptured)
        other.makeKeyAndVisible()
        XCTAssertFalse(window.isKeyWindow)
        input.dispatchPencil(.toggleKeyboard, preference: .switchEraser, hover: tip)
        XCTAssertTrue(keyboard.softwareKeyboardRequested)
        window.makeKey()
        input.dispatchPencil(.toggleKeyboard, preference: .switchEraser, hover: tip)
        XCTAssertFalse(keyboard.softwareKeyboardRequested)
    }
    #endif

    func testPencilKeyboardActionRoundTripsInBothSyncedGesturePreferences() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let action = PreferenceValue.text(RemotePencilAction.toggleKeyboard.rawValue)
        let doubleTap = SyncedPreference.doubleTap.rawValue
        let squeeze = SyncedPreference.squeeze.rawValue
        SyncedPreference.apply([doubleTap: action, squeeze: action], to: defaults)
        XCTAssertEqual(SyncedPreference.snapshot(defaults)[doubleTap], action)
        XCTAssertEqual(SyncedPreference.snapshot(defaults)[squeeze], action)
    }

    func testRemoteInputDimsCarouselUntilActivityEnds() async throws {
        let toolbar = DeskToolbarState()
        toolbar.noteRemoteActivity()
        XCTAssertTrue(toolbar.dimmed)
        try await Task.sleep(for: .milliseconds(500))
        toolbar.noteRemoteActivity()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(toolbar.dimmed)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(toolbar.dimmed)
        toolbar.noteRemoteActivity()
        toolbar.reset()
        XCTAssertFalse(toolbar.dimmed)
    }
}
#endif
