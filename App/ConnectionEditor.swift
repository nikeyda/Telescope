import SwiftUI
import RFBTransport
import rootshellVNC

enum EditorPurpose { case quick, new, edit, connect }
private enum DesktopSizing { case physical, dynamic, fixed }

private extension PortableFramebufferCodec {
    var title: String {
        switch self {
        case .tight: "Tight"
        case .lastRect: "Tight LastRect"
        case .zrle: "ZRLE"
        case .zlib: "Zlib"
        case .copyRect: "CopyRect"
        case .cursor: "Cursor"
        case .raw: "Raw"
        }
    }
}

private extension VNCDisconnectAction {
    var label: LocalizedStringKey {
        switch self {
        case .lockScreen: "锁定远程屏幕"
        case .logOutUser: "注销用户"
        case .controlAltDelete: "Ctrl-Alt-Delete"
        case .topLeft: "左上触发角"
        case .topRight: "右上触发角"
        case .bottomLeft: "左下触发角"
        case .bottomRight: "右下触发角"
        }
    }
}

struct EditorRequest: Identifiable {
    let id = UUID()
    var purpose: EditorPurpose
    var computer: Computer?
    var initialAddress: String = ""
    var folder: String?
    var initialSSHPort: UInt16?
    var initialSSHServer: String?
    var suggestedSSHPort: UInt16?
    var link: DesktopLink?
    var sharedOptions = ConnectionRoute.SharedOptions()
    var loadsStoredCredentials = true
    var remembersObservation = true
    var rejectedSSHCredential = false
    var discoveredSelection: DiscoveredProfileSelection?

    var allowsDeviceSelection: Bool {
        purpose == .quick && initialAddress.isEmpty && initialSSHPort == nil && link == nil
    }

    func platform(for endpoint: Endpoint?) -> DesktopPlatform? {
        guard let computer, endpoint?.host == computer.endpoint.host else { return nil }
        return computer.desktopPlatform
    }

    @MainActor
    static func connectingToDiscovered(_ computer: Computer, in library: ConnectionLibrary,
                                       suggestedSSHPort: UInt16?, quality: PictureQuality?,
                                       resolvedAddresses: Set<Endpoint> = []) -> Self {
        DiscoveredProfileSelection(computer: computer, suggestedSSHPort: suggestedSSHPort,
                                   intent: .connect(quality), resolvedAddresses: resolvedAddresses).request(in: library)
    }

    static func from(_ link: DesktopLink, in archive: LibraryArchive, allowUnsavedHost: Bool) throws -> Self {
        if link.requestsGuest { throw LinkError.guestUnavailable }
        let saved = archive.computers.filter(\.saved)
        let endpoint: Endpoint?
        var matches: [Computer]
        switch link.target {
        case .address(let address):
            // The Mac handles vnc:// and screens:// as saved-computer links.
            // SSH addresses and direct VNC links on iPad keep their original route.
            guard allowUnsavedHost, link.sshPort == nil else {
                return Self(purpose: .quick, initialAddress: address.address, initialSSHPort: link.sshPort, link: link)
            }
            // A literal IP, qualified hostname, or host with a port must keep
            // its destination even if another record has that display name.
            endpoint = address
            matches = saved.filter { $0.endpoint == address }
        case .savedName(let displayName):
            endpoint = try? Endpoint(address: displayName)
            matches = saved.filter { $0.displayName.caseInsensitiveCompare(displayName) == .orderedSame }
            if let endpoint {
                if (try? Endpoint.hostOnly(displayName)) == nil {
                    // An explicit port selects the exact endpoint, including an explicit 5900.
                    matches = saved.filter { $0.endpoint == endpoint }
                } else if matches.isEmpty || endpoint.host.contains(".") || endpoint.host.contains(":") {
                    // A host-only link selects a saved connection and inherits its port.
                    // A qualified host takes precedence over a display name spelled the same way.
                    let hostMatches = saved.filter { $0.endpoint.host == endpoint.host }
                    if !hostMatches.isEmpty { matches = hostMatches }
                }
            }
        }
        if matches.count > 1, let username = link.username {
            let accounts = matches.filter { $0.username == username }
            if !accounts.isEmpty { matches = accounts }
        }
        if matches.count > 1 { throw LinkError.ambiguousName }
        if let computer = matches.first { return Self(purpose: .connect, computer: computer, link: link) }
        if allowUnsavedHost, let endpoint { return Self(purpose: .quick, initialAddress: endpoint.address, link: link) }
        throw LinkError.missingComputer
    }

    enum LinkError: LocalizedError {
        case guestUnavailable, ambiguousName, missingComputer
        var errorDescription: String? {
            switch self {
            case .guestUnavailable: "当前版本尚未支持 Mac 的访客授权请求。请使用远程电脑的登录账户。"
            case .ambiguousName: "有多个已保存的连接符合这个链接。请从连接库选择要使用的电脑。"
            case .missingComputer: "连接库中没有这台电脑。"
            }
        }
    }
}

struct SessionRequest: Identifiable {
    let id = UUID()
    let computer: Computer
    let password: String
    let rememberPassword: Bool
    var synchronizeCredentials = false
    var sshProof: SSHProof?
    var sshSecretToRemember: String?
    var initialObservation: Bool?
    var remembersObservation = true

    @MainActor
    func startsInObservation(using library: ConnectionLibrary) -> Bool {
        initialObservation ?? library.startsInObservation(computer)
    }

    static func remembered(for computer: Computer, synchronize: Bool) throws -> Self? {
        if computer.authentication == .macUser, computer.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }
        let desktopPassword = computer.authentication.usesPassword
            ? try PasswordStore.read(computer, synchronize: synchronize) : ""
        guard let password = desktopPassword else { return nil }
        var request = Self(computer: computer, password: password, rememberPassword: true, synchronizeCredentials: synchronize)
        if let ssh = computer.ssh {
            guard !ssh.username.isEmpty else { return nil }
            let secret: String?
            if ssh.usesKey, let name = ssh.keyName {
                secret = try PasswordStore.namedKey(name, synchronize: synchronize)
            } else {
                secret = try PasswordStore.read(computer, kind: ssh.usesKey ? .sshKey : .sshPassword, synchronize: synchronize)
            }
            guard let secret, !secret.isEmpty else { return nil }
            request.sshProof = ssh.usesKey ? .privateKey(try SSHKeyFile.identity(secret)) : .password(secret)
            if ssh.keyName == nil { request.sshSecretToRemember = secret }
        }
        return request
    }
}

extension Computer {
    @MainActor
    var configuration: VNCConfiguration { configuration(preferences: .standard) }

    @MainActor
    func configuration(preferences: UserDefaults, streamingPaused: Bool = false) -> VNCConfiguration {
        let display = display(for: .current).resolved(for: .current)
        let picture: VNCConfiguration.VideoQualityMode = switch display.quality {
        case .adaptive: .adaptive
        case .standard: .standard
        case .lossless: .fullQuality
        }
        let topology: VNCConfiguration.DisplayMode = switch display.layout {
        case .single: .oneDisplay
        case .combined: .allDisplaysCombined
        case .virtualPair: .twoVirtualDisplays
        }
        var configuration = VNCConfiguration(
            enableHighPerformanceMode: display.quality == .adaptive && display.smoothVideo != false
                && (ssh == nil || ssh?.secureLocally == false) && !streamingPaused,
            videoQualityMode: picture,
            displaySizingMode: display.matchWindow ? .matchClient : .remoteDisplay,
            displayMode: topology,
            enableRemoteAudio: display.remoteAudio
        )
        if display.matchWindow, display.quality == .adaptive {
            if let fixedDesktop = display.fixedDesktop, fixedDesktop.isSupported {
                configuration.fixedDesktopSize = CGSize(width: fixedDesktop.width, height: fixedDesktop.height)
            }
            configuration.usesRetinaResolution = display.retinaResolution ?? true
        }
        if display.quality != .adaptive {
            switch display.colorDepth ?? .full {
            case .low: configuration.preferredPixelFormat = .rgb332
            case .medium: configuration.preferredPixelFormat = .rgb555
            case .full: break
            }
        }
        configuration.allowsFileTransfers = preferences.object(forKey: "connection.files") as? Bool ?? true
        configuration.automaticCurtainMessage = viewOnly ? nil : automaticCurtainMessage
        if allowsRemoteBell != false { configuration.serverBellHandler = { RemoteBell.play() } }
        configuration.framebufferQuality = framebufferQuality ?? FramebufferQuality()
        configuration.disabledPortableCodecs = Set((disabledVNCCodecs ?? []).compactMap(PortableFramebufferCodec.init(rawValue:)))
        configuration.allowsViewportZoom = allowsViewportZoom != false
        configuration.securityPolicy = switch authentication {
        case .automatic: .automatic
        case .macUser: .macUser
        case .vncPassword: .vncAuthentication
        case .unauthenticated: .none
        case .raspberryPiRSA: .rsaAES
        }
        configuration.preparesTigerVNCKeyboard = preparesTigerVNCKeyboard == true
        configuration.usesMacHardwareKeyPositions = offersAppleDisplayOptions && hardwareKeyboardMode == .keystrokes
        configuration.usesLegacyHardwareKeyboardMapping = hardwareKeyboardMode == .legacy
        configuration.usesLegacySoftwareKeyboardMapping = softwareKeyboardMode == .legacy
        configuration.swapsHardwareCommandAndControl = swapsHardwareCommandAndControl == true
        let localCursor = showsLocalCursor ?? (preferences.object(forKey: "connection.clientCursor") as? Bool ?? true)
        configuration.cursorRendering = localCursor && !configuration.disabledPortableCodecs.contains(.cursor) ? .client : .server
        configuration.usesFallbackCursor = usesFallbackCursor == true
        configuration.reconnectionPolicy.isEnabled = preferences.object(forKey: "connection.reconnect") as? Bool ?? true
        return configuration
    }
}

struct ConnectionEditor: View {
    let request: EditorRequest
    let library: ConnectionLibrary
    let tailnet: TailnetDirectory
    let privacy: AppLock
    let hiddenSources: HiddenSidebarItems
    let selectDevice: (Computer, UInt16?, Set<Endpoint>) -> Void
    let openLink: (String) throws -> Void
    let didSave: () -> Void
    let connect: (SessionRequest) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var host: String
    @State private var port: String
    #if targetEnvironment(macCatalyst)
    @State private var wakeAddressText: String
    #endif
    @State private var username: String
    @State private var password = ""
    @State private var authentication: DesktopAuthentication
    @State private var loadedAccount: Computer?
    @State private var remember = false
    @State private var choseRememberPassword = false
    @AppStorage("credentials.synchronize") private var synchronizeCredentials = false
    @State private var quality: PictureQuality
    @State private var colorDepth: ColorDepth
    @State private var framebuffer: FramebufferQuality
    @State private var disabledVNCCodecs: Set<Int32>
    @State private var disconnectAction: VNCDisconnectAction?
    @State private var savesDisconnectScreenshot: Bool
    @State private var layout: DisplayLayout
    @State private var rememberMonitor: Bool
    @State private var observe: Bool
    @State private var automaticallySharesClipboard: Bool?
    @State private var curtainsDisplayOnConnect: Bool
    @State private var curtainMessage: String
    @State private var sizing: DesktopSizing
    @State private var customWidth: String
    @State private var customHeight: String
    @State private var retina: Bool
    @State private var smoothVideo: Bool
    @State private var audio: Bool
    @State private var pointerMode: RemotePointerMode?
    @State private var cursorTrackingSpeed: Double?
    @State private var allowsViewportZoom: Bool
    @State private var initialViewportSizing: RemoteViewportSizing
    @State private var showsLocalCursor: Bool?
    @State private var usesFallbackCursor: Bool
    @AppStorage("connection.clientCursor") private var defaultShowsLocalCursor = true
    @State private var touchHoldDuration: TimeInterval?
    @AppStorage("gesture.holdDuration") private var defaultHoldDuration = RemoteTouchGestureConfiguration.defaultHoldDuration
    @State private var preparesTigerVNCKeyboard: Bool
    @State private var hardwareKeyboardMode: DesktopKeyboardMode
    #if !targetEnvironment(macCatalyst)
    @State private var legacySoftwareKeyboard: Bool
    #endif
    @State private var swapsHardwareCommandAndControl: Bool
    @State private var momentumScrolling: Bool
    @State private var allowsRemoteBell: Bool
    @State private var pcScrollSpeed: RemoteScrollSpeed
    @State private var useSSH: Bool
    @State private var secureLocally: Bool
    @State private var sshPort: String
    @State private var sshServer: String
    @State private var sshUser: String
    @State private var sshPassword = ""
    @State private var sshUseKey: Bool
    @State private var sshKey: String?
    @State private var awaitingKey = false
    @State private var keyImportID = UUID()
    @State private var keyNames: [String] = []
    @State private var selectedKeyName: String?
    @State private var loadedInitialCredentials = false
    @State private var restoredSSH: Computer?
    @State private var linkCredentialAccount: Computer?
    @State private var linkText = ""
    @State private var showsLinkInput = false
    @State private var showsDevicePicker = false
    @State private var error: String?
    @State private var showSettings = false
    @FocusState private var editingHost: Bool

    init(request: EditorRequest, library: ConnectionLibrary, tailnet: TailnetDirectory, privacy: AppLock,
         hiddenSources: HiddenSidebarItems,
         selectDevice: @escaping (Computer, UInt16?, Set<Endpoint>) -> Void, openLink: @escaping (String) throws -> Void,
         didSave: @escaping () -> Void, connect: @escaping (SessionRequest) -> Void) {
        self.request = request
        self.library = library
        self.tailnet = tailnet
        self.privacy = privacy
        self.hiddenSources = hiddenSources
        self.selectDevice = selectDevice
        self.openLink = openLink
        self.didSave = didSave
        self.connect = connect
        let c = request.computer
        let link = request.link
        let initial = c?.endpoint ?? (try? Endpoint(address: request.initialAddress))
        _name = State(initialValue: c?.name ?? "")
        _host = State(initialValue: initial?.host ?? request.initialAddress)
        _port = State(initialValue: String(initial?.port ?? 5900))
        #if targetEnvironment(macCatalyst)
        _wakeAddressText = State(initialValue: c?.wakeHardwareAddress?.text ?? "")
        #endif
        let desktopUser = (link?.sshPort == nil ? link?.username : nil) ?? c?.username ?? ""
        let tunnelUser = (link?.sshPort != nil ? link?.username : nil) ?? c?.ssh?.username ?? ""
        _authentication = State(initialValue: request.sharedOptions.authentication ?? c?.authentication ?? .automatic)
        _username = State(initialValue: desktopUser)
        _password = State(initialValue: link?.sshPort == nil ? link?.password ?? "" : "")
        let display = (c?.display(for: .current) ?? DesktopDisplayPreferences()).resolved(for: .current)
        let offeredQuality = request.sharedOptions.quality ?? display.quality
        _quality = State(initialValue: offeredQuality)
        _colorDepth = State(initialValue: display.colorDepth ?? .full)
        _framebuffer = State(initialValue: c?.framebufferQuality ?? FramebufferQuality())
        _disabledVNCCodecs = State(initialValue: Set(c?.disabledVNCCodecs ?? []))
        _disconnectAction = State(initialValue: c?.disconnectAction)
        _savesDisconnectScreenshot = State(initialValue: c?.savesDisconnectScreenshot == true)
        let initialLayout = display.layout
        _layout = State(initialValue: initialLayout)
        _rememberMonitor = State(initialValue: display.rememberMonitor != false)
        let observation = c.map { computer in
            request.purpose == .connect ? library.startsInObservation(computer) : computer.viewOnly
        }
        _observe = State(initialValue: request.sharedOptions.observe ?? link?.observe ?? observation ?? false)
        _automaticallySharesClipboard = State(initialValue: c?.automaticallySharesClipboard)
        _curtainsDisplayOnConnect = State(initialValue: c?.curtainsDisplayOnConnect == true)
        _curtainMessage = State(initialValue: c?.curtainMessage ?? "")
        let dimensions = display.fixedDesktop ?? .standard
        let initialSizing: DesktopSizing
        if initialLayout == .combined { initialSizing = .physical }
        else if initialLayout == .virtualPair || display.fixedDesktop != nil { initialSizing = .fixed }
        else if display.matchWindow || (c?.offersAppleDisplayOptions != false && request.sharedOptions.quality == .adaptive) {
            initialSizing = .dynamic
        }
        else { initialSizing = .physical }
        _sizing = State(initialValue: initialSizing)
        _customWidth = State(initialValue: String(dimensions.width))
        _customHeight = State(initialValue: String(dimensions.height))
        _retina = State(initialValue: display.retinaResolution ?? true)
        _smoothVideo = State(initialValue: display.smoothVideo ?? true)
        _audio = State(initialValue: display.remoteAudio)
        _pointerMode = State(initialValue: c?.pointerModeOverride)
        _cursorTrackingSpeed = State(initialValue: CursorTrackingSpeed.validated(c?.cursorTrackingSpeed))
        _allowsViewportZoom = State(initialValue: c?.allowsViewportZoom != false)
        _initialViewportSizing = State(initialValue: c?.initialViewportSizing ?? .fit)
        _showsLocalCursor = State(initialValue: c?.showsLocalCursor)
        _usesFallbackCursor = State(initialValue: c?.usesFallbackCursor == true)
        _touchHoldDuration = State(initialValue: c?.touchHoldDuration)
        _preparesTigerVNCKeyboard = State(initialValue: c?.preparesTigerVNCKeyboard == true)
        _hardwareKeyboardMode = State(initialValue: c?.hardwareKeyboardMode ?? .keystrokes)
        #if !targetEnvironment(macCatalyst)
        _legacySoftwareKeyboard = State(initialValue: c?.softwareKeyboardMode == .legacy)
        #endif
        _swapsHardwareCommandAndControl = State(initialValue: c?.swapsHardwareCommandAndControl == true)
        _momentumScrolling = State(initialValue: c?.momentumScrolling != false)
        _allowsRemoteBell = State(initialValue: c?.allowsRemoteBell != false)
        _pcScrollSpeed = State(initialValue: c?.pcScrollSpeed ?? .standard)
        _useSSH = State(initialValue: c?.ssh != nil || request.initialSSHPort != nil)
        _secureLocally = State(initialValue: c?.ssh?.secureLocally != false)
        _sshPort = State(initialValue: String(c?.ssh?.port ?? request.initialSSHPort ?? request.suggestedSSHPort ?? 22))
        _sshServer = State(initialValue: c?.ssh?.server ?? request.initialSSHServer ?? "")
        _sshUser = State(initialValue: tunnelUser)
        _sshPassword = State(initialValue: link?.sshPort != nil && link?.keyName == nil ? link?.password ?? "" : "")
        _sshUseKey = State(initialValue: link?.keyName != nil || c?.ssh?.usesKey == true)
        _selectedKeyName = State(initialValue: request.rejectedSSHCredential ? nil : link?.keyName ?? c?.ssh?.keyName)
        if let initial, let link, link.password != nil || link.keyName != nil {
            var owner = Computer(endpoint: initial)
            owner.username = desktopUser
            if let port = link.sshPort { owner.ssh = SSHSettings(port: port, username: tunnelUser, usesKey: link.keyName != nil) }
            _linkCredentialAccount = State(initialValue: owner)
        }
    }

    private var isSaving: Bool { request.purpose == .new || request.purpose == .edit }
    private var endpoint: Endpoint? {
        guard port.utf8.allSatisfy({ (48...57).contains($0) }), let port = UInt16(port), port != 0 else { return nil }
        return try? Endpoint(address: host, defaultPort: port)
    }
    private var desktopUsername: String {
        authentication.usesUsername ? username.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    private var remembersPassword: Binding<Bool> {
        Binding(get: { remember }, set: {
            remember = $0
            choseRememberPassword = $0
        })
    }

    private var canSubmit: Bool {
        guard endpoint != nil else { return false }
        #if targetEnvironment(macCatalyst)
        if isSaving, !useSSH, hasWakeAddress, !validWakeSettings { return false }
        #endif
        if !isSaving, authentication == .macUser, desktopUsername.isEmpty { return false }
        if selectedQuality == .adaptive, sizing == .fixed, fixedDimensions?.isSupported != true { return false }
        guard useSSH else { return true }
        if !sshServer.isEmpty, (try? Endpoint.hostOnly(sshServer)) == nil { return false }
        if sshUseKey && (awaitingKey || (selectedKeyName != nil && sshKey == nil)) { return false }
        guard let port = UInt16(sshPort), port > 0, !sshUser.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return isSaving || !sshUseKey || sshKey != nil
    }

    private var showsAppleOptions: Bool {
        let platform = request.platform(for: endpoint)
        return platform == nil || platform == .mac
    }

    private var selectedQuality: PictureQuality { !showsAppleOptions && quality == .adaptive ? .standard : quality }
    private var selectedHardwareKeyboard: DesktopKeyboardMode {
        !showsAppleOptions && hardwareKeyboardMode == .keystrokes ? .unicode : hardwareKeyboardMode
    }

    private var fixedDimensions: DesktopDimensions? {
        guard let width = Int(customWidth), let height = Int(customHeight) else { return nil }
        return DesktopDimensions(width: width, height: height)
    }

    private var title: String {
        switch request.purpose {
        case .quick: "快速连接"
        case .new: "新建连接"
        case .edit: "编辑连接"
        case .connect: request.computer?.displayName ?? "连接"
        }
    }

    private var connectionForm: some View {
        NavigationStack {
            Form {
                addressSection
                credentialSection
                sshSection
                #if targetEnvironment(macCatalyst)
                if isSaving, !useSSH { wakeSection }
                #endif
                if request.purpose != .quick { curtainSection }
                displaySection
                if isSaving {
                    SavedDesktopPreviewSettings(library: library, computerID: request.computer?.id,
                                                capturesOnDisconnect: $savesDisconnectScreenshot)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .accessibilityIdentifier("connection.form")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showsDevicePicker) {
                QuickConnectDevicePicker(tailnet: tailnet, privacy: privacy,
                                         showsNearby: offersNearbyDevices, showsTailnet: offersTailnetDevices,
                                         select: selectDevice)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "保存" : "连接", action: submit)
                        .disabled(!canSubmit)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("connection.submit")
                }
            }
        }
    }

    private var credentialAwareForm: some View {
        connectionForm.onAppear(perform: loadInitialCredentials)
        .onChange(of: host) { clearMismatchedPassword() }
        .onChange(of: port) { clearMismatchedPassword() }
        #if targetEnvironment(macCatalyst)
        .onChange(of: endpoint?.host) { _, destination in
            if let destination, let original = request.computer, destination != original.endpoint.host,
               WakeHardwareAddress(wakeAddressText) == original.wakeHardwareAddress {
                wakeAddressText = ""
            }
        }
        #endif
        .onChange(of: username) { clearMismatchedPassword() }
        .onChange(of: authentication) { previous, current in
            guard previous.usesPassword != current.usesPassword
                || (previous.usesUsername != current.usesUsername && !username.isEmpty) else { return }
            password = ""
            loadedAccount = nil
            if linkCredentialAccount?.ssh == nil { linkCredentialAccount = nil }
            remember = restoredSSH != nil
            choseRememberPassword = false
        }
        .onChange(of: sshUser) { clearMismatchedPassword() }
        .onChange(of: sshPort) { clearMismatchedPassword() }
        .onChange(of: sshServer) {
            clearMismatchedPassword()
            if selectedKeyName != nil { selectedKeyName = nil; sshKey = nil }
        }
        .onChange(of: useSSH) { clearMismatchedPassword() }
        .onChange(of: sshUseKey) { clearMismatchedPassword() }
    }

    var body: some View {
        credentialAwareForm
        .task(id: useSSH && sshUseKey) {
            guard useSSH, sshUseKey else { return }
            do { keyNames = try PasswordStore.keyNames(synchronize: synchronizeCredentials) }
            catch { self.error = error.localizedDescription }
        }
        .onChange(of: selectedQuality) {
            if selectedQuality != .adaptive, layout == .virtualPair { layout = .single }
            if selectedQuality != .adaptive, sizing == .fixed { sizing = .dynamic }
            if selectedQuality == .adaptive, layout == .single, sizing == .physical { sizing = .dynamic }
        }
        .onChange(of: layout) {
            if layout == .combined { sizing = .physical }
            if layout == .virtualPair { sizing = .fixed }
        }
        .onChange(of: editingHost) { _, focused in
            if !focused, let endpoint { host = endpoint.host; port = String(endpoint.port) }
        }
        .alert("打开连接链接", isPresented: $showsLinkInput) {
            SecureField("连接链接", text: $linkText)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("connection.linkText")
            Button("使用链接") { applyLink(linkText); linkText = "" }
                .disabled(linkText.isEmpty)
            Button("取消", role: .cancel) { linkText = "" }
        }
    }

    private func loadInitialCredentials() {
        guard !loadedInitialCredentials else { return }
        loadedInitialCredentials = true
        guard request.loadsStoredCredentials else { return }
        if let name = selectedKeyName { selectNamedKey(name) }
        if request.link?.username != nil || request.link?.password != nil || request.link?.keyName != nil { return }
        guard let original = request.computer else { return }
        if let stored = try? PasswordStore.read(original, synchronize: synchronizeCredentials) {
            loadedAccount = original
            password = stored
            remember = true
        }
        if !request.rejectedSSHCredential, let ssh = original.ssh, ssh.keyName == nil,
           let stored = try? PasswordStore.read(original, kind: ssh.usesKey ? .sshKey : .sshPassword, synchronize: synchronizeCredentials) {
            restoredSSH = original
            if ssh.usesKey { sshKey = stored } else { sshPassword = stored }
            remember = true
        }
    }

    private func applyLink(_ value: String) {
        do { try openLink(value) }
        catch let problem as EditorRequest.LinkError { error = problem.localizedDescription }
        catch { self.error = "无法识别这个连接链接。请检查地址和参数。" }
    }

    private var offersNearbyDevices: Bool { !hiddenSources.contains(.nearby) }
    private var offersTailnetDevices: Bool { !hiddenSources.contains(.tailscale) && tailnet.account != nil }

    private var addressSection: some View {
        Section {
            if isSaving { TextField("名称", text: $name).accessibilityIdentifier("connection.name") }
            TextField("地址", text: Binding(get: { host }, set: { value in
                if request.purpose == .quick, value.contains("://") {
                    if value.hasSuffix("://") { linkText = value; showsLinkInput = true }
                    else { applyLink(value) }
                } else { host = value }
            }))
                .focused($editingHost)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .accessibilityIdentifier("connection.host")
            TextField("端口", text: $port)
                .keyboardType(.numberPad)
                .accessibilityIdentifier("connection.port")
            if request.purpose == .quick {
                if request.allowsDeviceSelection && (offersNearbyDevices || offersTailnetDevices) {
                    Button {
                        editingHost = false
                        showsDevicePicker = true
                    } label: {
                        Label("选择电脑", systemImage: "desktopcomputer")
                    }
                    .accessibilityIdentifier("connection.chooseDevice")
                }
                Button("打开连接链接") { linkText = ""; showsLinkInput = true }
                    .accessibilityIdentifier("connection.openLink")
            }
            if !host.isEmpty && endpoint == nil {
                Text(UInt16(port) == nil || UInt16(port) == 0 ? "端口必须在 1 到 65535 之间。" : "请输入主机名或 IP 地址。").foregroundStyle(.red)
            }
        }
    }

    #if targetEnvironment(macCatalyst)
    private var hasWakeAddress: Bool { !wakeAddressText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var validWakeSettings: Bool {
        guard let endpoint, !endpoint.host.contains(":") else { return false }
        return WakeHardwareAddress(wakeAddressText) != nil
    }

    private var wakeSection: some View {
        Section {
            TextField("网卡的 MAC 地址（可选）", text: $wakeAddressText)
                .autocorrectionDisabled()
                .accessibilityIdentifier("connection.wakeMAC")
        } header: {
            Text("网络唤醒")
        } footer: {
            if hasWakeAddress, !validWakeSettings {
                Text("请输入有效的 MAC 地址，并使用电脑的主机名或局域网 IPv4 地址。")
                    .foregroundStyle(.red)
            } else {
                Text("填写后，连接时会尝试唤醒同一局域网内支持网络唤醒的电脑。")
            }
        }
    }
    #endif

    private var credentialSection: some View {
        Section {
            Picker("认证方式", selection: $authentication) {
                Text("自动协商").tag(DesktopAuthentication.automatic)
                Text("Mac 用户").tag(DesktopAuthentication.macUser)
                Text("VNC 密码").tag(DesktopAuthentication.vncPassword)
                Text("无认证").tag(DesktopAuthentication.unauthenticated)
                Text("Raspberry Pi · RSA-AES").tag(DesktopAuthentication.raspberryPiRSA)
            }.accessibilityIdentifier("connection.authentication")
            if authentication.usesUsername {
                TextField("用户名", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
                    .accessibilityIdentifier("connection.username")
            }
            if authentication.usesPassword {
                SecureField("密码", text: $password)
                    .textContentType(.password)
                    .accessibilityIdentifier("connection.password")
                Toggle("记住密码", isOn: remembersPassword).accessibilityIdentifier("connection.remember")
            }
        } header: {
            Text("身份验证")
        } footer: {
            if authentication == .macUser {
                Text("请使用远程 Mac 的登录用户名和密码。")
            } else if authentication == .unauthenticated {
                Text("服务器必须允许无认证连接。")
            }
        }
    }

    private var curtainSection: some View {
        Section {
            Toggle("连接时开启屏幕帘幕", isOn: $curtainsDisplayOnConnect)
                .accessibilityIdentifier("connection.autoCurtain")
            if curtainsDisplayOnConnect {
                TextField("远端提示（可选）", text: $curtainMessage, axis: .vertical)
                    .lineLimit(1...4)
                    .accessibilityIdentifier("connection.curtainMessage")
            }
        } footer: {
            Text("需要在远程 Mac 开启「远程管理」。")
        }
    }

    private var sshSection: some View {
        Section {
            Toggle("使用安全连接", isOn: $useSSH)
                .accessibilityIdentifier("connection.useSSH")
            if useSSH {
                Toggle("局域网内也使用 SSH", isOn: $secureLocally)
                    .accessibilityIdentifier("connection.secureLocally")
                TextField("SSH 服务器", text: $sshServer, prompt: Text("默认使用桌面地址"))
                    .keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .accessibilityIdentifier("connection.sshServer")
                TextField("端口", text: $sshPort).keyboardType(.numberPad).accessibilityIdentifier("connection.sshPort")
                TextField("用户名", text: $sshUser)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("connection.sshUsername")
                Toggle("SSH 密钥", isOn: $sshUseKey)
                if sshUseKey {
                    if let selectedKeyName { LabeledContent("当前密钥", value: selectedKeyName) }
                    if !keyNames.isEmpty {
                        Menu("选择已存密钥") {
                            ForEach(keyNames, id: \.self) { name in Button(name) { selectNamedKey(name) } }
                        }
                    }
                    SSHKeyImportFields(key: $sshKey, pending: $awaitingKey,
                                       onSelection: { _ in selectedKeyName = nil }, onError: { error = $0 })
                        .id(keyImportID)
                } else {
                    SecureField("密码", text: $sshPassword).textContentType(.password)
                        .accessibilityIdentifier("connection.sshPassword")
                }
                if !authentication.usesPassword {
                    Toggle("记住 SSH 凭据", isOn: $remember).accessibilityIdentifier("connection.rememberSSH")
                }
            }
        } header: {
            Text(verbatim: "SSH")
        } footer: {
            if useSSH, !secureLocally {
                Text("确认目标在当前局域网时直接连接，其他网络仍使用 SSH。")
            }
        }
    }

    private var displaySection: some View {
        Section {
            Toggle("仅观察", isOn: $observe).accessibilityIdentifier("connection.observe")
            Picker("自动共享剪贴板", selection: $automaticallySharesClipboard) {
                Text("跟随应用设置").tag(nil as Bool?)
                Text("开启").tag(true as Bool?)
                Text("关闭").tag(false as Bool?)
            }
            .accessibilityIdentifier("connection.sharedClipboard")
            Toggle("播放远程响铃", isOn: $allowsRemoteBell)
                .accessibilityIdentifier("connection.remoteBell")
            DisclosureGroup("显示器", isExpanded: $showSettings) {
                Picker("图像质量", selection: Binding(get: { selectedQuality }, set: { quality = $0 })) {
                    Text(VNCConfiguration.VideoQualityMode.standard.title).tag(PictureQuality.standard)
                    if showsAppleOptions { Text(VNCConfiguration.VideoQualityMode.adaptive.title).tag(PictureQuality.adaptive) }
                    Text(VNCConfiguration.VideoQualityMode.fullQuality.title).tag(PictureQuality.lossless)
                }
                .accessibilityIdentifier("connection.quality")
                if selectedQuality != .adaptive {
                    Picker("颜色深度", selection: $colorDepth) {
                        Text("低").tag(ColorDepth.low)
                        Text("中").tag(ColorDepth.medium)
                        Text("高").tag(ColorDepth.full)
                    }
                }
                if selectedQuality == .standard, colorDepth == .full {
                    if showsAppleOptions {
                        imagePolicy("Mac 自适应画质", selection: $framebuffer.adaptive)
                            .accessibilityIdentifier("connection.adaptiveQuality")
                    }
                    imagePolicy("图像压缩", selection: $framebuffer.compression)
                        .accessibilityIdentifier("connection.tightCompression")
                    tightJPEGQualitySlider
                        .disabled(framebuffer.compression == .never
                                  || disabledVNCCodecs.contains(PortableFramebufferCodec.tight.rawValue))
                }
                DisclosureGroup("VNC 编码") {
                    ForEach(PortableFramebufferCodec.allCases, id: \.rawValue) { codec in
                        Toggle(isOn: Binding(
                            get: { !disabledVNCCodecs.contains(codec.rawValue) },
                            set: { enabled in
                                if enabled { disabledVNCCodecs.remove(codec.rawValue) }
                                else { disabledVNCCodecs.insert(codec.rawValue) }
                            }
                        )) { Text(verbatim: codec.title) }
                        .accessibilityIdentifier("connection.codec." + String(codec.rawValue))
                    }
                    Text("允许远端使用所选编码。某些编码取决于远端服务和颜色深度。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Picker("显示器", selection: $layout) {
                    Text(VNCConfiguration.DisplayMode.oneDisplay.title).tag(DisplayLayout.single)
                    Text(VNCConfiguration.DisplayMode.allDisplaysCombined.title).tag(DisplayLayout.combined)
                    #if targetEnvironment(macCatalyst)
                    if selectedQuality == .adaptive {
                        Text(VNCConfiguration.DisplayMode.twoVirtualDisplays.title).tag(DisplayLayout.virtualPair)
                    }
                    #endif
                }
                Toggle("记住上次选择的显示器", isOn: $rememberMonitor)
                Picker("连接时缩放", selection: $initialViewportSizing) {
                    #if targetEnvironment(macCatalyst)
                    ForEach(RemoteViewportSizing.allCases, id: \.rawValue) { mode in
                        Text(mode.macTitle).tag(mode)
                    }
                    #else
                    Text("适合屏幕").tag(RemoteViewportSizing.fit)
                    Text("填满屏幕").tag(RemoteViewportSizing.fill)
                    Text("实际大小").tag(RemoteViewportSizing.actualSize)
                    #endif
                }
                .accessibilityIdentifier("connection.initialViewportSizing")
                Toggle("允许捏合缩放", isOn: $allowsViewportZoom)
                    .accessibilityIdentifier("connection.viewportZoom")
                if selectedQuality == .adaptive {
                    Picker("桌面尺寸", selection: $sizing) {
                        Text(VNCConfiguration.DisplaySizingMode.remoteDisplay.title).tag(DesktopSizing.physical)
                        Text("动态").tag(DesktopSizing.dynamic)
                        Text("固定").tag(DesktopSizing.fixed)
                    }.disabled(layout != .single)
                    if sizing == .fixed {
                        dimensionField("宽度", value: $customWidth)
                        dimensionField("高度", value: $customHeight)
                    }
                    if sizing != .physical { Toggle("Retina 分辨率", isOn: $retina) }
                    if useSSH {
                        Text("SSH 连接使用标准画面更新。桌面尺寸和 Retina 设置仍然有效。")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Toggle("流畅视频与音频", isOn: $smoothVideo)
                            .accessibilityIdentifier("connection.smoothVideo")
                        if smoothVideo, let item = request.computer, let retry = library.videoRetryDate(for: item) {
                            LabeledContent("流畅视频与音频将恢复", value: retry.formatted(date: .abbreviated, time: .shortened))
                            Button("立即恢复流畅视频与音频") { library.resumeStreaming(for: item) }
                                .accessibilityIdentifier("connection.resumeVideo")
                        }
                        if smoothVideo { Toggle("远程音频", isOn: $audio).disabled(sizing == .physical) }
                    }
                } else {
                    Toggle("调整远程分辨率", isOn: Binding(get: { sizing != .physical }, set: { sizing = $0 ? .dynamic : .physical }))
                        .disabled(layout != .single)
                }
                #if targetEnvironment(macCatalyst)
                Toggle("触控板", isOn: Binding(
                    get: { pointerMode == .trackpad },
                    set: { pointerMode = $0 ? .trackpad : .direct }
                ))
                .accessibilityIdentifier("connection.trackpad")
                #else
                Picker("光标模式", selection: $pointerMode) {
                    Text("跟随应用设置").tag(nil as RemotePointerMode?)
                    Text("直接触控").tag(RemotePointerMode.direct as RemotePointerMode?)
                    Text("触控板").tag(RemotePointerMode.trackpad as RemotePointerMode?)
                }
                .accessibilityIdentifier("connection.pointerMode")
                #endif
                CursorTrackingSpeedPicker(selection: $cursorTrackingSpeed)
                    .accessibilityIdentifier("connection.cursorTrackingSpeed")
                Picker("光标显示", selection: $showsLocalCursor) {
                    Text("跟随应用设置").tag(nil as Bool?)
                    Text("使用本地光标").tag(true as Bool?)
                    Text("使用远程光标").tag(false as Bool?)
                }
                .accessibilityIdentifier("connection.cursor")
                Toggle("使用备用光标", isOn: $usesFallbackCursor)
                    .disabled(!(showsLocalCursor ?? defaultShowsLocalCursor)
                              || disabledVNCCodecs.contains(PortableFramebufferCodec.cursor.rawValue))
                    .accessibilityIdentifier("connection.fallbackCursor")
                #if !targetEnvironment(macCatalyst)
                Toggle("单独设置长按拖动延迟", isOn: Binding(
                    get: { touchHoldDuration != nil },
                    set: { touchHoldDuration = $0 ? defaultHoldDuration : nil }
                ))
                .accessibilityIdentifier("connection.customDragDelay")
                if let delay = touchHoldDuration {
                    let effective = RemoteTouchGestureConfiguration(holdDuration: delay).resolvedHoldDuration
                    LabeledContent("长按拖动延迟", value: "\(effective.formatted(.number.precision(.fractionLength(2)))) 秒")
                    Slider(value: Binding(get: { effective }, set: { touchHoldDuration = $0 }),
                           in: RemoteTouchGestureConfiguration.holdDurationRange, step: 0.05) {
                        Text("长按拖动延迟")
                    }
                    .accessibilityIdentifier("connection.dragDelay")
                }
                #endif
                Picker("PC 滚动速度", selection: $pcScrollSpeed) {
                    ForEach(RemoteScrollSpeed.allCases, id: \.self) { speed in
                        Text(verbatim: Double(speed.multiplier).formatted() + "×").tag(speed)
                    }
                }
                .disabled(observe)
                .accessibilityIdentifier("connection.pcScrollSpeed")
                Picker("实体键盘", selection: Binding(get: { selectedHardwareKeyboard }, set: { hardwareKeyboardMode = $0 })) {
                    if showsAppleOptions { Text("按远端键位输入（Mac）").tag(DesktopKeyboardMode.keystrokes) }
                    Text("发送本地字符").tag(DesktopKeyboardMode.unicode)
                    Text("旧版键盘映射").tag(DesktopKeyboardMode.legacy)
                }
                .disabled(observe)
                .accessibilityIdentifier("connection.hardwareKeyboard")
                #if !targetEnvironment(macCatalyst)
                Picker("屏幕键盘", selection: $legacySoftwareKeyboard) {
                    Text("发送本地字符").tag(false)
                    Text("旧版键盘映射").tag(true)
                }
                .disabled(observe)
                .accessibilityIdentifier("connection.softwareKeyboard")
                #endif
                Toggle(isOn: $preparesTigerVNCKeyboard) {
                    VStack(alignment: .leading) {
                        Text("兼容 TigerVNC 首字输入")
                        Text("首个按键是 Unicode 扩展字符时，先轻按一次 Shift。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(observe)
                .accessibilityIdentifier("connection.tigerKeyboard")
                Toggle("互换实体键盘的 Command 和 Control", isOn: $swapsHardwareCommandAndControl)
                    .disabled(observe)
                    .accessibilityIdentifier("connection.swapCommandControl")
                #if !targetEnvironment(macCatalyst)
                if showsAppleOptions {
                    Toggle("连接 Mac 时使用惯性滚动", isOn: $momentumScrolling)
                        .accessibilityIdentifier("connection.momentum")
                }
                #endif
            }
            if isSaving || request.computer?.disconnectAction != nil {
                Picker("断开时", selection: $disconnectAction) {
                    Text("无操作").tag(nil as VNCDisconnectAction?)
                    ForEach(VNCDisconnectAction.allCases, id: \.self) { action in
                        Text(action.label).tag(Optional(action))
                    }
                }
                .disabled(observe)
            }
        }
    }

    private func dimensionField(_ label: LocalizedStringKey, value: Binding<String>) -> some View {
        LabeledContent(label) {
            TextField(label, text: value)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
        }
    }

    private func imagePolicy(_ title: LocalizedStringKey, selection: Binding<FramebufferQuality.Scope>) -> some View {
        Picker(title, selection: selection) {
            Text("始终启用").tag(FramebufferQuality.Scope.always)
            Text("仅远程连接时启用").tag(FramebufferQuality.Scope.remoteOnly)
            Text("永不启用").tag(FramebufferQuality.Scope.never)
        }
    }

    private var tightJPEGQualitySlider: some View {
        let quality = framebuffer.resolvedTightJPEGQuality
        let levels = FramebufferQuality.tightJPEGQualityRange
        let value = Binding(
            get: { Double(framebuffer.resolvedTightJPEGQuality) },
            set: { value in
                let level = Int(value.rounded())
                framebuffer.tightJPEGQuality = level == FramebufferQuality.defaultTightJPEGQuality ? nil : level
            }
        )
        return VStack(alignment: .leading) {
            LabeledContent("TightVNC JPEG 画质", value: quality.formatted())
            Slider(value: value, in: Double(levels.lowerBound)...Double(levels.upperBound), step: 1) {
                Text("TightVNC JPEG 画质")
            }
            .accessibilityValue(quality.formatted())
            .accessibilityIdentifier("connection.tightJPEGQuality")
        }
    }

    private func selectNamedKey(_ name: String) {
        selectedKeyName = name
        awaitingKey = false
        keyImportID = UUID()
        sshKey = nil
        restoredSSH = nil
        do {
            guard let key = try PasswordStore.namedKey(name, synchronize: synchronizeCredentials) else {
                throw PasswordStore.NamedKeyError.missingKey
            }
            sshKey = key
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func clearMismatchedPassword() {
        let server = useSSH && !sshServer.isEmpty ? (try? Endpoint.hostOnly(sshServer)) ?? sshServer : nil
        if let owner = linkCredentialAccount {
            if let ssh = owner.ssh {
                if !useSSH || ssh.server != server || owner.endpoint.host != endpoint?.host || ssh.port != UInt16(sshPort) ||
                    ssh.username != sshUser || ssh.usesKey != sshUseKey {
                    sshPassword = ""
                    sshKey = nil
                    selectedKeyName = nil
                    linkCredentialAccount = nil
                }
            } else if owner.endpoint != endpoint || owner.username != username || server != nil {
                password = ""
                linkCredentialAccount = nil
            }
        }
        if let stored = restoredSSH, !useSSH || stored.ssh?.server != server || stored.endpoint.host != endpoint?.host ||
            stored.ssh?.port != UInt16(sshPort) || stored.ssh?.username != sshUser || stored.ssh?.usesKey != sshUseKey {
            sshPassword = ""
            sshKey = nil
            awaitingKey = false
            keyImportID = UUID()
            restoredSSH = nil
        }
        guard let stored = loadedAccount else { return }
        let routeChanged = stored.ssh?.server != server ||
            (server != nil && (stored.ssh?.port != UInt16(sshPort) || stored.ssh?.username != sshUser))
        guard routeChanged || stored.endpoint != endpoint || stored.username != username else { return }
        password = ""
        remember = false
        loadedAccount = nil
    }

    private func submit() {
        guard canSubmit, let endpoint else { return }
        var entry = request.computer ?? Computer(endpoint: endpoint)
        entry.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.desktopPlatform = request.platform(for: endpoint)
        if entry.endpoint.host != endpoint.host { entry.wakeHardwareAddress = nil }
        #if targetEnvironment(macCatalyst)
        if isSaving, !useSSH { entry.wakeHardwareAddress = WakeHardwareAddress(wakeAddressText) }
        #endif
        entry.endpoint = endpoint
        entry.username = desktopUsername
        entry.authentication = authentication
        if isSaving || request.purpose == .quick { entry.viewOnly = observe }
        entry.automaticallySharesClipboard = automaticallySharesClipboard
        entry.curtainsDisplayOnConnect = curtainsDisplayOnConnect ? true : nil
        entry.curtainMessage = curtainMessage.isEmpty ? nil : curtainMessage
        entry.disconnectAction = disconnectAction
        entry.savesDisconnectScreenshot = savesDisconnectScreenshot ? true : nil
        var display = DesktopDisplayPreferences(
            quality: selectedQuality, colorDepth: colorDepth == .full ? nil : colorDepth,
            layout: selectedQuality != .adaptive && layout == .virtualPair ? .single : layout,
            matchWindow: sizing != .physical, fixedDesktop: selectedQuality == .adaptive && sizing == .fixed ? fixedDimensions : nil,
            retinaResolution: retina ? nil : false, smoothVideo: smoothVideo ? nil : false, remoteAudio: audio)
        display.rememberMonitor = rememberMonitor ? nil : false
        if rememberMonitor {
            let old = entry.display(for: .current)
            display.lastMonitor = old.lastMonitor
            display.windowedMonitors = old.windowedMonitors
        }
        entry.setDisplay(display, for: .current, explicit: true)
        entry.pointerModeOverride = pointerMode
        entry.cursorTrackingSpeed = cursorTrackingSpeed
        entry.allowsViewportZoom = allowsViewportZoom ? nil : false
        entry.initialViewportSizing = initialViewportSizing == .fit ? nil : initialViewportSizing
        entry.showsLocalCursor = showsLocalCursor
        entry.usesFallbackCursor = usesFallbackCursor ? true : nil
        entry.touchHoldDuration = touchHoldDuration
        entry.preparesTigerVNCKeyboard = preparesTigerVNCKeyboard ? true : nil
        entry.hardwareKeyboardMode = selectedHardwareKeyboard
        #if !targetEnvironment(macCatalyst)
        if legacySoftwareKeyboard != (entry.softwareKeyboardMode == .legacy) {
            entry.softwareKeyboardMode = legacySoftwareKeyboard ? .legacy : .unicode
        }
        #endif
        entry.swapsHardwareCommandAndControl = swapsHardwareCommandAndControl ? true : nil
        entry.framebufferQuality = framebuffer == FramebufferQuality() ? nil : framebuffer
        entry.disabledVNCCodecs = disabledVNCCodecs.isEmpty ? nil : disabledVNCCodecs.sorted()
        entry.momentumScrolling = momentumScrolling ? nil : false
        entry.allowsRemoteBell = allowsRemoteBell ? nil : false
        entry.pcScrollSpeed = pcScrollSpeed == .standard ? nil : pcScrollSpeed
        let selectedSecret = sshUseKey ? sshKey : sshPassword
        let kind: PasswordStore.Kind = sshUseKey ? .sshKey : .sshPassword
        if useSSH {
            guard let number = UInt16(sshPort), number > 0 else { return }
            let server: String?
            do { server = sshServer.isEmpty ? nil : try Endpoint.hostOnly(sshServer) }
            catch { self.error = URLError(.badURL).localizedDescription; return }
            entry.ssh = SSHSettings(port: number, username: sshUser.trimmingCharacters(in: .whitespacesAndNewlines),
                                    usesKey: sshUseKey, keyName: sshUseKey ? selectedKeyName : nil, server: server,
                                    secureLocally: secureLocally ? nil : false)
        } else { entry.ssh = nil }
        if isSaving {
            entry.saved = true
            if request.computer == nil { entry.folder = request.folder }
            guard library.saveEditedConnection(entry) else { error = library.errorMessage; return }
            do {
                // An SSH-only credential may have turned on Remember Password when the editor opened.
                let savesDesktopPassword = authentication.usesPassword && remember
                    && (!password.isEmpty || loadedAccount != nil || choseRememberPassword)
                if savesDesktopPassword || loadedAccount != nil {
                    try PasswordStore.write(savesDesktopPassword ? password : nil, for: entry, synchronize: synchronizeCredentials)
                }
                if useSSH, entry.ssh?.keyName == nil, remember || restoredSSH != nil {
                    try PasswordStore.write(remember ? selectedSecret : nil, for: entry, kind: kind, synchronize: synchronizeCredentials)
                }
                didSave()
                dismiss()
            } catch { self.error = error.localizedDescription }
        } else {
            if request.computer == nil { entry.saved = false }
            entry = entry.forConnectionAttempt(from: request.computer)
            if request.purpose == .quick || request.link != nil { entry.openedFromLink = true }
            if !remember, let loadedAccount {
                do { try PasswordStore.write(nil, for: loadedAccount, synchronize: synchronizeCredentials) }
                catch { self.error = error.localizedDescription; return }
            }
            do {
                let desktopPassword = authentication.usesPassword ? password : ""
                var offer = SessionRequest(computer: entry, password: desktopPassword, rememberPassword: remember,
                                           synchronizeCredentials: synchronizeCredentials, initialObservation: observe,
                                           remembersObservation: request.remembersObservation
                                               && request.purpose == .connect && request.link == nil)
                if useSSH {
                    if sshUseKey {
                        guard let sshKey else { return }
                        offer.sshProof = .privateKey(try SSHKeyFile.identity(sshKey))
                    } else { offer.sshProof = .password(sshPassword) }
                    if remember, entry.ssh?.keyName == nil { offer.sshSecretToRemember = selectedSecret }
                    else if let restoredSSH { try PasswordStore.write(nil, for: restoredSSH, kind: kind, synchronize: synchronizeCredentials) }
                }
                connect(offer)
            } catch { self.error = error.localizedDescription }
        }
    }
}
