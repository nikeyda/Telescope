#if !targetEnvironment(macCatalyst)
import SwiftUI
import rootshellVNC

enum DeskToolbarStyle: String, CaseIterable {
    case docked, floating, carousel

    var title: String {
        switch self {
        case .docked: "已停靠"
        case .floating: "浮动"
        case .carousel: "轮播"
        }
    }
}

enum DeskToolbarSize: String, CaseIterable {
    case small, standard, large, extraLarge

    var title: String {
        switch self {
        case .small: "小"
        case .standard: "默认"
        case .large: "大"
        case .extraLarge: "特大"
        }
    }

    var points: CGFloat {
        switch self {
        case .small: 44
        case .standard: 48
        case .large: 54
        case .extraLarge: 62
        }
    }

    var buttonStyle: VNCHUDButtonStyle {
        VNCHUDButtonStyle(size: CGSize(width: points, height: points), symbolPointSize: points * 0.38)
    }
}

enum DeskToolbarButton: String, CaseIterable {
    case escape, tab, shift, control, option, command, fn, arrows, home, end, pageUp, pageDown, functions, edit, shortcuts, password, spacer, dictation, screenshot
    case switchApp, spotlight, missionControl
    case enter, up, down, left, right
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12

    var functionNumber: Int? { rawValue.first == "f" ? Int(rawValue.dropFirst()) : nil }
    var supportsRepeat: Bool {
        switch self {
        case .tab, .enter, .up, .down, .left, .right, .pageUp, .pageDown: true
        default: false
        }
    }

    static let standard = "escape,tab,dictation,shift,control,option,command,arrows,edit,functions,shortcuts"
    var available: Bool {
        if #available(iOS 26, *) { return true }
        return self != .dictation
    }
    static func buttons(in stored: String) -> [Self] {
        stored.split(separator: ",").compactMap { Self(rawValue: String($0)) }.filter(\.available)
    }

    var title: String {
        switch self {
        case .escape: "Escape"
        case .tab: "Tab"
        case .shift: "Shift"
        case .control: "Control"
        case .option: "Option"
        case .command: "Command"
        case .fn: "Fn"
        case .arrows: "方向键"
        case .home: "Home"
        case .end: "End"
        case .pageUp: "Page Up"
        case .pageDown: "Page Down"
        case .functions: "功能键"
        case .edit: "编辑"
        case .shortcuts: "远程快捷命令"
        case .switchApp: RemoteMenuShortcut.switchApp.title
        case .spotlight: RemoteMenuShortcut.spotlight.title
        case .missionControl: RemoteCommand.missionControl.title
        case .password: "输入用户密码"
        case .spacer: "间距"
        case .dictation: "听写"
        case .screenshot: "保存屏幕快照"
        case .enter: "Return"
        case .up: "向上"
        case .down: "向下"
        case .left: "向左"
        case .right: "向右"
        case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12: rawValue.uppercased()
        }
    }

    var preferenceTitle: String {
        switch self {
        case .spotlight: "\(title)／\(RemoteMenuShortcut.spotlight.title(for: .other))"
        case .missionControl: "\(title)／任务视图"
        default: title
        }
    }

    func title(for platform: RemoteCommandPlatform) -> String {
        switch self {
        case .spotlight: RemoteMenuShortcut.spotlight.title(for: platform)
        case .missionControl where platform == .other: "任务视图"
        default: title
        }
    }

    var symbol: String {
        switch self {
        case .escape: "escape"
        case .tab: "arrow.right.to.line"
        case .shift: "shift"
        case .control: "control"
        case .option: "option"
        case .command: "command"
        case .fn: "globe"
        case .arrows: "arrow.up.and.down.and.arrow.left.and.right"
        case .home: "arrow.up.left"
        case .end: "arrow.down.right"
        case .pageUp: "arrow.up.to.line"
        case .pageDown: "arrow.down.to.line"
        case .functions: "function"
        case .edit: "scissors"
        case .shortcuts: "command.square"
        case .switchApp: "square.on.square"
        case .spotlight: "magnifyingglass"
        case .missionControl: "rectangle.3.group"
        case .password: "key"
        case .spacer: "arrow.left.and.right"
        case .dictation: "mic"
        case .screenshot: ConnectionActionSymbol.screenshot
        case .enter: "return"
        case .up: "arrow.up"
        case .down: "arrow.down"
        case .left: "arrow.left"
        case .right: "arrow.right"
        case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12: "function"
        }
    }

    var modifier: VNCKeyboardModifiers? {
        switch self {
        case .shift: .shift
        case .control: .control
        case .option: .option
        case .command: .command
        case .fn: .fn
        default: nil
        }
    }

    var keysym: UInt32? {
        switch self {
        case .escape: KeyboardInputHandler.keysymEscape
        case .tab: KeyboardInputHandler.keysymTab
        case .home: KeyboardInputHandler.keysymHome
        case .end: KeyboardInputHandler.keysymEnd
        case .pageUp: KeyboardInputHandler.keysymPageUp
        case .pageDown: KeyboardInputHandler.keysymPageDown
        case .enter: KeyboardInputHandler.keysymReturn
        case .up: KeyboardInputHandler.keysymUp
        case .down: KeyboardInputHandler.keysymDown
        case .left: KeyboardInputHandler.keysymLeft
        case .right: KeyboardInputHandler.keysymRight
        default: functionNumber.map { KeyboardInputHandler.keysymF1 + UInt32($0 - 1) }
        }
    }
}

@MainActor @Observable final class DeskToolbarState {
    let keyboard = VNCKeyboardCapture()
    var textDraft = ""
    var visible = true
    var expanded = true
    var anchor = CGPoint(x: 0.78, y: 0.75)
    var page = 0
    private(set) var locked: VNCKeyboardModifiers = []
    private(set) var dimmed = false
    @ObservationIgnored private var lastModifier: VNCKeyboardModifiers?
    @ObservationIgnored private var lastPress = ContinuousClock.now
    @ObservationIgnored private var lastActivity = ContinuousClock.now
    @ObservationIgnored private var restoreVisibility: Task<Void, Never>?

    init() {
        keyboard.onSupplementalModifiersConsumed = { [weak self] in self?.consume() }
    }

    func press(_ modifier: VNCKeyboardModifiers, now: ContinuousClock.Instant = .now) {
        if locked.contains(modifier) {
            locked.remove(modifier)
            keyboard.supplementalModifiers.remove(modifier)
            lastModifier = nil
        } else if lastModifier == modifier && now - lastPress <= .milliseconds(420) {
            locked.insert(modifier)
            keyboard.supplementalModifiers.insert(modifier)
            lastModifier = nil
        } else {
            if keyboard.supplementalModifiers.contains(modifier) { keyboard.supplementalModifiers.remove(modifier) }
            else { keyboard.supplementalModifiers.insert(modifier) }
            lastModifier = modifier
        }
        lastPress = now
    }

    func consume() {
        keyboard.supplementalModifiers = locked
        lastModifier = nil
    }

    func clearModifiers() {
        locked = []
        consume()
    }

    func reset() {
        clearModifiers()
        keyboard.softwareKeyboardRequested = false
        brighten()
    }

    func noteRemoteActivity() {
        lastActivity = .now
        guard !dimmed else { return }
        dimmed = true
        // One task follows the most recent input, even during a continuous pointer drag.
        restoreVisibility = Task { [weak self] in
            while let deadline = self?.lastActivity.advanced(by: .milliseconds(850)), .now < deadline {
                do { try await Task.sleep(until: deadline, clock: .continuous) }
                catch { return }
            }
            self?.dimmed = false
            self?.restoreVisibility = nil
        }
    }

    func brighten() {
        restoreVisibility?.cancel()
        restoreVisibility = nil
        dimmed = false
    }

    func handle(_ action: RemotePencilAction, at position: CGPoint, style: DeskToolbarStyle) {
        switch action {
        case .toggleToolbar:
            if !visible, style == .carousel { anchor = position }
            visible.toggle()
        case .toggleExpandedToolbar where style == .floating:
            visible = true
            expanded.toggle()
        default:
            break
        }
    }
}

private enum LaptopPalette {
    static let deck = Color(red: 0.057, green: 0.067, blue: 0.085)
    static let panel = Color(red: 0.106, green: 0.121, blue: 0.148)
    static let key = Color(red: 0.169, green: 0.191, blue: 0.226)
    static let accent = Color(red: 0.61, green: 0.77, blue: 1)
}

private enum LaptopKey {
    case character(Character, alternate: Character? = nil)
    case command(DeskToolbarButton)
    case capsLock, backspace, systemKeyboard, arrows, menu

    var width: CGFloat {
        switch self {
        case .character(" ", _): 5.4
        case .command(.escape), .command(.tab), .backspace, .systemKeyboard: 1.4
        case .capsLock: 1.7
        case .command(.enter), .command(.shift): 2
        case .arrows: 3
        default: 1
        }
    }

    private static func characters(_ keys: String) -> [Self] { keys.map { .character($0) } }

    static let rows: [[Self]] = [
        [.command(.escape), .character("`", alternate: "~")]
            + zip("1234567890-=", "!@#$%^&*()_+").map { .character($0, alternate: $1) }
            + [.backspace],
        [.command(.tab)] + characters("qwertyuiop")
            + [.character("[", alternate: "{"), .character("]", alternate: "}"), .character("\\", alternate: "|")],
        [.capsLock] + characters("asdfghjkl")
            + [.character(";", alternate: ":"), .character("'", alternate: "\""), .command(.enter)],
        [.command(.shift)] + characters("zxcvbnm")
            + [.character(",", alternate: "<"), .character(".", alternate: ">"), .character("/", alternate: "?"), .command(.shift)],
        [.systemKeyboard, .command(.control), .command(.option), .command(.command), .character(" "),
         .command(.command), .command(.option), .arrows, .menu]
    ]
}

struct InteractiveDesktop<SessionHeader: View>: View {
    let desktop: RemoteDesktopView
    let session: VNCSession
    let controls: VNCDesktopControls
    let bar: DeskToolbarState
    let deck: DeskSessionDeck?
    let showsSessionHeader: Bool
    let isWidePhone: Bool
    let holdDuration: TimeInterval
    let chooseMonitor: (VNCMonitorSelection) -> Void
    let startDictation: () -> Void
    let captureScreenshot: () -> Void
    let toggleFullScreen: () -> Void
    @ViewBuilder let sessionHeader: () -> SessionHeader
    private var toolbarProfile = ToolbarProfile(device: .current)
    private var style: DeskToolbarStyle { toolbarProfile.style }
    private var size: DeskToolbarSize { toolbarProfile.size }
    private var keyboardTrailing: Bool { toolbarProfile.keyboardTrailing }
    private var docksToLeading: Bool { isWidePhone && style == .docked && deck == nil }
    @AppStorage("toolbar.splitControls") private var splitControls = DeskSplitControls.sideBySide
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragStart: CGPoint?
    @State private var dockedKeyboardInset: CGFloat = 0
    @State private var coverPointerMode = RemotePointerMode.trackpad
    @State private var laptopSymbols = false
    @State private var showsDraft = false
    @FocusState private var draftFocused: Bool

    private let laptopKeySpacing: CGFloat = 6
    private let laptopPanelInset: CGFloat = 10
    private let wideLaptopKeyboardWidth: CGFloat = 540
    private var buttons: [DeskToolbarButton] { DeskToolbarButton.buttons(in: toolbarProfile.buttons) }
    private var laptopOutline: Color { .white.opacity(contrast == .increased ? 0.28 : 0.12) }
    private var keyboardVisible: Bool { deck != nil && dockedKeyboardInset >= 1 }
    private var usesDirectTouchInDeck: Bool {
        keyboardVisible || (deck?.isCover == true && coverPointerMode == .direct)
    }
    private var usesLaptopKeyboard: Bool {
        guard let deck, !deck.isCover else { return false }
        return splitControls == .laptop || deck.size.width - 28 < 314
    }

    private var keyboardHandler: KeyboardInputHandler {
        KeyboardInputHandler(sendKeyEvent: { session.sendKeyEvent(downFlag: $0, key: $1) },
                             usesAppleModifierConvention: { session.serverUsesAppleModifierConvention })
    }

    private var keyboardEdgeSwipe: ((CGPoint, UIView) -> Void)? {
        guard bar.keyboard.softwareKeyboardRequested, style == .docked || bar.expanded else { return nil }
        return { point, view in controls.movePointerToBottomEdge(at: point, in: view) }
    }

    var body: some View {
        let shortcutHeight = size.points + 12
        let coverHeader = deck?.isCover == true && showsSessionHeader
        VStack(spacing: 0) {
            if coverHeader {
                deckHeader.padding(.horizontal, 8).frame(height: 52)
            }
            viewer.frame(height: deck.map {
                let divider = keyboardVisible && $0.gap == 0
                    ? $0.size.height - dockedKeyboardInset
                    : $0.divider
                return max(1, divider - shortcutHeight - (coverHeader ? 52 : 0))
            })
            if let deck {
                Color.black.frame(height: shortcutHeight).overlay {
                    if keyboardVisible, !showsDraft {
                        laptopTypingShortcuts.padding(.horizontal, 10)
                    } else if usesLaptopKeyboard, showsSessionHeader, !showsDraft {
                        deckHeader.padding(.horizontal, 14)
                    }
                }
                Color.black.frame(height: deck.gap).accessibilityHidden(true)
                if deck.isCover {
                    coverControls
                } else {
                    laptopControls
                }
            }
        }
        .padding(deck?.coverMargins ?? EdgeInsets())
        .background {
            if deck != nil {
                VNCDockedKeyboardInsetReader { dockedKeyboardInset = $0 }
            }
        }
        .environment(\.colorScheme, deck == nil ? colorScheme : .dark)
        .sheet(isPresented: $showsDraft) { draftSheet }
        .onChange(of: toolbarProfile.buttons) { _, _ in bar.page = 0 }
        .onChange(of: session.isReadyForDesktopInput) { _, ready in
            if !ready { bar.clearModifiers() }
        }
        .onChange(of: deck == nil) { _, regular in
            if regular { dockedKeyboardInset = 0 }
        }
        .onDisappear { bar.reset() }
    }

    private var viewer: some View {
        desktop
            .separateTrackpad(deck != nil, usesDirectTouch: usesDirectTouchInDeck)
            .suspendingKeyboardCapture(showsDraft)
            .hidesHUD(deck != nil || !bar.visible)
            .onPencilToolbarAction { action, point in bar.handle(action, at: point, style: style) }
            .hudAccessory(isEnabled: style != .carousel && !docksToLeading, docksToBottom: style == .docked,
                          floatingMovement: bar.expanded ? .vertical : .free,
                          providesKeyboardButton: true,
                          onUpwardSwipe: keyboardEdgeSwipe,
                          buttonStyle: { _ in size.buttonStyle }) { width in
                if style == .docked || bar.expanded { strip(width: width) }
            } beside: { dimensions in
                if style == .floating {
                    Button { bar.expanded.toggle() } label: {
                        Image(systemName: bar.expanded ? "chevron.right" : "chevron.left")
                            .frame(width: dimensions.size.width, height: dimensions.size.height)
                    }
                    .accessibilityLabel(bar.expanded ? "折叠工具栏" : "展开工具栏")
                    .accessibilityIdentifier("toolbar.expand")
                    .contextMenu {
                        if !bar.expanded {
                            Button("显示键盘", systemImage: "keyboard") { bar.keyboard.softwareKeyboardRequested = true }
                            Menu("远程快捷命令", systemImage: DeskToolbarButton.shortcuts.symbol) { remoteCommands }
                            fileTransferAction
                            disconnectAction
                        }
                    }
                }
            }
            .leadingHUD(isEnabled: docksToLeading, buttonStyle: size.buttonStyle) { menu, height in
                leadingStrip(menu: menu, height: height)
            }
            .floatingHUD(isEnabled: style == .carousel) { menu, available in carousel(menu: menu, in: available) }
            .overlay(alignment: .bottomTrailing) {
                if deck == nil, !bar.visible {
                    Button { bar.visible = true } label: {
                        Image(systemName: "ellipsis.rectangle").frame(width: 44, height: 44)
                    }
                    .background(.regularMaterial, in: Circle())
                    .padding(8).accessibilityLabel("显示工具栏")
                    .accessibilityIdentifier("toolbar.show")
                }
            }
    }

    private var deckHeader: some View {
        sessionHeader()
            .tint(.primary)
            .background(LaptopPalette.panel, in: Capsule())
            .overlay { Capsule().strokeBorder(laptopOutline).allowsHitTesting(false) }
    }

    private var laptopControls: some View {
        VStack(spacing: 12) {
            if !keyboardVisible {
                if showsSessionHeader, !usesLaptopKeyboard { deckHeader }
                GeometryReader { geometry in
                    if usesLaptopKeyboard {
                        let width = geometry.size.width
                        let wide = width >= wideLaptopKeyboardWidth
                        let keyHeight = (geometry.size.height * 0.49 - 28) / 5
                        VStack(spacing: 6) {
                            laptopKeyboard(width: width, keyHeight: min(wide ? 36 : 38, max(28, keyHeight)))
                            laptopTrackpad
                        }
                    } else {
                        let keyPanelMinimum = 4 * 44 + 3 * laptopKeySpacing + 2 * laptopPanelInset
                        let keypadWidth = max(keyPanelMinimum, (geometry.size.width - 12) * 0.46)
                        let keypadChrome = 44 + 3 * laptopKeySpacing + 2 * laptopPanelInset
                        let keyHeight = min(62, max(44, (geometry.size.height - keypadChrome) / 3))
                        HStack(alignment: .top, spacing: 12) {
                            laptopKeypad(width: keypadWidth, keyHeight: keyHeight)
                                .frame(width: keypadWidth)
                            laptopTrackpad.frame(maxWidth: .infinity)
                        }
                        .frame(height: 3 * keyHeight + keypadChrome)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(LaptopPalette.deck.ignoresSafeArea(.container, edges: .bottom))
    }

    private var coverControls: some View {
        VStack(spacing: 8) {
            if !keyboardVisible {
                HStack(spacing: 6) {
                    Picker("触控板", selection: $coverPointerMode) {
                        Text("触控板").tag(RemotePointerMode.trackpad)
                        Text("直接触控").tag(RemotePointerMode.direct)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("session.coverPointerMode")
                    Button {
                        bar.keyboard.softwareKeyboardRequested = false
                        showsDraft = true
                    } label: {
                        icon("square.and.pencil", using: .small)
                    }
                    .buttonStyle(LaptopButtonStyle())
                    .background(LaptopPalette.key, in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityLabel("发送文本")
                    .accessibilityIdentifier("session.coverDraft")
                    .disabled(!session.connectionState.isConnected)
                }
                if coverPointerMode == .trackpad {
                    laptopTypingShortcuts
                    laptopTrackpad
                } else {
                    GeometryReader { geometry in
                        laptopKeypad(width: geometry.size.width, keyHeight: 44)
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(LaptopPalette.deck.ignoresSafeArea(.container, edges: .bottom))
    }

    private var draftSheet: some View {
        @Bindable var bar = bar
        return NavigationStack {
            Form {
                TextField("发送文本", text: $bar.textDraft, axis: .vertical)
                    .lineLimit(3...7)
                    .focused($draftFocused)
                    .accessibilityIdentifier("session.draftText")
            }
            .navigationTitle("发送文本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showsDraft = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        guard session.isReadyForDesktopInput, !bar.textDraft.isEmpty else { return }
                        bar.keyboard.noteExternalInput()
                        keyboardHandler.typeText(bar.textDraft)
                        bar.consume()
                        bar.textDraft = ""
                        showsDraft = false
                    } label: {
                        Label("发送", systemImage: "paperplane")
                    }
                    .disabled(!session.isReadyForDesktopInput || bar.textDraft.isEmpty)
                    .accessibilityIdentifier("session.sendDraft")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .defaultFocus($draftFocused, true)
    }

    private func laptopKeyboard(width: CGFloat, keyHeight: CGFloat) -> some View {
        Group {
            if width >= wideLaptopKeyboardWidth {
                VStack(spacing: 3) {
                    ForEach(LaptopKey.rows.indices, id: \.self) { index in
                        laptopKeyRow(LaptopKey.rows[index], width: width - 12, height: keyHeight)
                    }
                }
            } else {
                compactLaptopKeyboard(width: width, keyHeight: keyHeight)
            }
        }
        .padding(6)
        .buttonStyle(LaptopButtonStyle())
        .background(LaptopPalette.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(laptopOutline).allowsHitTesting(false) }
        .disabled(!session.connectionState.isConnected)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session.laptopKeyboard")
    }

    private func laptopKeyRow(_ row: [LaptopKey], width: CGFloat, height: CGFloat) -> some View {
        let unit = (width - CGFloat(row.count - 1) * 3) / row.reduce(0) { $0 + $1.width }
        return HStack(spacing: 3) {
            ForEach(row.indices, id: \.self) { index in
                let key = row[index]
                laptopKey(key, height: height).frame(width: unit * key.width)
            }
        }
    }

    @ViewBuilder private func laptopKey(_ key: LaptopKey, height: CGFloat) -> some View {
        switch key {
        case let .character(base, alternate):
            let shifted = bar.keyboard.supplementalModifiers.contains(.shift)
            if base == " " {
                typingKey(systemImage: "space", label: "空格", height: height) {
                    send(KeyboardInputHandler.keysymForCharacter(base))
                }
            } else {
                let character = shifted ? alternate ?? Character(base.uppercased()) : base
                typingKey(String(shifted && alternate != nil ? base : character),
                          alternate: alternate.map { String($0) }, height: height) {
                    send(KeyboardInputHandler.keysymForCharacter(character))
                }
            }
        case .command(.escape):
            typingKey("Esc", height: height) { send(KeyboardInputHandler.keysymEscape) }
        case let .command(button):
            if button.modifier != nil {
                typingModifier(button, height: height)
            } else {
                laptopCommandKey(button, height: height)
            }
        case .capsLock:
            typingKey(systemImage: "capslock", label: "Caps Lock", height: height) {
                send(KeyboardInputHandler.keysymCapsLock)
            }
        case .backspace:
            typingKey(systemImage: "delete.left", label: "退格", height: height) {
                send(KeyboardInputHandler.keysymBackspace)
            }
        case .systemKeyboard:
            laptopSystemKeyboardKey(height: height)
        case .arrows:
            HStack(spacing: 2) {
                laptopCommandKey(.left, height: height)
                VStack(spacing: 2) {
                    laptopCommandKey(.up, height: (height - 2) / 2)
                    laptopCommandKey(.down, height: (height - 2) / 2)
                }
                .frame(maxWidth: .infinity)
                laptopCommandKey(.right, height: height)
            }
        case .menu:
            laptopSessionMenu(height: height)
        }
    }

    @ViewBuilder private func laptopCommandKey(_ button: DeskToolbarButton, height: CGFloat) -> some View {
        if let keysym = button.keysym {
            typingKey(systemImage: button.symbol, label: button.title, height: height) { send(keysym) }
        }
    }

    private func compactLaptopKeyboard(width: CGFloat, keyHeight: CGFloat) -> some View {
        let shifted = bar.keyboard.supplementalModifiers.contains(.shift)
        return VStack(spacing: 4) {
            HStack(spacing: 4) {
                typingKey("Esc", height: keyHeight) { send(KeyboardInputHandler.keysymEscape) }
                typingCharacters(shifted ? "!@#$%^&*()" : "1234567890", height: keyHeight)
            }
            HStack(spacing: 4) {
                typingKey(systemImage: "arrow.right.to.line", label: "Tab", height: keyHeight) {
                    send(KeyboardInputHandler.keysymTab)
                }
                typingCharacters(laptopSymbols ? "-=[]\\;',./" : shifted ? "QWERTYUIOP" : "qwertyuiop", height: keyHeight)
            }
            HStack(spacing: 4) {
                typingCharacters(laptopSymbols ? "_+{}|:\"<>?" : shifted ? "ASDFGHJKL" : "asdfghjkl", height: keyHeight)
                typingKey(systemImage: "delete.left", label: "退格", height: keyHeight) {
                    send(KeyboardInputHandler.keysymBackspace)
                }
            }
            HStack(spacing: 4) {
                typingModifier(.shift, height: keyHeight)
                typingCharacters(laptopSymbols ? "`~€£¥©®" : shifted ? "ZXCVBNM" : "zxcvbnm", height: keyHeight)
                typingKey(systemImage: "return", label: "Return", height: keyHeight) {
                    send(KeyboardInputHandler.keysymReturn)
                }
            }
            HStack(spacing: 4) {
                laptopSystemKeyboardKey(height: keyHeight)
                typingKey(laptopSymbols ? "ABC" : "#+=", height: keyHeight, active: laptopSymbols) {
                    laptopSymbols.toggle()
                }
                typingModifier(.control, height: keyHeight)
                typingModifier(.option, height: keyHeight)
                typingModifier(.command, height: keyHeight)
                typingKey(systemImage: "space", label: "空格", height: keyHeight) {
                    send(KeyboardInputHandler.keysymForCharacter(" "))
                }
                .frame(width: width * 0.30)
                laptopSessionMenu(height: keyHeight, includesArrows: true)
            }
        }
    }

    private func laptopSystemKeyboardKey(height: CGFloat) -> some View {
        typingKey(systemImage: "keyboard", label: "键盘", height: height, active: bar.keyboard.softwareKeyboardRequested) {
            toggleLaptopSystemKeyboard()
        }
        .accessibilityIdentifier("toolbar.keyboard")
    }

    private func typingCharacters(_ characters: String, height: CGFloat) -> some View {
        ForEach(Array(characters), id: \.self) { character in
            typingKey(String(character), height: height) { send(KeyboardInputHandler.keysymForCharacter(character)) }
        }
    }

    private func typingModifier(_ key: DeskToolbarButton, height: CGFloat) -> some View {
        let modifier = key.modifier ?? []
        let active = bar.keyboard.supplementalModifiers.contains(modifier)
        return typingKey(systemImage: key.symbol, label: key.title, height: height, active: active) {
            bar.press(modifier)
        }
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityValue(bar.locked.contains(modifier) ? "已锁定" : "")
        .accessibilityIdentifier("toolbar." + key.rawValue)
        .disabled(!session.isReadyForDesktopInput)
    }

    private func typingKey(
        _ title: String = "", systemImage: String? = nil, label: String? = nil, alternate: String? = nil,
        height: CGFloat, active: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if let systemImage { Image(systemName: systemImage) }
                else if let alternate {
                    VStack(spacing: 0) {
                        Text(verbatim: alternate).font(.system(size: 9)).foregroundStyle(.secondary)
                        Text(verbatim: title).font(.system(size: 12, weight: .medium))
                    }
                }
                else { Text(verbatim: title) }
            }
            .font(.system(size: height < 24 ? 10 : 14, weight: .medium))
            .foregroundStyle(active ? LaptopPalette.accent : Color.primary)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .contentShape(Rectangle())
        }
        .background(active ? LaptopPalette.accent.opacity(0.18) : LaptopPalette.key.opacity(0.72),
                    in: RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel(Text(label ?? title))
    }

    private func laptopKeypad(width: CGFloat, keyHeight: CGFloat) -> some View {
        let keyWidth = (width - 2 * laptopPanelInset - 3 * laptopKeySpacing) / 4
        let keyFrame = CGSize(width: max(1, keyWidth), height: keyHeight)
        return VStack(spacing: laptopKeySpacing) {
            Grid(horizontalSpacing: laptopKeySpacing, verticalSpacing: laptopKeySpacing) {
                GridRow {
                    laptopKey(.escape, frame: keyFrame)
                    laptopKey(.tab, frame: keyFrame)
                    laptopKey(.enter, frame: keyFrame)
                    Button { send(KeyboardInputHandler.keysymBackspace) } label: {
                        icon("delete.left", using: .small, keyFrame: keyFrame)
                    }
                    .accessibilityLabel("退格")
                    .accessibilityIdentifier("toolbar.backspace")
                    .background(LaptopPalette.key, in: RoundedRectangle(cornerRadius: 9))
                }
                GridRow {
                    ForEach([DeskToolbarButton.shift, .control, .option, .command], id: \.self) {
                        laptopKey($0, frame: keyFrame)
                    }
                }
                GridRow {
                    ForEach([DeskToolbarButton.left, .up, .down, .right], id: \.self) {
                        laptopKey($0, frame: keyFrame)
                    }
                }
            }
            HStack(spacing: laptopKeySpacing) {
                laptopKeyboardButton(compact: false)
                laptopSessionMenu()
            }
        }
        .padding(laptopPanelInset)
        .buttonStyle(LaptopButtonStyle())
        .background(LaptopPalette.panel, in: RoundedRectangle(cornerRadius: 17))
        .overlay { RoundedRectangle(cornerRadius: 17).strokeBorder(laptopOutline).allowsHitTesting(false) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session.splitKeypad")
    }

    private func laptopKey(_ button: DeskToolbarButton, frame: CGSize) -> some View {
        let active = button.modifier.map { bar.keyboard.supplementalModifiers.contains($0) } ?? false
        return commandButton(button, using: .small, keyFrame: frame)
            .background(active ? LaptopPalette.accent.opacity(0.18) : LaptopPalette.key,
                        in: RoundedRectangle(cornerRadius: 9))
    }

    private func laptopKeyboardButton(compact: Bool) -> some View {
        let requested = bar.keyboard.softwareKeyboardRequested
        return Button(action: toggleLaptopSystemKeyboard) {
            if compact {
                icon(requested ? "keyboard.chevron.compact.down" : "keyboard", active: requested)
            } else {
                Label("键盘", systemImage: "keyboard")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(LaptopPalette.accent)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
        }
        .background(LaptopPalette.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityLabel("键盘")
        .accessibilityIdentifier("toolbar.keyboard")
        .accessibilityAddTraits(requested ? .isSelected : [])
    }

    private func toggleLaptopSystemKeyboard() {
        if !bar.keyboard.softwareKeyboardRequested { bar.keyboard.capture() }
        bar.keyboard.softwareKeyboardRequested.toggle()
    }

    private var laptopTypingShortcuts: some View {
        let modifiers: [DeskToolbarButton] = [.shift, .control, .option, .command] + (buttons.contains(.fn) ? [.fn] : [])
        let keySections: [[DeskToolbarButton]] = [[.escape, .tab], modifiers,
                                                  [.left, .up, .down, .right, .enter]]
        return HStack(spacing: 3) {
            laptopKeyboardButton(compact: true)
            ScrollView(.horizontal) {
                HStack(spacing: 3) {
                    ForEach(keySections.indices, id: \.self) { index in
                        if index > 0 { Rectangle().fill(laptopOutline).frame(width: 1, height: 20) }
                        HStack(spacing: 0) {
                            ForEach(keySections[index], id: \.self) {
                                commandButton($0, using: .small)
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            laptopSessionMenu()
        }
        .frame(maxWidth: CGFloat(keySections.joined().count) * DeskToolbarSize.small.points + size.points + 64)
        .padding(4)
        .buttonStyle(LaptopButtonStyle())
        .background(LaptopPalette.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(laptopOutline).allowsHitTesting(false) }
    }

    private func laptopSessionMenu(height: CGFloat = 44, includesArrows: Bool = false) -> some View {
        let pinned = buttons.filter { $0 == .switchApp || $0 == .spotlight || $0 == .missionControl }
        return Menu {
            if deck?.isCover == false {
                Picker("上下分屏", selection: $splitControls) {
                    ForEach(DeskSplitControls.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Divider()
            }
            if includesArrows {
                Menu("方向键", systemImage: DeskToolbarButton.arrows.symbol) {
                    ForEach([DeskToolbarButton.left, .up, .down, .right], id: \.self) { arrow in
                        if let key = arrow.keysym {
                            Button(arrow.title, systemImage: arrow.symbol) { send(key) }
                        }
                    }
                }
            }
            if !pinned.isEmpty {
                ForEach(pinned, id: \.self) { button in
                    Button(button.title(for: keyboardHandler.commandPlatform), systemImage: button.symbol) {
                        sendPinnedCommand(button)
                    }
                    .disabled(!session.isReadyForDesktopInput)
                }
                Divider()
            }
            remoteCommands
            Divider()
            fileTransferAction
            Button("切换全屏幕", systemImage: ConnectionActionSymbol.fullScreen, action: toggleFullScreen)
            disconnectAction
        } label: {
            icon("ellipsis.circle", using: .small, keyFrame: CGSize(width: 44, height: height))
        }
        .accessibilityLabel("会话操作")
        .accessibilityIdentifier("session.splitCommands")
    }

    private var fileTransferAction: some View {
        Button("文件传输", systemImage: ConnectionActionSymbol.transfers) { controls.toggleFileTransfers() }
    }

    private var disconnectAction: some View {
        Button(role: .destructive) {
            session.requestUserDisconnect()
        } label: {
            Label("断开连接", systemImage: ConnectionActionSymbol.disconnect)
        }
    }

    private var laptopTrackpad: some View {
        VStack(spacing: 0) {
            VNCTrackpadSurface(controls: controls, holdDuration: holdDuration)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    Label("触控板", systemImage: "trackpad")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("触控板")
                .accessibilityIdentifier("session.laptopTrackpad")

            Rectangle().fill(laptopOutline).frame(height: 1).accessibilityHidden(true)
            HStack(spacing: 0) {
                laptopClickButton("左键", button: .left)
                Rectangle().fill(laptopOutline).frame(width: 1, height: 20).accessibilityHidden(true)
                laptopClickButton("右键", button: .right)
            }
            .background(LaptopPalette.key.opacity(0.55))
        }
        .background(LaptopPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 17))
        .overlay { RoundedRectangle(cornerRadius: 17).strokeBorder(laptopOutline).allowsHitTesting(false) }
        .disabled(!session.connectionState.isConnected)
    }

    private func laptopClickButton(_ title: LocalizedStringKey, button: RemotePointerButton) -> some View {
        Button {
            controls.clickTrackpad(button)
        } label: {
            Text(title)
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(LaptopButtonStyle())
        .accessibilityIdentifier(button == .left ? "session.trackpad.leftClick" : "session.trackpad.rightClick")
    }

    private func strip(width: CGFloat) -> some View {
        let trailingWidth = size.points * (style == .floating ? 2 : 1)
        return HStack(spacing: 0) {
            if !keyboardTrailing { keyboardButton }
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Array(buttons.enumerated()), id: \.offset) { _, button in commandButton(button) }
                }
            }
            .scrollIndicators(.hidden)
            if keyboardTrailing { keyboardButton }
            Color.clear.frame(width: trailingWidth).allowsHitTesting(false)
        }
        .frame(width: min(width, max(trailingWidth + size.points, size.points * CGFloat(buttons.count + 1) + trailingWidth)),
               height: size.points)
    }

    private func leadingStrip(menu: AnyView, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            if !keyboardTrailing { keyboardButton }
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(Array(buttons.enumerated()), id: \.offset) { _, button in commandButton(button) }
                }
            }
            .scrollIndicators(.hidden)
            .frame(height: min(size.points * CGFloat(buttons.count), max(0, height - 2 * size.points)))
            if keyboardTrailing { keyboardButton }
            menu
        }
        .frame(width: size.points)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toolbar.leadingDock")
    }

    private var keyboardButton: some View {
        Button { bar.keyboard.softwareKeyboardRequested.toggle() } label: { icon("keyboard", active: bar.keyboard.softwareKeyboardRequested) }
            .accessibilityLabel("键盘").accessibilityIdentifier("toolbar.keyboard")
            .accessibilityAddTraits(bar.keyboard.softwareKeyboardRequested ? .isSelected : [])
    }

    @ViewBuilder private func commandButton(_ button: DeskToolbarButton, using keySize: DeskToolbarSize? = nil,
                                            keyFrame: CGSize? = nil) -> some View {
        let size = keySize ?? self.size
        if let modifier = button.modifier {
            Button { bar.press(modifier) } label: {
                icon(button.symbol, active: bar.keyboard.supplementalModifiers.contains(modifier),
                     using: size, keyFrame: keyFrame)
                    .overlay(alignment: .bottom) {
                        if bar.locked.contains(modifier) { Capsule().frame(width: 15, height: 2).padding(.bottom, 5) }
                    }
            }
            .accessibilityLabel(button.title)
            .accessibilityValue(bar.locked.contains(modifier) ? "已锁定" : bar.keyboard.supplementalModifiers.contains(modifier) ? "已选中" : "")
            .accessibilityIdentifier("toolbar." + button.rawValue)
            .disabled(!session.isReadyForDesktopInput)
        } else if let keysym = button.keysym, button.supportsRepeat {
            RepeatKeyButton(symbol: button.symbol, title: button.title, points: size.buttonStyle.symbolPointSize,
                            identifier: "toolbar." + button.rawValue, timing: bar.keyboard.keyRepeat) {
                let modifiers = bar.keyboard.supplementalModifiers
                return { send(keysym, additional: modifiers) }
            }
            .frame(width: keyFrame?.width ?? size.points, height: keyFrame?.height ?? size.points)
            .disabled(!session.isReadyForDesktopInput)
        } else if let keysym = button.keysym {
            Button { send(keysym) } label: {
                if button.functionNumber != nil {
                    Text(verbatim: button.title).font(.body.weight(.medium)).frame(width: size.points, height: size.points)
                } else if button == .escape, keySize != nil {
                    Text(verbatim: "Esc")
                        .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                        .frame(width: keyFrame?.width ?? size.points, height: keyFrame?.height ?? size.points)
                        .contentShape(Rectangle())
                } else { icon(button.symbol, using: size, keyFrame: keyFrame) }
            }
                .accessibilityLabel(button.title).accessibilityIdentifier("toolbar." + button.rawValue)
                .disabled(!session.isReadyForDesktopInput)
        } else if button == .dictation {
            Button(action: startDictation) { icon(button.symbol) }
                .disabled(!session.isReadyForDesktopInput)
                .accessibilityLabel(button.title).accessibilityIdentifier("toolbar.dictation")
        } else if button == .screenshot {
            Button(action: captureScreenshot) { icon(button.symbol) }
                .accessibilityLabel(button.title).accessibilityIdentifier("toolbar.screenshot")
        } else if button == .switchApp || button == .spotlight || button == .missionControl {
            Button { sendPinnedCommand(button) } label: { icon(button.symbol) }
                .disabled(!session.isReadyForDesktopInput)
                .accessibilityLabel(button.title(for: keyboardHandler.commandPlatform))
                .accessibilityIdentifier("toolbar." + button.rawValue)
        } else if button == .spacer {
            Spacer().frame(width: size.points / 2).accessibilityHidden(true)
        } else if button == .password {
            PasswordTypingButton(controls: controls) { icon(button.symbol) }
                .disabled(!session.isReadyForDesktopInput || !session.canSendLoginPassword)
                .accessibilityLabel(button.title)
                .accessibilityIdentifier("toolbar.password")
        } else {
            Menu {
                switch button {
                case .arrows:
                    Button("向上") { send(KeyboardInputHandler.keysymUp) }
                    Button("向下") { send(KeyboardInputHandler.keysymDown) }
                    Button("向左") { send(KeyboardInputHandler.keysymLeft) }
                    Button("向右") { send(KeyboardInputHandler.keysymRight) }
                case .functions:
                    ForEach(1...12, id: \.self) { number in
                        Button("F\(number)") { send(KeyboardInputHandler.keysymF1 + UInt32(number - 1)) }
                    }
                case .edit:
                    Button("撤销") { edit("z") }
                    Button("重做") { session.serverUsesAppleModifierConvention ? edit("z", shift: true) : edit("y") }
                    Button("剪切") { edit("x") }
                    Button("拷贝") { edit("c") }
                    Button("粘贴") { edit("v") }
                    Button("全选") { edit("a") }
                case .shortcuts:
                    remoteCommands
                default: EmptyView()
                }
            } label: { icon(button.symbol) }
            .accessibilityLabel(button.title).accessibilityIdentifier("toolbar." + button.rawValue)
        }
    }

    @ViewBuilder private var remoteCommands: some View {
        RemoteCommandsMenu(session: session, willSend: {
            bar.keyboard.noteExternalInput()
            bar.consume()
        })
        if session.selectableMonitorIDs.count > 1 {
            Divider()
            MonitorMenu(session: session, select: chooseMonitor)
        }
    }

    private func edit(_ character: Character, shift: Bool = false) {
        var modifier: VNCKeyboardModifiers = session.serverUsesAppleModifierConvention ? .command : .control
        if shift { modifier.insert(.shift) }
        send(KeyboardInputHandler.keysymForCharacter(character), additional: modifier)
    }

    private func send(_ key: UInt32, additional: VNCKeyboardModifiers = []) {
        guard session.isReadyForDesktopInput else { return }
        if bar.keyboard.sendToolbarKey(key, adding: additional) { bar.consume() }
    }

    private func sendPinnedCommand(_ button: DeskToolbarButton) {
        guard session.isReadyForDesktopInput else { return }
        bar.keyboard.noteExternalInput()
        bar.consume()
        switch button {
        case .switchApp: keyboardHandler.handleMenuShortcut(.switchApp)
        case .spotlight: keyboardHandler.handleMenuShortcut(.spotlight)
        case .missionControl: keyboardHandler.handleRemoteCommand(.missionControl)
        default: break
        }
    }

    private func icon(_ symbol: String, active: Bool = false, using keySize: DeskToolbarSize? = nil,
                      keyFrame: CGSize? = nil) -> some View {
        let size = keySize ?? self.size
        let activeColor = deck == nil ? Color.accentColor : LaptopPalette.accent
        return Image(systemName: symbol)
            .font(.system(size: size.buttonStyle.symbolPointSize, weight: active ? .bold : .medium))
            .foregroundStyle(active ? activeColor : Color.primary)
            .frame(width: keyFrame?.width ?? size.points, height: keyFrame?.height ?? size.points)
            .contentShape(Rectangle())
    }

    private func carousel(menu: AnyView, in available: CGSize) -> some View {
        let ordered: [DeskToolbarButton?] = buttons.filter { $0 != .spacer }.map(Optional.some)
        let entries = keyboardTrailing ? ordered + [nil] : [nil] + ordered
        let pages = max(1, (entries.count + 5) / 6)
        let first = min(bar.page, pages - 1) * 6
        let visible = Array(entries.dropFirst(first).prefix(6))
        let radius = min(size.points * 1.26, max(0, (min(available.width, available.height) - size.points) / 2))
        let diameter = radius * 2 + size.points
        let limit = diameter / 2
        let center = CGPoint(x: max(limit, min(available.width - limit, bar.anchor.x * available.width)),
                             y: max(limit, min(available.height - limit, bar.anchor.y * available.height)))
        return TouchOnlyToolbar { translation in
            guard let translation else { dragStart = nil; return }
            guard available.width > 0, available.height > 0 else { return }
            if dragStart == nil { bar.brighten(); dragStart = center }
            guard let start = dragStart else { return }
            bar.anchor = CGPoint(x: max(limit, min(available.width - limit, start.x + translation.width)) / available.width,
                                 y: max(limit, min(available.height - limit, start.y + translation.height)) / available.height)
        } content: {
            carouselButtons(menu: menu, visible: visible, pages: pages, radius: radius)
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .opacity(bar.dimmed && !reduceTransparency ? 0.32 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: bar.dimmed)
        .position(center)
    }

    private func carouselButtons(menu: AnyView, visible: [DeskToolbarButton?], pages: Int, radius: CGFloat) -> some View {
        ZStack {
            Circle().fill(.regularMaterial)
            menu
            ForEach(visible.indices, id: \.self) { index in
                let count = visible.count + (pages > 1 ? 1 : 0)
                let angle = CGFloat(index) * 2 * .pi / CGFloat(count) - .pi / 2
                Group { if let button = visible[index] { commandButton(button) } else { keyboardButton } }
                    .offset(x: cos(angle) * radius, y: sin(angle) * radius)
            }
            if pages > 1 {
                let angle = CGFloat(visible.count) * 2 * .pi / CGFloat(visible.count + 1) - .pi / 2
                Button { bar.page = (bar.page + 1) % pages } label: { icon("ellipsis") }
                    .accessibilityLabel("下一组按钮").accessibilityIdentifier("toolbar.next")
                    .offset(x: cos(angle) * radius, y: sin(angle) * radius)
            }
        }
    }
}

private struct LaptopButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.68 : 1)
    }
}

#endif
