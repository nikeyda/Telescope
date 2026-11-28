#if !targetEnvironment(macCatalyst)
import SwiftUI
import rootshellVNC

struct RepeatKeyButton: UIViewRepresentable {
    let symbol: String
    let title: String
    let points: CGFloat
    let identifier: String
    let timing: VNCKeyRepeat
    let actionForPress: () -> () -> Void

    func makeUIView(context: Context) -> Control {
        let control = Control(type: .system)
        control.addTarget(control, action: #selector(Control.beginHold), for: [.touchDown, .touchDragEnter])
        control.addTarget(control, action: #selector(Control.activate), for: .primaryActionTriggered)
        control.addTarget(control, action: #selector(Control.cancelHold), for: [.touchCancel, .touchUpOutside, .touchDragExit])
        NotificationCenter.default.addObserver(control, selector: #selector(Control.cancelForFocusChange(_:)),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        return control
    }

    func updateUIView(_ control: Control, context: Context) {
        control.isEnabled = context.environment.isEnabled
        if !control.isEnabled { control.cancelHold() }
        control.actionForPress = actionForPress
        control.timing = timing
        control.accessibilityLabel = title
        control.accessibilityIdentifier = identifier
        control.tintColor = .label
        let config = UIImage.SymbolConfiguration(pointSize: points, weight: .medium)
        control.setImage(UIImage(systemName: symbol, withConfiguration: config), for: .normal)
    }

    static func dismantleUIView(_ control: Control, coordinator: ()) { control.cancelHold() }

    final class Control: UIButton {
        var actionForPress: (() -> () -> Void)?
        var timing = VNCKeyRepeat() { didSet { if timing != oldValue { cancelHold() } } }
        private var action: (() -> Void)?
        private var repeating: Task<Void, Never>?
        private var sent = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            cancelHold()
            let notifications = NotificationCenter.default
            notifications.removeObserver(self, name: UIWindow.didResignKeyNotification, object: nil)
            notifications.removeObserver(self, name: UIScene.willDeactivateNotification, object: nil)
            guard let window else { return }
            notifications.addObserver(self, selector: #selector(cancelForFocusChange(_:)),
                                      name: UIWindow.didResignKeyNotification, object: window)
            if let scene = window.windowScene {
                notifications.addObserver(self, selector: #selector(cancelForFocusChange(_:)),
                                          name: UIScene.willDeactivateNotification, object: scene)
            }
        }

        @objc func cancelForFocusChange(_ notification: Notification) {
            cancelHold()
        }

        @objc func beginHold() {
            cancelHold()
            action = actionForPress?()
            guard timing.enabled else { return }
            let timing = timing
            repeating = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(timing.delay))
                    while let self, !Task.isCancelled, self.action != nil {
                        self.sent = true
                        self.action?()
                        try await Task.sleep(for: .seconds(timing.interval))
                    }
                } catch {}
            }
        }

        @objc func activate() {
            if !sent { (action ?? actionForPress?())?() }
            cancelHold()
        }

        @objc func cancelHold() {
            repeating?.cancel()
            repeating = nil
            action = nil
            sent = false
        }
    }
}
#endif
