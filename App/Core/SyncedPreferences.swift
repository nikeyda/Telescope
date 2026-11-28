import Foundation
import rootshellVNC

enum PreferenceValue: Codable, Sendable, Equatable {
    case flag(Bool)
    case number(Int)
    case speed(Double)
    case text(String)
}

/// Settings exchanged in the user-selected library folder. Authentication, trust and device permissions stay local.
enum SyncedPreference: String, CaseIterable {
    case list = "library.listLayout"
    case savedOrder = "library.savedOrder"
    case favoriteOrder = "library.favoriteOrder"
    case recentOrder = "library.recentOrder"
    case linkOrder = "library.linkOrder"
    case reconnect = "connection.reconnect"
    case sharedClipboard = "connection.sharedClipboard"
    case cursor = "connection.clientCursor"
    case speed = "pointer.speed"
    case pointerMode = "pointer.mode"
    case up = "gesture.upFingers"
    case down = "gesture.downFingers"
    case horizontal = "gesture.horizontalFingers"
    case holdDuration = "gesture.holdDuration"
    case keyRepeat = "keyboard.repeat"
    case keyDelay = "keyboard.delay"
    case keyInterval = "keyboard.interval"
    case style = "toolbar.style"
    case size = "toolbar.size"
    case buttons = "toolbar.buttons"
    case keyboardTrailing = "toolbar.keyboardTrailing"
    case phoneToolbarStyle = "toolbar.iPhone.style"
    case phoneToolbarSize = "toolbar.iPhone.size"
    case phoneToolbarButtons = "toolbar.iPhone.buttons"
    case phoneToolbarKeyboardTrailing = "toolbar.iPhone.keyboardTrailing"
    case padToolbarStyle = "toolbar.iPad.style"
    case padToolbarSize = "toolbar.iPad.size"
    case padToolbarButtons = "toolbar.iPad.buttons"
    case padToolbarKeyboardTrailing = "toolbar.iPad.keyboardTrailing"
    case twoFingerToggle = "toolbar.twoFingerToggle"
    case doubleTap = "pencil.doubleTap"
    case squeeze = "pencil.squeeze"

    static func snapshot(_ defaults: UserDefaults) -> [String: PreferenceValue] {
        Dictionary(uniqueKeysWithValues: allCases.compactMap { field in
            field.value(in: defaults).map { (field.rawValue, $0) }
        })
    }

    static func apply(_ values: [String: PreferenceValue], to defaults: UserDefaults) {
        for field in allCases {
            let wanted = values[field.rawValue]
            if let wanted, !field.accepts(wanted) { continue }
            guard wanted != field.value(in: defaults) else { continue }
            switch wanted {
            case .flag(let selected): defaults.set(selected, forKey: field.rawValue)
            case .number(let count): defaults.set(count, forKey: field.rawValue)
            case .speed(let speed): defaults.set(speed, forKey: field.rawValue)
            case .text(let text): defaults.set(text, forKey: field.rawValue)
            case nil: defaults.removeObject(forKey: field.rawValue)
            }
        }
    }

    func accepts(_ value: PreferenceValue) -> Bool {
        switch (self, value) {
        case (.list, .flag), (.reconnect, .flag), (.sharedClipboard, .flag), (.cursor, .flag), (.keyboardTrailing, .flag),
             (.phoneToolbarKeyboardTrailing, .flag), (.padToolbarKeyboardTrailing, .flag),
             (.twoFingerToggle, .flag), (.keyRepeat, .flag):
            true
        case (.speed, .speed(let value)): (0.5...3).contains(value)
        case (.pointerMode, .text(let value)): RemotePointerMode(rawValue: value) != nil
        case (.holdDuration, .speed(let value)): RemoteTouchGestureConfiguration.holdDurationRange.contains(value)
        case (.keyDelay, .speed(let value)): VNCKeyRepeat.delayRange.contains(value)
        case (.keyInterval, .speed(let value)): VNCKeyRepeat.intervalRange.contains(value)
        case (.up, .number(let n)), (.down, .number(let n)), (.horizontal, .number(let n)): [0, 3, 4].contains(n)
        case (.style, .text(let text)), (.phoneToolbarStyle, .text(let text)), (.padToolbarStyle, .text(let text)):
            ["docked", "floating", "carousel"].contains(text)
        case (.savedOrder, .text(let text)), (.favoriteOrder, .text(let text)), (.linkOrder, .text(let text)): ComputerOrder(rawValue: text) != nil
        case (.recentOrder, .text(let text)): ComputerOrder(rawValue: text).map { $0 != .manual } == true
        case (.size, .text(let text)), (.phoneToolbarSize, .text(let text)), (.padToolbarSize, .text(let text)):
            ["small", "standard", "large", "extraLarge"].contains(text)
        case (.doubleTap, .text(let text)), (.squeeze, .text(let text)):
            RemotePencilAction(rawValue: text) != nil
        case (.buttons, .text), (.phoneToolbarButtons, .text), (.padToolbarButtons, .text): true
        default: false
        }
    }

    private func value(in defaults: UserDefaults) -> PreferenceValue? {
        guard defaults.object(forKey: rawValue) != nil else { return nil }
        let result: PreferenceValue?
        switch self {
        case .list, .reconnect, .sharedClipboard, .cursor, .keyboardTrailing, .phoneToolbarKeyboardTrailing, .padToolbarKeyboardTrailing,
                .twoFingerToggle, .keyRepeat: result = .flag(defaults.bool(forKey: rawValue))
        case .speed, .holdDuration, .keyDelay, .keyInterval: result = .speed(defaults.double(forKey: rawValue))
        case .up, .down, .horizontal: result = .number(defaults.integer(forKey: rawValue))
        case .style, .size, .buttons, .phoneToolbarStyle, .phoneToolbarSize, .phoneToolbarButtons,
                .padToolbarStyle, .padToolbarSize, .padToolbarButtons,
                .doubleTap, .squeeze, .savedOrder, .favoriteOrder, .recentOrder, .linkOrder, .pointerMode:
            result = defaults.string(forKey: rawValue).map(PreferenceValue.text)
        }
        return result.flatMap { accepts($0) ? $0 : nil }
    }
}
