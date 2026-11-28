import Observation
import SwiftUI
import UIKit
import rootshellVNC

enum ConnectionActionSymbol {
    static let transfers = "arrow.up.arrow.down.circle"
    static let clipboard = "doc.on.clipboard"
    static let sendClipboard = "arrow.up.doc"
    static let receiveClipboard = "arrow.down.doc"
    static let screenshot = "camera.viewfinder"
    static let fullScreen = "arrow.up.left.and.arrow.down.right"
    static let exitFullScreen = "arrow.down.right.and.arrow.up.left"
    static let disconnect = "xmark.circle"
}

@MainActor @Observable
final class SessionPointerControl {
    var mode: RemotePointerMode

    init(mode: RemotePointerMode) { self.mode = mode }
}

struct SessionGesturePreferences: DynamicProperty {
    @AppStorage private var up: RemoteSwipeFingers
    @AppStorage private var down: RemoteSwipeFingers
    @AppStorage private var horizontal: RemoteSwipeFingers

    init(store: UserDefaults? = nil) {
        _up = AppStorage(wrappedValue: .three, SyncedPreference.up.rawValue, store: store)
        _down = AppStorage(wrappedValue: .three, SyncedPreference.down.rawValue, store: store)
        _horizontal = AppStorage(wrappedValue: .three, SyncedPreference.horizontal.rawValue, store: store)
    }

    func configuration(for computer: Computer, usesAppleModifiers: Bool) -> RemoteTouchGestureConfiguration {
        var gestures = RemoteTouchGestureConfiguration.standard
        gestures.scrollSpeed = computer.scrollSpeed(forMac: usesAppleModifiers)
        gestures.upFingers = up
        gestures.downFingers = down
        gestures.horizontalFingers = horizontal
        return gestures
    }
}

struct SessionScreen: View {
    let request: SessionRequest
    let library: ConnectionLibrary
    private let pasteboard: UIPasteboard
    private let preferences: UserDefaults
    @State private var sharesClipboard: Bool
    let close: (EditorRequest?) -> Void
    @Environment(\.displayScale) private var scale
    @Environment(\.scenePhase) private var phase
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var keyWindowFocused = false
    @Environment(AppLock.self) private var privacy
    @State private var session: VNCSession
    @State private var clipboard: VNCClipboardSynchronizer?
    @State private var observing: Bool
    #if targetEnvironment(macCatalyst)
    @Environment(MacWindowSceneSource.self) private var macWindow: MacWindowSceneSource?
    private var fullscreen: Bool { macWindow?.isFullScreen == true }
    #else
    @State private var fullscreen = false
    #endif
    @State private var recorded = false
    @State private var recordedVideoPause = false
    @State private var stopped = false
    @State private var closing = false
    @State private var confirmClose = false
    @State private var showsConnectionDetails = false
    @State private var reportStartedAt = Date()
    @State private var liveReport: ConnectionReport?
    @State private var diagnosticAttemptID = UUID()
    @State private var connectionAttempt = UUID()
    @State private var wakingComputer = false
    @State private var setupRequiresEditing = false
    @State private var lastReportWrite: Date?
    @State private var showsDictation = false
    @State private var screenshot = ScreenshotExport()
    @State private var controls = VNCDesktopControls()
    @State private var monitorError: String?
    @AppStorage("keyboard.localOptionKey") private var localOptionKey = VNCLocalOptionKey.off
    private struct DisplayLayoutState: Equatable {
        let topology: VNCMonitorTopology
        let ids: [UInt32]
        let reported: Bool
        let connected: Bool
        let locked: Bool
    }
    #if targetEnvironment(macCatalyst)
    @State private var macKeyboard = VNCKeyboardCapture()
    @Environment(MacMonitorWindows.self) private var monitorWindows
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    private var monitorGroup: MacMonitorWindows.Group? { monitorWindows.groups[request.id] }
    private var presentingMonitorGroup: MacMonitorWindows.Group? {
        session.hasPresentedCurrentPicture && !session.hasReportedMonitorLayout ? nil : monitorGroup
    }
    #endif
    #if !targetEnvironment(macCatalyst)
    @State private var mirrorAvailable = false
    @State private var mirrorEnabled = false
    @State private var toolbar = DeskToolbarState()
    @State private var toolbarBeforeFullScreen = true
    private var toolbarProfile = ToolbarProfile(device: .current)
    private var toolbarStyle: DeskToolbarStyle { toolbarProfile.style }
    @AppStorage("toolbar.portraitSplit") private var portraitSplit = false
    @AppStorage("pencil.doubleTap") private var pencilDoubleTap = RemotePencilAction.secondaryClick
    @AppStorage("pencil.squeeze") private var pencilSqueeze = RemotePencilAction.toggleToolbar
    @AppStorage("toolbar.twoFingerToggle") private var twoFingerToggle = true
    @AppStorage("gesture.holdDuration") private var holdDuration = RemoteTouchGestureConfiguration.defaultHoldDuration
    @AppStorage("keyboard.repeat") private var repeatKeys = true
    @AppStorage("keyboard.commandReturnSwitchesApps") private var commandReturnSwitchesApps = false
    @AppStorage("keyboard.delay") private var keyDelay = VNCKeyRepeat().delay
    @AppStorage("keyboard.interval") private var keyInterval = VNCKeyRepeat().interval
    #endif
    @State private var hostTrust: HostTrust
    @AppStorage("connection.files") private var transfers = true
    @AppStorage("connection.reconnect") private var reconnect = true
    @State private var viewport = RemoteViewportState()
    @State private var viewportPanningMode = RemoteViewportPanningMode.edge
    @State private var pointer: SessionPointerControl
    @State private var cursorTrackingSpeed: Double?
    @AppStorage("pointer.speed") private var pointerSpeed = 1.0
    private var gesturePreferences = SessionGesturePreferences()

    private var gestures: RemoteTouchGestureConfiguration {
        var result = gesturePreferences.configuration(for: request.computer,
                                                      usesAppleModifiers: session.serverUsesAppleModifierConvention)
        #if !targetEnvironment(macCatalyst)
        result.holdDuration = request.computer.touchHoldDuration ?? holdDuration
        result.allowsMomentumScrolling = request.computer.momentumScrolling != false || !session.serverUsesAppleModifierConvention
        result.pencilDoubleTap = pencilDoubleTap
        result.pencilSqueeze = pencilSqueeze
        result.togglesToolbarWithTwoFingerDoubleTap = twoFingerToggle
        #endif
        return result
    }

    private var pointerMenuExtras: VNCHUDMenuExtras {
        #if targetEnvironment(macCatalyst)
        return VNCHUDMenuExtras()
        #else
        return VNCHUDMenuExtras(display: {
            CursorTrackingSpeedPicker(selection: Binding(get: { cursorTrackingSpeed }, set: setCursorTrackingSpeed))
                .accessibilityIdentifier("session.cursorTrackingSpeed")
        })
        #endif
    }

    #if !targetEnvironment(macCatalyst)
    private func setCursorTrackingSpeed(_ speed: Double?) {
        guard session.connectionState.isConnected, !observing, !privacy.locked else { return }
        if var saved = library.existingComputer(matching: request.computer), saved.saved,
           saved.id == request.computer.id, saved.hasSameDestination(as: request.computer),
           saved.cursorTrackingSpeed != speed {
            saved.cursorTrackingSpeed = speed
            guard library.save(saved) else { return }
        }
        cursorTrackingSpeed = speed
    }
    #endif

    private var sessionKeyboard: VNCKeyboardCapture {
        #if targetEnvironment(macCatalyst)
        macKeyboard
        #else
        toolbar.keyboard
        #endif
    }

    private var remoteDesktop: RemoteDesktopView {
        @Bindable var pointer = pointer
        #if targetEnvironment(macCatalyst)
        let remoteActivity: (@MainActor () -> Void)? = nil
        #else
        let remoteActivity: (@MainActor () -> Void)? = toolbarStyle == .carousel ? toolbar.noteRemoteActivity : nil
        #endif
        let desktop = RemoteDesktopView(session: session, keyboardCapture: sessionKeyboard, isFullScreen: fullscreen,
                                 toggleFullScreen: toggleFullScreen, clipboardSynchronizer: clipboard,
                                 pointerSpeed: cursorTrackingSpeed ?? pointerSpeed, touchGestures: gestures, onRemoteInput: remoteActivity,
                                 onSharedClipboardUserChange: setClipboardSharing,
                                 hostOwnsRecoveryChrome: true, hudMenuExtras: pointerMenuExtras)
            .controllingViewport($viewport, panningMode: $viewportPanningMode)
            .controllingPointerMode($pointer.mode)
            .desktopControls(controls)
            .onMonitorShortcut(chooseMonitor)
            .onScreenshotShortcut(captureScreenshot)
        if #available(iOS 26, macCatalyst 26, *) { return desktop.onDictation { showsDictation = true } }
        return desktop
    }

    init(request: SessionRequest, library: ConnectionLibrary, preferences: UserDefaults, pasteboard: UIPasteboard,
         close: @escaping (EditorRequest?) -> Void) {
        self.request = request
        self.library = library
        self.pasteboard = pasteboard
        self.preferences = preferences
        let clipboardEnabled = preferences.object(forKey: "connection.sharedClipboard") as? Bool ?? true
        _sharesClipboard = State(initialValue: request.computer.sharesClipboard(defaultValue: clipboardEnabled))
        self.close = close
        let trust = HostTrust(defaults: preferences)
        _hostTrust = State(initialValue: trust)
        var configuration = request.computer.configuration(preferences: preferences,
            streamingPaused: library.videoRetryDate(for: request.computer) != nil)
        configuration.rsaHostValidationHandler = { host, port, fingerprint in
            await trust.verify(host: host, port: port, fingerprint: fingerprint, kind: .rsa)
        }
        configuration.certificateValidationHandler = { await trust.verifyCertificate($0) }
        let observing = request.startsInObservation(using: library)
        if observing {
            configuration.allowsFileTransfers = false
            configuration.automaticCurtainMessage = nil
        }
        if let ssh = request.computer.ssh {
            DesktopSSH.configureTransport(&configuration, settings: ssh, proof: request.sshProof, trust: trust)
        }
        _session = State(initialValue: VNCSession(configuration: configuration))
        _observing = State(initialValue: observing)
        _viewport = State(initialValue: RemoteViewportState(sizing: request.computer.initialViewportSizing ?? .fit))
        _pointer = State(initialValue: SessionPointerControl(mode: request.computer.pointerMode(using: preferences)))
        _cursorTrackingSpeed = State(initialValue: CursorTrackingSpeed.validated(request.computer.cursorTrackingSpeed))
    }

    var body: some View {
        GeometryReader { geometry in
            let deck = sessionDeck(in: geometry)
            VStack(spacing: 0) {
                if deck == nil, !fullscreen || observing || !session.connectionState.isConnected {
                    sessionHeader()
                }
                switch session.connectionState {
                case .connected, .reconnecting:
                    if privacy.locked {
                        Color.clear
                    } else {
                        sessionPicture(deck: deck, availableSize: geometry.size).overlay {
                            ConnectionStatusOverlay(session: session) {
                                closeSession(allowAction: false) { close(nil) }
                            }
                        }
                    }
                case .failed(let reason) where !wakingComputer:
                    let failure = SessionConnectionFailure(session.lastError, setupRequiresEditing: setupRequiresEditing)
                    ContentUnavailableView {
                        Label(failure.title, systemImage: "exclamationmark.triangle")
                            .accessibilityIdentifier("session.failureTitle")
                    } description: {
                        Text(failure.advice)
                    } actions: {
                        if failure.needsEditing {
                            editConnectionButton.buttonStyle(.borderedProminent)
                        } else {
                            retryActions("重试")
                        }
                        if !reason.isEmpty {
                            DisclosureGroup("错误详情") {
                                Text(verbatim: reason).font(.caption).textSelection(.enabled)
                            }
                            .frame(maxWidth: 360)
                        }
                    }
                case .disconnected where !wakingComputer:
                    ContentUnavailableView {
                        Label("已断开", systemImage: "rectangle.slash")
                    } actions: { retryActions("重新连接") }
                case .idle, .connecting, .failed, .disconnected:
                    VStack(spacing: 18) {
                        ProgressView(wakingComputer ? String(localized: "正在尝试唤醒电脑…")
                                                    : session.connectionPhaseDescription ?? "正在连接…")
                        Button("取消") { finish(edit: false) }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("session.cancelConnection")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .disconnecting:
                    ProgressView("正在断开…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .task(id: connectionAttempt) {
                guard !closing, !stopped, session.connectionState.canConnect else { return }
                setupRequiresEditing = false
                session.userDisconnectHandler = { finish(edit: false) }
                session.authorizePasswordSend = {
                    guard !observing, !stopped, !closing, !privacy.locked else { return false }
                    let permitted = await privacy.approvePasswordSend()
                    return permitted && !observing && !stopped && !closing && !privacy.locked
                }
                session.updateRemoteDisplaySize(viewSize: geometry.size, displayScale: scale)
                let item = request.computer
                do {
                    #if targetEnvironment(macCatalyst)
                    if let hardwareAddress = item.wakeHardwareAddress, item.ssh == nil, !privacy.locked {
                        wakingComputer = true
                        defer { wakingComputer = false }
                        try await WakeOnLAN.prepare(item.endpoint, hardwareAddress: hardwareAddress)
                    }
                    #endif
                    try Task.checkCancellation()
                    guard !closing, !stopped else { return }
                    let tunnelUserPassword: String?
                    if case let .password(value) = request.sshProof { tunnelUserPassword = value } else { tunnelUserPassword = nil }
                    try await session.connect(credentials: VNCCredentials(host: item.endpoint.host, port: item.endpoint.port,
                        password: request.password, username: item.username.isEmpty ? nil : item.username,
                        tunnelUserPassword: tunnelUserPassword))
                } catch is CancellationError {
                } catch {
                    if session.connectionState == .idle {
                        if let error = error as? VNCError, case .unsupportedFeature = error {
                            setupRequiresEditing = true
                        }
                        session.connectionState = .failed(error.localizedDescription)
                    }
                }
            }
            .onChange(of: geometry.size) { _, newSize in
                if observing { session.updateRemoteDisplaySize(viewSize: newSize, displayScale: scale) }
            }
            #if !targetEnvironment(macCatalyst)
            .background {
                if deck != nil { Color.black.ignoresSafeArea(.container, edges: .top) }
            }
            #endif
        }
        #if !targetEnvironment(macCatalyst)
        .ignoresSafeArea(.keyboard)
        .onChange(of: VNCKeyRepeat(enabled: repeatKeys, delay: keyDelay, interval: keyInterval), initial: true) { _, value in
            toolbar.keyboard.keyRepeat = value
        }
        .onChange(of: commandReturnSwitchesApps, initial: true) { _, value in
            toolbar.keyboard.usesReturnForRemoteAppSwitcher = value
        }
        .background {
            if #available(iOS 27.0, *), !stopped {
                // Keep the external window registered while this session reconnects.
                let outputEnabled = mirrorAvailable && mirrorEnabled && !privacy.locked && !closing && phase == .active
                ExternalDisplayMirror(session: session, privacy: privacy, enabled: outputEnabled) {
                    mirrorAvailable = $0
                    if !$0 { mirrorEnabled = false }
                }
                .frame(width: 0, height: 0)
            }
        }
        #endif
        .onChange(of: localOptionKey, initial: true) { _, value in
            sessionKeyboard.localOptionKey = value
        }
        .onChange(of: session.connectionState) { _, state in
            if case .failed = state {
                let diagnostics = session.getDiagnostics()
                library.recordDiagnosticFailure(.init(id: diagnosticAttemptID, date: .now, reason: .init(session.lastError),
                                                      usesSSH: request.computer.ssh != nil,
                                                      requestsHighPerformance: session.configuration.enableHighPerformanceMode,
                                                      version: diagnostics.clientVersion?.description,
                                                      securityType: diagnostics.selectedSecurityType?.rawValue))
            } else if state.isConnecting || state.isConnected { diagnosticAttemptID = UUID() }
            if !state.isConnected {
                if let liveReport { library.keepReport(liveReport, for: request.computer) }
                showsConnectionDetails = false
                liveReport = nil
                lastReportWrite = nil
            } else { reportStartedAt = .now }
            if state.isConnected, !recorded {
                recorded = true
                library.recordSuccess(request.computer)
                if request.remembersObservation, request.initialObservation != nil {
                    library.rememberObservation(observing, for: request.computer)
                }
                if request.rememberPassword {
                    do {
                        try PasswordStore.write(request.password, for: request.computer, synchronize: request.synchronizeCredentials)
                        if let ssh = request.computer.ssh, let secret = request.sshSecretToRemember {
                            try PasswordStore.write(secret, for: request.computer, kind: ssh.usesKey ? .sshKey : .sshPassword,
                                                    synchronize: request.synchronizeCredentials)
                        }
                    }
                    catch { library.errorMessage = error.localizedDescription }
                }
            }
            if state.isConnected, !observing { attachClipboard() }
            recordVideoFallback()
        }
        .onChange(of: session.highPerformanceFallbackReason) { _, _ in recordVideoFallback() }
        .onChange(of: transfers, initial: true, syncTransferPermission)
        .task(id: DisplayLayoutState(topology: session.monitorTopology, ids: session.selectableMonitorIDs,
                                     reported: session.hasReportedMonitorLayout,
                                     connected: session.connectionState.isConnected, locked: privacy.locked)) {
            guard !Task.isCancelled, !stopped, !closing, !privacy.locked, session.connectionState.isConnected else { return }
            let saved = (library.existingComputer(matching: request.computer) ?? request.computer).display(for: .current)
            #if targetEnvironment(macCatalyst)
            if session.hasReportedMonitorLayout, let group = monitorGroup, group.topology != session.monitorTopology {
                closeMonitorWindows()
            }
            if let windows = MacMonitorWindows.desiredChildren(session: session, locked: privacy.locked,
                                                              group: monitorGroup, saved: saved) {
                if windows.isEmpty {
                    closeMonitorWindows()
                } else {
                    await openMonitorWindows(windows, remember: false)
                    return
                }
            }
            #endif
            guard !session.selectableMonitorIDs.isEmpty, session.monitorTopology != .virtualVideo,
                  saved.rememberMonitor != false, let choice = saved.lastMonitor else { return }
            do { try await session.selectMonitor(choice) } catch { if !Task.isCancelled { monitorError = error.localizedDescription } }
        }
        .alert("切换显示器失败", isPresented: Binding(get: { monitorError != nil }, set: { if !$0 { monitorError = nil } })) {
            Button("好") { monitorError = nil }
        } message: { Text(monitorError ?? "") }
        .onChange(of: reconnect, initial: true) { session.configuration.reconnectionPolicy.isEnabled = reconnect }
        .onChange(of: observing, syncTransferPermission)
        #if targetEnvironment(macCatalyst)
        .focusedSceneValue(\.deskLinkSession, macMenu)
        #elseif os(iOS)
        .focusedSceneValue(\.telescopePadSession, padSessionMenu)
        .onChange(of: [observing, session.isReadyForDesktopInput]) {
            if #available(iOS 26, *), UIDevice.current.userInterfaceIdiom == .pad {
                UIMenuSystem.main.setNeedsRebuild()
            }
        }
        #endif
        .background { SessionWindowFocus { keyWindowFocused = $0 }.frame(width: 0, height: 0) }
        .focusedSceneValue(\.deskLinkClipboardSharing, clipboardSharing)
        .onChange(of: windowIsActive) { _, active in clipboard?.setHostWindowActive(active) }
        .onChange(of: privacy.locked) { _, locked in
            syncTransferPermission()
            if locked { showsConnectionDetails = false; clipboard?.invalidate(); clipboard = nil }
            else if !observing, session.connectionState.isConnected { attachClipboard() }
        }
        .sheet(isPresented: $showsConnectionDetails) {
            if !privacy.locked { ConnectionDetails(report: liveReport) }
        }
        .task(id: reportSampling) { await sampleConnection() }
        .modifier(RemoteDictationPresentation(session: session, presented: $showsDictation,
                                              canControl: { !observing && !closing && !stopped && !privacy.locked }))
        .modifier(ScreenshotExporter(export: screenshot))
        .onDisappear { closeSession(allowAction: phase != .background) {} }
        .confirmationDialog("文件传输进行中", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("断开连接", role: .destructive) { closeSession(allowAction: true) { close(nil) } }
            Button("取消", role: .cancel) {}
        }
        .alert(hostTrust.prompt?.kind == .tls ? "TLS" : "主机指纹", isPresented: Binding(get: { hostTrust.prompt != nil }, set: { _ in }), presenting: hostTrust.prompt) { identity in
            Button("取消", role: .cancel) { hostTrust.answer(false) }
            Button("确认") { hostTrust.answer(true, remember: identity.kind == .ssh) }
            if identity.kind == .tls { Button("记住证书") { hostTrust.answer(true) } }
            if identity.kind == .rsa { Button("记住主机指纹") { hostTrust.answer(true) } }
        } message: { identity in
            Text(verbatim: (identity.kind == .ssh ? "请核对远程计算机的 SSH 指纹。\n" : identity.kind == .rsa ? "请核对远程计算机的 RSA 公钥指纹。\n" : "") + identity.displayAddress + "\n" + identity.fingerprint)
        }
        .statusBarHidden(fullscreen)
        .persistentSystemOverlays(fullscreen ? .hidden : .automatic)
    }

    private func sessionHeader(allowsToolbarToggle: Bool = true, compact: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: compact ? 12 : 14) {
                Button { finish(edit: false) } label: { Label("返回", systemImage: "chevron.backward") }
                    .labelStyle(.iconOnly)
                Button { liveReport = nil; showsConnectionDetails = true } label: {
                    VStack(alignment: .leading) {
                        HStack(spacing: 4) {
                            Text(request.computer.displayName).font(.headline).lineLimit(1)
                            if session.connectionState.isConnected {
                                Image(systemName: "info.circle").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if !compact, request.computer.displayName != request.computer.endpoint.address {
                            Text(request.computer.endpoint.address).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!session.connectionState.isConnected)
                .accessibilityLabel("连接信息")
                .accessibilityValue(request.computer.displayName)
                .accessibilityIdentifier("session.info")
                Spacer()
                if session.connectionState.isConnected {
                    if session.isCurtained {
                        Label("屏幕帘幕已开启", systemImage: "eye.slash.fill")
                            .labelStyle(.iconOnly)
                            .accessibilityIdentifier("session.curtainActive")
                    }
                    Button { toggleObservation() } label: {
                        if compact {
                            Label(observing ? "仅观察" : "控制", systemImage: observing ? "eye" : "cursorarrow")
                                .labelStyle(.iconOnly)
                        } else {
                            Label(observing ? "仅观察" : "控制", systemImage: observing ? "eye" : "cursorarrow")
                        }
                    }
                    .accessibilityIdentifier("session.mode")
                    #if targetEnvironment(macCatalyst)
                    MacPictureSizingMenu(viewport: $viewport).labelStyle(.iconOnly)
                    MonitorMenu(session: session, select: chooseMonitor, split: showAllMonitorWindows,
                                isSplit: monitorGroup != nil).labelStyle(.iconOnly)
                    if !observing, session.isReadyForDesktopInput, session.canSendLoginPassword {
                        PasswordTypingButton(controls: controls) {
                            Label("输入用户密码", systemImage: "key").labelStyle(.iconOnly)
                        }
                        .accessibilityIdentifier("session.password")
                    }
                    if #available(macCatalyst 26, *), !observing {
                        Button { showsDictation = true } label: { Label("听写", systemImage: "mic").labelStyle(.iconOnly) }
                            .accessibilityIdentifier("session.dictation")
                    }
                    #else
                    MonitorMenu(session: session, shortcuts: true, select: chooseMonitor).labelStyle(.iconOnly)
                    #endif
                    #if !targetEnvironment(macCatalyst)
                    if !observing, allowsToolbarToggle {
                        Button { toolbar.visible.toggle() } label: {
                            Label(toolbar.visible ? "隐藏工具栏" : "显示工具栏", systemImage: "rectangle.bottomthird.inset.filled")
                                .labelStyle(.iconOnly)
                        }.accessibilityIdentifier("toolbar.toggle")
                    }
                    if mirrorAvailable {
                        Toggle(isOn: $mirrorEnabled) {
                            Label("镜像到外部显示器", systemImage: "airplayvideo").labelStyle(.iconOnly)
                        }.toggleStyle(.button)
                    }
                    #endif
                    Button(action: captureScreenshot) {
                        Label("保存屏幕快照", systemImage: ConnectionActionSymbol.screenshot).labelStyle(.iconOnly)
                    }.accessibilityIdentifier("session.screenshot")
                    #if !targetEnvironment(macCatalyst)
                    .keyboardShortcut("r", modifiers: [.shift, .control, .command])
                    #endif
                    if !observing, let clipboard {
                        Menu {
                            Button("接收剪贴板", systemImage: ConnectionActionSymbol.receiveClipboard) { clipboard.getClipboard() }
                                .disabled(!clipboard.canGetClipboard)
                            Button("发送剪贴板", systemImage: ConnectionActionSymbol.sendClipboard) { clipboard.sendClipboard() }
                                .disabled(!clipboard.canSendClipboard)
                            if let sharing = clipboardSharing {
                                Divider()
                                Toggle(isOn: sharing) {
                                    Label("自动共享剪贴板", systemImage: "arrow.triangle.2.circlepath")
                                }
                                .accessibilityIdentifier("session.sharedClipboard")
                            }
                        } label: { Label("共享剪贴板", systemImage: ConnectionActionSymbol.clipboard).labelStyle(.iconOnly) }
                        .accessibilityIdentifier("session.clipboard")
                    }
                    Button { toggleFullScreen() } label: {
                        Label("切换全屏幕", systemImage: fullscreen
                              ? ConnectionActionSymbol.exitFullScreen : ConnectionActionSymbol.fullScreen)
                            .labelStyle(.iconOnly)
                    }
                    Button { finish(edit: false) } label: {
                        Label("断开连接", systemImage: ConnectionActionSymbol.disconnect).labelStyle(.iconOnly)
                    }
                    .accessibilityIdentifier("session.close")
                    #if !targetEnvironment(macCatalyst)
                    .keyboardShortcut("c", modifiers: [.shift, .control, .command])
                    #endif
                }
            }
            .padding(.horizontal)
            .padding(.vertical, compact ? 0 : 10)
            .frame(minHeight: compact ? 44 : nil)
            if !compact { Divider() }
        }
    }

    private func sessionDeck(in geometry: GeometryProxy) -> DeskSessionDeck? {
        #if !targetEnvironment(macCatalyst)
        guard !fullscreen, !observing, !privacy.locked else { return nil }
        switch session.connectionState {
        case .connected, .reconnecting: break
        default: return nil
        }

        let size = geometry.size
        if #available(iOS 27.1, *) {
            let divisions = geometry.reservedRegions(kind: .division, options: .includeInactive)
            if let fold = divisions.first(where: {
                $0.isActive && $0.frame.width > $0.frame.height
                    && $0.frame.minY > 0 && $0.frame.maxY < size.height
            })?.frame {
                return DeskSessionDeck(divider: fold.minY, size: size, gap: fold.height)
            }
            if divisions.isEmpty, horizontalSizeClass == .compact, size.height > size.width,
               let margins = coverMargins(in: geometry) {
                return DeskSessionDeck(divider: size.height * 0.51, size: size, coverMargins: margins)
            }
        }
        if portraitSplit, size.height > size.width, size.height >= 580,
           size.width >= 280 {
            return DeskSessionDeck(divider: min(size.height * 0.46, size.height - 350), size: size)
        }
        #endif
        return nil
    }

    #if !targetEnvironment(macCatalyst)
    @available(iOS 27.1, *)
    private func coverMargins(in geometry: GeometryProxy) -> EdgeInsets? {
        let size = geometry.size
        let safe = geometry.safeAreaInsets
        // The cover camera sits in a corner, while a conventional phone's
        // camera cutout is centered on one axis. Work in this view's safe area.
        let corner = geometry.reservedRegions(kind: .occlusion).first { region in
            let frame = region.frame
            return region.isActive && (frame.midX < size.width * 0.24 || frame.midX > size.width * 0.76)
                && (frame.midY < size.height * 0.28 || frame.midY > size.height * 0.72)
        }?.frame
        if let corner {
            let leading = corner.midX < size.width / 2 ? max(0, corner.maxX + 8) : 0
            let trailing = corner.midX >= size.width / 2 ? max(0, size.width - corner.minX + 8) : 0
            return EdgeInsets(top: 0, leading: leading, bottom: 0, trailing: trailing)
        }
        // Some presentations already inset the whole view away from the rail.
        if size.height > size.width, max(safe.leading, safe.trailing) > 20 { return EdgeInsets() }
        return nil
    }
    #endif

    @ViewBuilder private func sessionPicture(deck: DeskSessionDeck?, availableSize: CGSize) -> some View {
        #if targetEnvironment(macCatalyst)
        if let group = presentingMonitorGroup {
            if let region = group.region(for: group.primary) {
                if observing { VNCMonitorPicture(session: session, region: region, viewport: $viewport) }
                else { remoteDesktop.showingMonitor(in: region).ignoresSafeArea(.keyboard) }
            } else if session.connectionState.isConnected, session.hasPresentedCurrentPicture {
                ProgressView("等待远程画面…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.black
            }
        } else if observing {
            ObservedPicture(session: session, showsPlaceholder: false, viewport: $viewport)
        } else {
            remoteDesktop.ignoresSafeArea(.keyboard)
        }
        #else
        if observing {
            ObservedPicture(session: session, showsPlaceholder: false, viewport: $viewport)
        } else {
            InteractiveDesktop(desktop: remoteDesktop, session: session, controls: controls, bar: toolbar,
                               deck: deck, showsSessionHeader: !fullscreen,
                               isWidePhone: DisplayClient.current == .iPhone && availableSize.width > availableSize.height,
                               holdDuration: gestures.holdDuration, chooseMonitor: chooseMonitor,
                               startDictation: { showsDictation = true }, captureScreenshot: captureScreenshot,
                               toggleFullScreen: toggleFullScreen) {
                sessionHeader(allowsToolbarToggle: false, compact: true)
            }
            .ignoresSafeArea(.keyboard)
        }
        #endif
    }

    @ViewBuilder private func retryActions(_ title: String) -> some View {
        Button(title) {
            guard !privacy.locked, !closing, !stopped else { return }
            #if targetEnvironment(macCatalyst)
            if !recorded, request.computer.wakeHardwareAddress != nil, request.computer.ssh == nil {
                connectionAttempt = UUID()
                return
            }
            #endif
            if !session.retryConnection() { connectionAttempt = UUID() }
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("session.reconnect")
        editConnectionButton.buttonStyle(.bordered)
    }

    private var editConnectionButton: some View {
        Button("编辑连接") { finish(edit: true) }
            .accessibilityIdentifier("session.editConnection")
    }

    private func syncTransferPermission() {
        session.fileTransfers.setNewTransfersSuspended(privacy.locked)
        session.configuration.allowsFileTransfers = transfers && !observing
        session.configuration.automaticCurtainMessage = observing || privacy.locked ? nil : request.computer.automaticCurtainMessage
    }

    private func recordVideoFallback() {
        guard !recordedVideoPause, session.highPerformanceFallbackReason != nil else { return }
        recordedVideoPause = library.pauseStreaming(for: request.computer)
    }

    private enum ReportSampling: Hashable { case idle, periodic, visible }
    private var reportSampling: ReportSampling {
        guard session.connectionState.isConnected, phase != .background, !privacy.locked else { return .idle }
        return showsConnectionDetails ? .visible : .periodic
    }

    private func sampleConnection() async {
        if reportSampling == .idle {
            if let liveReport { library.keepReport(liveReport, for: request.computer) }
            return
        }
        while !Task.isCancelled {
            if let value = await ConnectionReport.capture(session: session, id: request.id,
                                                          startedAt: reportStartedAt), !Task.isCancelled {
                let firstPicture = value.frames > 0 && (liveReport?.frames ?? 0) == 0
                let firstSound = (value.audioPackets ?? 0) > 0 && (liveReport?.audioPackets ?? 0) == 0
                let mediaChanged = value.videoCodec != liveReport?.videoCodec || value.audioPlayback != liveReport?.audioPlayback
                let periodicWriteDue = value.capturedAt.timeIntervalSince(lastReportWrite ?? .distantPast) >= 60
                liveReport = value
                if firstPicture || firstSound || mediaChanged || periodicWriteDue {
                    library.keepReport(value, for: request.computer)
                    lastReportWrite = value.capturedAt
                }
            }
            do { try await Task.sleep(for: .seconds(showsConnectionDetails ? 1 : 5)) } catch { return }
        }
    }

    private func captureScreenshot() {
        guard !stopped, !closing, !privacy.locked, phase != .background else { return }
        withScreenshotRegion { screenshot.capture(session, region: $0) }
    }

    private func withScreenshotRegion(_ capture: (CGRect?) -> Void) {
        #if targetEnvironment(macCatalyst)
        if let group = presentingMonitorGroup {
            guard let region = group.region(for: group.primary) else { return }
            capture(region)
            return
        }
        #endif
        capture(nil)
    }

    private var canUseSessionMenu: Bool {
        !privacy.locked && hostTrust.prompt == nil && !confirmClose && !closing && !stopped
    }

    #if os(iOS) && !targetEnvironment(macCatalyst)
    private var padSessionMenu: PadSessionMenuActions? {
        guard UIDevice.current.userInterfaceIdiom == .pad, canUseSessionMenu,
              phase != .background, !showsDictation, !showsConnectionDetails, monitorError == nil else { return nil }
        return PadSessionMenuActions(session: session, controls: controls, clipboard: observing ? nil : clipboard,
                                     observing: observing, toggleObservation: toggleObservation,
                                     toggleFullScreen: toggleFullScreen, disconnect: { finish(edit: false) },
                                     chooseMonitor: chooseMonitor, captureScreenshot: captureScreenshot,
                                     allowsInput: {
                                         canUseSessionMenu && phase != .background && !observing
                                             && session.connectionState.isConnected
                                     })
    }
    #endif

    #if targetEnvironment(macCatalyst)
    private var macMenu: MacSessionMenuActions? {
        guard canUseSessionMenu else { return nil }
        return MacSessionMenuActions(session: session, controls: controls, clipboard: clipboard, clipboardSharing: clipboardSharing,
                                     observing: observing, toggleObservation: toggleObservation,
                                     toggleFullScreen: toggleFullScreen, disconnect: { finish(edit: false) },
                                     chooseMonitor: chooseMonitor, splitMonitors: showAllMonitorWindows,
                                     isSplit: monitorGroup != nil, viewport: $viewport, startDictation: { showsDictation = true },
            captureScreenshot: captureScreenshot, isFullScreen: fullscreen)
    }

    private func showAllMonitorWindows() {
        let displays = session.selectableMonitorIDs
        Task { await openMonitorWindows(displays, remember: true) }
    }

    private func openMonitorWindows(_ displays: [UInt32], remember: Bool) async {
        let topology = session.monitorTopology
        let available = session.selectableMonitorIDs
        let previousGroup = monitorGroup
        let preferredPrimary = previousGroup.flatMap { $0.topology == topology ? $0.primary : nil }
        guard !privacy.locked, !closing, !stopped,
              let (primary, children) = MacMonitorWindows.splitLayout(
                  availableDisplays: available, preferredPrimary: preferredPrimary, requestedChildren: displays),
              !children.isEmpty else { return }
        let previous = previousGroup?.children ?? []
        do {
            guard try await session.selectMonitor(.all), !Task.isCancelled, !privacy.locked,
                  !closing, !stopped, session.connectionState.isConnected,
                  topology == session.monitorTopology, available == session.selectableMonitorIDs else { return }
            guard remember || previous == (monitorGroup?.children ?? []) else { return }
            let focusedChild = monitorGroup?.focusedChild.flatMap { children.contains($0) ? $0 : nil }
            let group = MacMonitorWindows.Group(session: session, computer: request.computer, library: library,
                                                pointer: pointer,
                                                primary: primary, children: children, observing: observing,
                                                focusedChild: focusedChild, sessionMenu: { macMenu }, topology: topology)
            monitorWindows.set(group, for: request.id)
            for id in previous where !children.contains(id) {
                dismissWindow(id: MonitorWindowID.scene, value: group.window(id, connection: request.id))
            }
            for id in children where remember || !previous.contains(id) {
                openWindow(id: MonitorWindowID.scene, value: group.window(id, connection: request.id))
            }
            if remember, topology == .standard { library.rememberMonitor(.all, for: request.computer, windowed: children) }
        } catch { if !Task.isCancelled { monitorError = error.localizedDescription } }
    }

    private func closeMonitorWindows() {
        guard let group = monitorGroup else { return }
        for id in monitorWindows.remove(request.id) {
            dismissWindow(id: MonitorWindowID.scene, value: group.window(id, connection: request.id))
        }
    }
    #endif

    private var windowIsActive: Bool {
        #if targetEnvironment(macCatalyst)
        if monitorGroup?.focusedChild != nil { return !privacy.locked }
        #endif
        return keyWindowFocused && appearsActive && phase == .active
    }

    private func chooseMonitor(_ choice: VNCMonitorSelection) {
        guard !stopped, !closing, !privacy.locked else { return }
        Task {
            do {
                if try await session.selectMonitor(choice) {
                    #if targetEnvironment(macCatalyst)
                    closeMonitorWindows()
                    #endif
                    if session.monitorTopology != .virtualVideo { library.rememberMonitor(choice, for: request.computer) }
                }
            } catch { monitorError = error.localizedDescription }
        }
    }

    private var clipboardSharing: Binding<Bool>? {
        guard clipboard != nil, !observing, !privacy.locked, !closing, !stopped, session.connectionState.isConnected else { return nil }
        return Binding(get: { sharesClipboard }, set: setClipboardSharing)
    }

    private func setClipboardSharing(_ value: Bool) {
        guard !observing, !privacy.locked, !closing, !stopped else { return }
        sharesClipboard = value
        clipboard?.sharedClipboardEnabled = value
    }

    private func attachClipboard() {
        guard clipboard == nil, !privacy.locked, !closing, !stopped else { return }
        let controller = VNCClipboardSynchronizer(session: session, pasteboard: pasteboard)
        let computer = request.computer.displayName
        let preferences = preferences
        controller.onManualTransferResult = { [weak privacy] result in
            Task { @MainActor in
                await ClipboardNotifications.post(result, computer: computer, preferences: preferences, canPresent: {
                    privacy?.locked == false
                })
            }
        }
        controller.setHostWindowActive(windowIsActive)
        controller.sharedClipboardEnabled = sharesClipboard
        clipboard = controller
    }

    private func toggleObservation() {
        if observing {
            attachClipboard()
        } else {
            clipboard?.sharedClipboardEnabled = false
            clipboard?.invalidate()
            clipboard = nil
        }
        observing.toggle()
        if recorded, request.remembersObservation, !privacy.locked {
            library.rememberObservation(observing, for: request.computer)
        }
        #if targetEnvironment(macCatalyst)
        monitorWindows.setObserving(observing, for: request.id)
        #endif
    }

    private func toggleFullScreen() {
        #if targetEnvironment(macCatalyst)
        macWindow?.toggleFullScreen()
        #else
        if fullscreen { toolbar.visible = toolbarBeforeFullScreen }
        else {
            toolbarBeforeFullScreen = toolbar.visible
            toolbar.visible = false
        }
        fullscreen.toggle()
        #endif
    }

    private func finish(edit: Bool) {
        if !edit, session.fileTransfers.hasActiveTransfers { confirmClose = true; return }
        closeSession(allowAction: !edit) {
            let editor = edit ? EditorRequest(purpose: .connect, computer: request.computer,
                                              sharedOptions: .init(observe: observing),
                                              remembersObservation: request.remembersObservation,
                                              rejectedSSHCredential: session.lastError == .sshAuthenticationFailed) : nil
            close(editor)
        }
    }

    private func closeSession(allowAction: Bool, completion: @escaping @MainActor () -> Void) {
        guard !closing, !stopped else { return }
        closing = true
        if let liveReport { library.keepReport(liveReport, for: request.computer) }
        guard allowAction, !privacy.locked, session.connectionState.isConnected else {
            tearDown()
            completion()
            return
        }
        let action = observing ? nil : request.computer.disconnectAction
        if request.computer.savesDisconnectScreenshot == true, phase != .background,
           let frame = session.presentedFrame {
            withScreenshotRegion { library.saveDisconnectScreenshot(for: request.computer, frame: frame, region: $0) }
        }
        action?.send(to: session)
        // A desktop that stopped reading must still let its window close.
        let timeout = Task { @MainActor in
            try await Task.sleep(for: .seconds(2))
            if !stopped { tearDown(); completion() }
        }
        Task { @MainActor in
            if action != nil { await session.flushPendingInput() }
            if !stopped, let final = await ConnectionReport.capture(session: session, id: request.id, startedAt: reportStartedAt) {
                library.keepReport(final, for: request.computer)
            }
            timeout.cancel()
            if !stopped { tearDown(); completion() }
        }
    }

    private func tearDown() {
        guard !stopped else { return }
        stopped = true
        #if targetEnvironment(macCatalyst)
        closeMonitorWindows()
        #endif
        hostTrust.cancel()
        clipboard?.invalidate()
        clipboard = nil
        session.userDisconnectHandler = nil
        session.authorizePasswordSend = nil
        session.disconnect()
    }
}

/// Observe mode owns no input responder, clipboard controller or file drop target.
struct ObservedPicture: View {
    let session: VNCSession
    var showsPlaceholder = true
    var viewport: Binding<RemoteViewportState>?

    var body: some View {
        ZStack {
            Color.black
            if session.isHighPerformanceMode || (viewport != nil && session.hasPresentedStandardPicture) {
                VNCMonitorPicture(session: session, viewport: viewport)
            } else if case let .image(image) = session.presentedFrame {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else if showsPlaceholder {
                ProgressView().tint(.white)
            }
        }
        .accessibilityLabel("观察")
    }
}
