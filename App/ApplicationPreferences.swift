import SwiftUI
import UniformTypeIdentifiers
import rootshellVNC

struct ApplicationPreferences: View {
    let preferences: UserDefaults
    @Environment(AppLock.self) private var privacy
    @Environment(\.dismiss) private var dismiss
    @AppStorage("connection.reconnect") private var reconnect = true
    @AppStorage("connection.files") private var transfers = true
    @AppStorage(SyncedPreference.sharedClipboard.rawValue) private var sharedClipboard = true
    @AppStorage("connection.clientCursor") private var clientCursor = true
    @AppStorage("pointer.speed") private var pointerSpeed = 1.0
    @AppStorage("keyboard.localOptionKey") private var localOptionKey = VNCLocalOptionKey.off
    #if targetEnvironment(macCatalyst)
    @AppStorage(MacConnectionTabs.preference) private var connectionTabs = MacConnectionTabs.system
    #else
    @AppStorage("keyboard.commandReturnSwitchesApps") private var commandReturnSwitchesApps = false
    #endif
    @AppStorage(SyncedPreference.pointerMode.rawValue) private var pointerMode = RemotePointerMode.direct
    @AppStorage("gesture.upFingers") private var upFingers = RemoteSwipeFingers.three
    @AppStorage("gesture.downFingers") private var downFingers = RemoteSwipeFingers.three
    @AppStorage("gesture.horizontalFingers") private var horizontalFingers = RemoteSwipeFingers.three
    @AppStorage("gesture.holdDuration") private var holdDuration = RemoteTouchGestureConfiguration.defaultHoldDuration

    var body: some View {
        NavigationStack {
            Form {
                Section("外观") {
                    NavigationLink("侧栏") { LibrarySidebarPreferences() }
                        .accessibilityIdentifier("preferences.sidebar")
                }
                Section("连接") {
                    Toggle("自动重新连接", isOn: $reconnect)
                    Toggle("允许文件传输", isOn: $transfers).accessibilityIdentifier("preferences.transfers")
                    Toggle("新连接默认共享剪贴板", isOn: $sharedClipboard).accessibilityIdentifier("preferences.sharedClipboard")
                    ClipboardNotificationPreferences()
                    #if targetEnvironment(macCatalyst)
                    Picker("连接标签页", selection: $connectionTabs) {
                        Text("遵循系统设置").tag(MacConnectionTabs.system)
                        Text("始终打开独立窗口").tag(MacConnectionTabs.never)
                    }
                    .accessibilityIdentifier("preferences.connectionTabs")
                    MacVNCLinkPreferences()
                    #endif
                }
                #if targetEnvironment(macCatalyst)
                MacAvailabilityPreferences()
                #endif
                LibrarySyncPreferences()
                Section {
                    NavigationLink("连接库备份") { LibraryBackupPreferences() }
                        .accessibilityIdentifier("preferences.backups")
                }
                Section("控制方式") {
                    Toggle("使用本地光标", isOn: $clientCursor)
                    #if !targetEnvironment(macCatalyst)
                    Picker("默认光标模式", selection: $pointerMode) {
                        Text("直接触控").tag(RemotePointerMode.direct)
                        Text("触控板").tag(RemotePointerMode.trackpad)
                    }
                    .accessibilityIdentifier("preferences.pointerMode")
                    NavigationLink("互动工具栏") { ToolbarPreferences() }
                        .accessibilityIdentifier("preferences.toolbar")
                    NavigationLink("键盘重复") { KeyRepeatPreferences() }
                        .accessibilityIdentifier("preferences.keyRepeat")
                    Toggle("用 Command–Return 切换远程 Mac 的应用", isOn: $commandReturnSwitchesApps)
                        .accessibilityIdentifier("preferences.remoteAppSwitcher")
                    VStack(alignment: .leading) {
                        Text("光标跟踪速度")
                        Slider(value: $pointerSpeed, in: 0.5...3.0, step: 0.25) {
                            Text("光标跟踪速度")
                        }.accessibilityValue(pointerSpeed.formatted(.number.precision(.fractionLength(0...2))))
                    }
                    #endif
                    Picker("Option 输入特殊字符", selection: $localOptionKey) {
                        Text("keyboard.local-option.off").tag(VNCLocalOptionKey.off)
                        Text("左侧 Option").tag(VNCLocalOptionKey.left)
                        Text("右侧 Option").tag(VNCLocalOptionKey.right)
                    }
                    .accessibilityIdentifier("preferences.localOptionKey")
                }
                #if !targetEnvironment(macCatalyst)
                PencilPreferences()
                Section("多点触控") {
                    VStack(alignment: .leading) {
                        LabeledContent("长按拖动延迟", value: "\(holdDuration.formatted(.number.precision(.fractionLength(2)))) 秒")
                        Slider(value: $holdDuration, in: RemoteTouchGestureConfiguration.holdDurationRange, step: 0.05) {
                            Text("长按拖动延迟")
                        }
                        .accessibilityIdentifier("preferences.dragDelay")
                        .accessibilityValue("\(holdDuration.formatted(.number.precision(.fractionLength(2)))) 秒")
                    }
                    fingers("向上滑动", $upFingers)
                    fingers("向下滑动", $downFingers)
                    fingers("向左或向右滑动", $horizontalFingers)
                }
                #endif
                Section("隐私") {
                    NavigationLink("连接诊断") { SupportDiagnosticsView() }
                        .accessibilityIdentifier("preferences.diagnostics")
                    NavigationLink("SSH 密钥") { SSHKeyPreferences() }.accessibilityIdentifier("preferences.sshKeys")
                    NavigationLink("已信任的主机") { TrustedHostPreferences(preferences: preferences) }
                    Toggle("身份验证", isOn: Binding(get: { privacy.enabled }, set: { new in Task { await privacy.setEnabled(new) } }))
                        .disabled(privacy.authenticating)
                    if let error = privacy.error { Text(error).foregroundStyle(.red) }
                }
                Section("输入用户密码") {
                    Toggle("身份验证", isOn: Binding(get: { privacy.passwordProtection }, set: { new in
                        Task { await privacy.setPasswordProtection(new) }
                    })).disabled(privacy.authenticating)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { dismiss() } } }
        }
    }

    private func fingers(_ title: LocalizedStringKey, _ selection: Binding<RemoteSwipeFingers>) -> some View {
        Picker(title, selection: selection) {
            Text("关闭").tag(RemoteSwipeFingers.off)
            Text("三指").tag(RemoteSwipeFingers.three)
            Text("四指").tag(RemoteSwipeFingers.four)
        }
    }
}

private struct LibrarySidebarPreferences: View {
    @AppStorage(HiddenSidebarItems.preferenceKey) private var hiddenSidebarItems = 0
    @AppStorage("library.showsNearbyCount") private var showsNearbyCount = true

    var body: some View {
        Form {
            Section("显示在侧栏") {
                option("附近", .nearby, id: "nearby")
                option("Tailscale", .tailscale, id: "tailscale")
                option("所有链接", .links, id: "links")
                option("最近连接", .recent, id: "recent")
                option("收藏", .favorites, id: "favorites")
            }
            if UIDevice.current.userInterfaceIdiom == .phone {
                Section {
                    Toggle("显示附近设备数量", isOn: $showsNearbyCount)
                        .disabled(HiddenSidebarItems(rawValue: hiddenSidebarItems).contains(.nearby))
                        .accessibilityIdentifier("preferences.sidebar.nearbyCount")
                }
            }
        }
        .navigationTitle("侧栏")
    }

    private func option(_ title: LocalizedStringKey, _ item: HiddenSidebarItems, id: String) -> some View {
        Toggle(title, isOn: Binding(
            get: { !HiddenSidebarItems(rawValue: hiddenSidebarItems).contains(item) },
            set: { visible in
                var hidden = HiddenSidebarItems(rawValue: hiddenSidebarItems)
                if visible { hidden.remove(item) } else { hidden.insert(item) }
                hiddenSidebarItems = hidden.rawValue
            }
        ))
        .accessibilityIdentifier("preferences.sidebar." + id)
    }
}

#if !targetEnvironment(macCatalyst)
private struct KeyRepeatPreferences: View {
    @AppStorage("keyboard.repeat") private var enabled = true
    @AppStorage("keyboard.delay") private var delay = VNCKeyRepeat().delay
    @AppStorage("keyboard.interval") private var interval = VNCKeyRepeat().interval

    var body: some View {
        Form {
            Toggle("按住时重复", isOn: $enabled).accessibilityIdentifier("repeat.enabled")
            if enabled {
                slider("开始前延迟", value: $delay, range: VNCKeyRepeat.delayRange, id: "repeat.delay")
                slider("重复间隔", value: $interval, range: VNCKeyRepeat.intervalRange, id: "repeat.interval")
            }
        }
        .navigationTitle("键盘重复")
    }

    private func slider(_ title: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>, id: String) -> some View {
        VStack(alignment: .leading) {
            LabeledContent(title, value: "\(Int((value.wrappedValue * 1000).rounded())) 毫秒")
            Slider(value: value, in: range, step: 0.005) { Text(title) }
                .accessibilityValue("\(Int((value.wrappedValue * 1000).rounded())) 毫秒")
                .accessibilityIdentifier(id)
        }
    }
}
#endif

private struct LibrarySyncPreferences: View {
    @Environment(ConnectionLibrary.self) private var library
    @Environment(LibrarySync.self) private var sync
    @State private var choosing = false
    @AppStorage("credentials.synchronize") private var synchronizeCredentials = false

    var body: some View {
        Section {
            Button("选择同步文件夹") { choosing = true }
            if let folder = sync.folderName {
                LabeledContent("文件夹", value: folder)
                if let location = sync.folderLocation {
                    LabeledContent("位置") {
                        if location == .iCloudDrive { Text("iCloud 云盘") } else { Text("本机") }
                    }
                }
                LabeledContent {
                    if let date = sync.lastSync { Text(date.formatted(date: .abbreviated, time: .shortened)) }
                    else { Text("尚未同步") }
                } label: {
                    if sync.folderLocation == .localDocuments { Text("上次写入本机") } else { Text("上次同步") }
                }
                Button { Task { await sync.refresh(library) } } label: {
                    HStack { Text("立即同步"); if sync.running { ProgressView() } }
                }.disabled(sync.running)
                Button("在这台设备上停止同步") {
                    do { try sync.stop() } catch { sync.error = error.localizedDescription }
                }
                .disabled(sync.running)
            }
            if let error = sync.error { Text(error).foregroundStyle(.red) }
        } header: { Text("连接库同步") } footer: {
            if sync.folderLocation == .localDocuments {
                Text("当前文件夹在本机。要跨设备同步，请在两台设备上选择 iCloud 云盘中的同一文件夹。")
            } else {
                Text("在两台设备上选择 iCloud 云盘中的同一文件夹，即可同步连接、文件夹和操作偏好。")
            }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { selection in
            do {
                try sync.select(selection.get())
                Task { await sync.refresh(library) }
            } catch let error as CocoaError where error.code == .userCancelled {
            } catch { sync.error = error.localizedDescription }
        }
        Section {
            Toggle("通过 iCloud 钥匙串同步凭据", isOn: $synchronizeCredentials)
                .accessibilityIdentifier("preferences.keychainSync")
        } footer: {
            Text("开启后，保存或移除的远程密码和 SSH 密钥会同步到同一 iCloud 钥匙串。已有本机凭据在下次保存时同步。关闭后仅使用本机凭据。")
        }
    }
}

private struct TrustedHostPreferences: View {
    let preferences: UserDefaults
    @State private var entries: [HostFingerprint] = []
    @State private var removing: HostFingerprint?

    var body: some View {
        List(entries) { entry in
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: entry.kind.rawValue.uppercased() + " · " + entry.displayAddress).font(.headline)
                Text(verbatim: entry.fingerprint).font(.footnote.monospaced()).textSelection(.enabled)
                Button("忘记主机指纹", role: .destructive) { removing = entry }
                    .buttonStyle(.borderless)
            }
        }
        .navigationTitle("已信任的主机")
        .onAppear { entries = HostTrust.saved(in: preferences) }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            entries = HostTrust.saved(in: preferences)
        }
        .alert("忘记主机指纹", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { entry in
            Button("取消", role: .cancel) {}
            Button("忘记主机指纹", role: .destructive) {
                HostTrust.forget(entry, in: preferences)
                entries = HostTrust.saved(in: preferences)
            }
        } message: { entry in Text(verbatim: entry.displayAddress + "\n" + entry.fingerprint) }
    }
}

struct PrivacyGate: View {
    let privacy: AppLock

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(verbatim: AppName.display).font(.headline)
            Button("身份验证") { Task { await privacy.unlock() } }
                .buttonStyle(.borderedProminent).disabled(privacy.authenticating)
            if let error = privacy.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .accessibilityElement(children: .contain)
    }
}

/// A scene can already be presenting a sheet when the app moves to the
/// background. Cover the scene's sheets as well as its library and desktop.
struct PrivacyCover: UIViewRepresentable {
    let privacy: AppLock

    func makeUIView(context: Context) -> Anchor { Anchor() }
    func updateUIView(_ view: Anchor, context: Context) {
        view.update(privacy, locked: privacy.locked)
    }
    static func dismantleUIView(_ view: Anchor, coordinator: ()) { view.removeCover() }

    final class Anchor: UIView {
        private var privacy: AppLock?
        private var cover: UIWindow?
        private var locked = false

        override func didMoveToWindow() { super.didMoveToWindow(); updateCover() }
        func update(_ model: AppLock, locked: Bool) {
            self.privacy = model
            self.locked = locked
            updateCover()
        }
        func removeCover() {
            let wasKey = cover?.isKeyWindow == true
            cover?.isHidden = true
            cover?.rootViewController = nil
            cover = nil
            if wasKey, let window, !window.isHidden { window.makeKey() }
        }
        private func updateCover() {
            guard locked, let scene = window?.windowScene, let privacy else { removeCover(); return }
            guard cover == nil else { return }
            let shield = UIWindow(windowScene: scene)
            shield.windowLevel = .alert + 1
            let controller = UIHostingController(rootView: PrivacyGate(privacy: privacy))
            controller.view.accessibilityViewIsModal = true
            shield.rootViewController = controller
            cover = shield
            shield.makeKeyAndVisible()
        }
    }
}
