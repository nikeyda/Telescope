import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

private let vncLocationType = UTType(filenameExtension: "vncloc") ?? UTType(importedAs: "com.apple.vnc-internet-location")

private struct LibraryConnectionDrag: Codable, Transferable {
    let computerID: UUID
    let scope: LibraryFolderScope

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType(exportedAs: "local.nikey.desklink.connection-drag", conformingTo: .json))
            .visibility(.ownProcess)
    }
}

struct HiddenSidebarItems: OptionSet {
    static let preferenceKey = "library.hiddenSidebarItems"

    let rawValue: Int
    static let nearby = Self(rawValue: 1 << 0)
    static let tailscale = Self(rawValue: 1 << 1)
    static let links = Self(rawValue: 1 << 2)
    static let recent = Self(rawValue: 1 << 3)
    static let favorites = Self(rawValue: 1 << 4)
    static let linkSection: Self = [.links, .recent, .favorites]
}

enum CollectionPage: Codable, Hashable {
    case all, recent, links, favorites, nearby, tailscale, folder(String), linkFolder(String)
    #if targetEnvironment(macCatalyst)
    case remoteAccess
    #endif

    static func startup(computers: [Computer], hiddenItems: HiddenSidebarItems) -> Self {
        if hiddenItems.contains(.recent) || computers.contains(where: \.saved) { return .all }
        return .recent
    }

    var title: Text {
        switch self {
        case .all: Text("所有连接")
        case .recent: Text("最近连接")
        case .links: Text("所有链接")
        case .favorites: Text("收藏")
        case .nearby: Text("附近")
        case .tailscale: Text("Tailscale")
        #if targetEnvironment(macCatalyst)
        case .remoteAccess: Text("异网接入")
        #endif
        case .folder(let name), .linkFolder(let name): Text(verbatim: name)
        }
    }

    var folderScope: LibraryFolderScope {
        switch self {
        case .links, .recent, .linkFolder: .links
        default: .custom
        }
    }

    var sidebarItem: HiddenSidebarItems {
        switch self {
        case .nearby: .nearby
        case .tailscale: .tailscale
        case .links, .linkFolder: .links
        case .recent: .recent
        case .favorites: .favorites
        case .all, .folder: []
        #if targetEnvironment(macCatalyst)
        case .remoteAccess: []
        #endif
        }
    }

    var showsConnectionListFolders: Bool {
        switch self {
        case .all, .links: true
        default: false
        }
    }

    func displayedFolder(for computer: Computer) -> String? {
        switch self {
        case .folder, .linkFolder: nil
        case .recent: computer.linkFolder ?? computer.folder
        default: computer.folder(in: folderScope)
        }
    }

    static func folder(_ name: String, in scope: LibraryFolderScope) -> Self {
        scope == .links ? .linkFolder(name) : .folder(name)
    }

    func fallback(in archive: LibraryArchive, hiddenItems: HiddenSidebarItems) -> Self? {
        if !hiddenItems.isDisjoint(with: sidebarItem) { return .all }
        switch self {
        case .folder(let name) where !archive.folders(in: .custom).contains(name): return .all
        case .linkFolder(let name) where !archive.folders(in: .links).contains(name): return .links
        default: return nil
        }
    }
}

enum LibraryWindowRequest: Codable, Hashable {
    case connection(UUID)
    case quickConnect
    case collection(CollectionPage)

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        // Saved windows in existing installations persist a UUID.
        if let id = try? value.decode(UUID.self) { self = .connection(id) }
        else if (try? value.decode(String.self)) == "quickConnect" { self = .quickConnect }
        else { self = .collection(try value.decode(CollectionPage.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .connection(let id): try value.encode(id)
        case .quickConnect: try value.encode("quickConnect")
        case .collection(let page): try value.encode(page)
        }
    }
}

struct ArchiveDocument: FileDocument {
    static let type = UTType(exportedAs: "local.nikey.desklink.archive", conformingTo: .json)
    static let screensType = UTType(importedAs: "com.edovia.screens5.archive", conformingTo: .data)
    static let readableContentTypes = [type, .json, screensType]
    static let writableContentTypes = [type, screensType]
    private(set) var fromScreens = false
    private(set) var outputType = Self.type
    let data: Data
    init(data: Data, exportType: UTType = Self.type) {
        self.data = data
        self.outputType = exportType
    }
    init(contentsOf url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var error: NSError?
        var read: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &error) { location in
            read = Result { try Data(contentsOf: location) }
        }
        if let error { throw error }
        guard let read else { throw CocoaError(.fileReadUnknown) }
        try self.init(importing: read.get(), fromScreens: url.pathExtension.lowercased() == "screens")
    }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        try self.init(importing: data, fromScreens: configuration.contentType == Self.screensType)
    }
    private init(importing data: Data, fromScreens: Bool) throws {
        self.fromScreens = fromScreens
        self.data = fromScreens ? try ScreensArchive.convert(data).encoded() : data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard configuration.contentType == outputType else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
        return FileWrapper(regularFileWithContents: data)
    }
}

struct LibraryWindow: View {
    @Bindable var library: ConnectionLibrary
    let preferences: UserDefaults
    let pasteboard: UIPasteboard
    var initialRequest: LibraryWindowRequest?
    @State private var page: CollectionPage?
    @State private var selectedConnection: String?
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    @State private var nearby = NearbyComputers()
    @Environment(TailnetDirectory.self) private var tailnet
    @Environment(AppLock.self) private var privacy
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @State private var search = ""
    @State private var sidebarSearchPresented = false
    @State private var detailSearchPresented = false
    @State private var editor: EditorRequest?
    @State private var activeSession: SessionRequest?
    @State private var showFolder = false
    @State private var renamingFolder: String?
    @State private var deletingFolder: String?
    @State private var editingFolderScope = LibraryFolderScope.custom
    @State private var folderName = ""
    @State private var importFile = false
    @State private var exportFile = false
    @State private var exportDocument: ArchiveDocument?
    @State private var pendingArchives: [ArchiveDocument] = []
    @State private var importResult: ArchiveImportResult?
    @State private var deletion: Computer?
    @State private var ownError: String?
    @AppStorage("library.listLayout") private var listLayout = false
    @ScaledMetric(relativeTo: .body) private var connectionListFolderWidth: CGFloat = 144
    @AppStorage(HiddenSidebarItems.preferenceKey) private var hiddenSidebarItems = 0
    @AppStorage("library.showsNearbyCount") private var showsNearbyCount = true
    @AppStorage("library.savedOrder") private var savedOrder = ComputerOrder.manual
    @AppStorage("library.favoriteOrder") private var favoriteOrder = ComputerOrder.manual
    @AppStorage("library.recentOrder") private var recentOrder = ComputerOrder.lastConnected
    @AppStorage("library.linkOrder") private var linkOrder = ComputerOrder.lastConnected
    @State private var sessionToEdit: EditorRequest?
    @State private var queuedRoute: ConnectionRoute?
    @State private var openedInitialRequest = false
    @State private var settings = false
    @State private var downloads = false
    @State private var historicalReport: ConnectionReport?
    @State private var selectedPreview: SavedDesktopPreview?
    #if targetEnvironment(macCatalyst)
    @Environment(MacAvailability.self) private var availability
    @SceneStorage("mac.library.toolbarVisible") private var libraryToolbarVisible = true
    @SceneStorage("mac.connectionWindow.savedID") private var restoredConnectionID: String?
    @State private var windowSource = MacWindowSceneSource()
    @State private var isConnectionWindow = false
    @State private var showsDiagnostics = false
    @State private var hasVisitedNearby = false
    #endif

    init(library: ConnectionLibrary, preferences: UserDefaults, pasteboard: UIPasteboard,
         initialRequest: LibraryWindowRequest? = nil) {
        self.library = library
        self.preferences = preferences
        self.pasteboard = pasteboard
        self.initialRequest = initialRequest
        let hiddenItems = HiddenSidebarItems(rawValue: preferences.integer(forKey: HiddenSidebarItems.preferenceKey))
        _page = State(initialValue: CollectionPage.startup(computers: library.archive.computers, hiddenItems: hiddenItems))
    }

    private var hiddenItems: HiddenSidebarItems { HiddenSidebarItems(rawValue: hiddenSidebarItems) }
    private var collectionFallback: CollectionPage? {
        page?.fallback(in: library.archive, hiddenItems: hiddenItems)
    }

    #if targetEnvironment(macCatalyst)
    private var connectionTabs: MacConnectionTabs {
        preferences.string(forKey: MacConnectionTabs.preference).flatMap(MacConnectionTabs.init(rawValue:)) ?? .system
    }
    #endif

    private var startupRequest: LibraryWindowRequest? {
        #if targetEnvironment(macCatalyst)
        if initialRequest == nil, let restoredConnectionID, let id = UUID(uuidString: restoredConnectionID) { return .connection(id) }
        #endif
        return initialRequest
    }

    private var usesUnifiedSearch: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    private var offersNearbyCount: Bool {
        #if targetEnvironment(macCatalyst)
        hasVisitedNearby
        #else
        usesUnifiedSearch && showsNearbyCount
        #endif
    }
    private var unifiedQuery: LibrarySearchQuery { LibrarySearchQuery(search) }
    private var categoryQuery: LibrarySearchQuery { usesUnifiedSearch ? LibrarySearchQuery("") : unifiedQuery }
    private var offersCategorySearch: Bool {
        #if targetEnvironment(macCatalyst)
        if page == .remoteAccess { return false }
        #endif
        return page != .tailscale || tailnet.account != nil
    }
    private var searchesAllSources: Bool {
        usesUnifiedSearch && (sidebarSearchPresented || detailSearchPresented) && !unifiedQuery.isEmpty
    }

    private var discoversNearbyComputers: Bool {
        !privacy.locked && activeSession == nil && scenePhase != .background
            && !hiddenItems.contains(.nearby) && (page == .nearby || offersNearbyCount || searchesAllSources)
    }

    private var nearbyCount: Int { offersNearbyCount ? nearby.entries.count : 0 }

    private var order: Binding<ComputerOrder> {
        switch page {
        case .recent: $recentOrder
        case .links, .linkFolder: $linkOrder
        case .favorites: $favoriteOrder
        default: $savedOrder
        }
    }

    private var entries: [Computer] {
        let query = categoryQuery
        let list: [Computer]
        switch page {
        case .recent:
            return order.wrappedValue.arrange(library.archive.recentComputers(matching: query))
        case .links:
            list = library.archive.computers.filter(\.isLink)
        case .linkFolder(let name):
            list = library.archive.computers.filter { $0.isLink && $0.linkFolder == name }
        case .favorites:
            list = library.archive.computers.filter { $0.saved && $0.favorite }
        case let .folder(folder):
            list = library.archive.computers.filter { $0.saved && $0.folder == folder }
        default:
            list = library.archive.computers.filter(\.saved)
        }
        let matching = query.isEmpty ? list : list.filter(query.matches)
        return order.wrappedValue.arrange(matching)
    }

    var body: some View {
        Group {
            if let activeSession {
                SessionScreen(request: activeSession, library: library, preferences: preferences, pasteboard: pasteboard) { recoveryEditor in
                    sessionToEdit = recoveryEditor
                    self.activeSession = nil
                    #if targetEnvironment(macCatalyst)
                    if recoveryEditor == nil, isConnectionWindow, queuedRoute == nil, pendingArchives.isEmpty,
                       let scene = windowSource.scene {
                        UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil)
                    }
                    #endif
                }
                .id(activeSession.id)
                #if targetEnvironment(macCatalyst)
                .environment(windowSource)
                #endif
                .background(Color(uiColor: .systemBackground).ignoresSafeArea())
                .preferredColorScheme(.dark)
            } else {
                NavigationSplitView {
                    if usesUnifiedSearch {
                        ZStack {
                            if sidebarSearchPresented && !unifiedQuery.isEmpty { unifiedResults }
                            else { librarySidebar }
                        }
                        .navigationTitle(AppName.display)
                        .searchable(text: $search, isPresented: $sidebarSearchPresented,
                                    placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索所有来源")
                    } else { librarySidebar }
                } detail: {
                    if usesUnifiedSearch {
                        ZStack {
                            if detailSearchPresented && !unifiedQuery.isEmpty { unifiedResults }
                            else { collection }
                        }
                        .navigationTitle((page ?? .all).title)
                        .searchable(text: $search, isPresented: $detailSearchPresented,
                                    placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索所有来源")
                        .toolbar { libraryToolbar }
                    } else {
                        searchableCollection
                            .navigationTitle((page ?? .all).title)
                            #if targetEnvironment(macCatalyst)
                            .navigationBarTitleDisplayMode(.inline)
                            #endif
                            .toolbar { libraryToolbar }
                    }
                }
                .onChange(of: collectionFallback, initial: true) { _, fallback in
                    if let fallback { page = fallback }
                }
                .onChange(of: page, initial: true) {
                    selectedConnection = nil
                    #if targetEnvironment(macCatalyst)
                    if page == .nearby { hasVisitedNearby = true }
                    #endif
                }
                .onChange(of: offersCategorySearch) { _, offersSearch in
                    if !usesUnifiedSearch, !offersSearch { search = "" }
                }
                #if targetEnvironment(macCatalyst)
                .focusedSceneValue(\.deskLinkLibrary, libraryMenu)
                #elseif os(iOS)
                .focusedSceneValue(\.telescopePadLibrary, padLibraryMenu)
                #endif
                .onAppear {
                    let startupRequest = self.startupRequest
                    #if targetEnvironment(macCatalyst)
                    availability.libraryStartup.libraryAppeared(openingRequestedContent: startupRequest != nil)
                    #endif
                    importPendingArchives()
                    if !openedInitialRequest, let startupRequest {
                        openedInitialRequest = true
                        #if targetEnvironment(macCatalyst)
                        if case .connection = startupRequest { isConnectionWindow = true }
                        #endif
                        open(startupRequest)
                    } else if let sessionToEdit {
                        editor = sessionToEdit
                        self.sessionToEdit = nil
                    } else if let queuedRoute {
                        self.queuedRoute = nil
                        present(queuedRoute)
                    }
                }
            }
        }
        #if targetEnvironment(macCatalyst)
        .background {
            let title = privacy.locked ? AppName.display : activeSession?.computer.displayName ?? AppName.display
            MacWindowSceneCapture(source: windowSource, title: title)
        }
        .onContinueUserActivity(MacConnectionWindows.activityType) { activity in
            guard let content = availability.connectionWindows.take(activity) else { return }
            isConnectionWindow = true
            switch content {
            case .session(let request): start(request)
            case .route(let route):
                if case .saved(let id) = route {
                    openedInitialRequest = true
                    restoredConnectionID = id.uuidString
                }
                present(route)
            }
        }
        .handlesExternalEvents(preferring: [], allowing: ["desklink://", "vnc://", "ssh://", "screens-ssh://", "file://"])
        #endif
        .onChange(of: discoversNearbyComputers, initial: true) { _, browsing in
            if browsing { nearby.start() }
            else { nearby.stop() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, discoversNearbyComputers { nearby.retryAfterLocalNetworkDenial() }
        }
        .task(id: searchesAllSources) {
            if searchesAllSources, !hiddenItems.contains(.tailscale), tailnet.devices.isEmpty {
                await tailnet.refresh()
            }
        }
        .onDisappear { nearby.stop() }
        .sheet(item: $editor) { request in
            connectionSheet(for: request).id(request.id)
        }
        .sheet(isPresented: $settings) { ApplicationPreferences(preferences: preferences) }
        .sheet(isPresented: $downloads) { DownloadsView() }
        #if targetEnvironment(macCatalyst)
        .sheet(isPresented: $showsDiagnostics) {
            if !privacy.locked {
                NavigationStack {
                    SupportDiagnosticsView().toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("关闭") { showsDiagnostics = false }
                        }
                    }
                }
            }
        }
        #endif
        .sheet(item: $historicalReport) { report in
            if !privacy.locked { ConnectionDetails(report: report, historical: true) }
        }
        .sheet(item: $selectedPreview) { selection in
            if !privacy.locked {
                NavigationStack {
                    Group {
                        if let current = library.previews[selection.computerID] {
                            SavedDesktopImage(preview: current).padding()
                        }
                    }
                    .navigationTitle("上次桌面快照")
                    .toolbar { Button("关闭") { selectedPreview = nil } }
                }
            }
        }
        .onChange(of: privacy.locked) { _, locked in
            if locked {
                historicalReport = nil
                selectedPreview = nil
                #if targetEnvironment(macCatalyst)
                showsDiagnostics = false
                #endif
            }
        }
        .alert(renamingFolder == nil ? "新建文件夹" : "重命名文件夹", isPresented: $showFolder) {
            TextField("名称", text: $folderName)
            Button("取消", role: .cancel) {}
            Button("保存") {
                let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
                if let original = renamingFolder {
                    if library.renameFolder(original, to: name, in: editingFolderScope), page == .folder(original, in: editingFolderScope) {
                        page = .folder(name, in: editingFolderScope)
                    }
                } else if library.addFolder(name, in: editingFolderScope) { page = .folder(name, in: editingFolderScope) }
            }
            .disabled(!canSaveFolder)
        }
        .alert("删除文件夹", isPresented: Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } }), presenting: deletingFolder) { name in
            Button("取消", role: .cancel) {}
            Button("删除文件夹", role: .destructive) {
                if library.removeFolder(name, in: editingFolderScope), page == .folder(name, in: editingFolderScope) {
                    page = editingFolderScope == .links ? .links : .all
                }
            }
        } message: { _ in
            Text(editingFolderScope == .links ? "文件夹中的链接会保留在「所有链接」。" : "文件夹中的连接会移至「所有连接」。")
        }
        .alert("删除", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }), presenting: deletion) { item in
            Button("删除", role: .destructive) { library.remove(item) }
            Button("取消", role: .cancel) {}
        } message: { item in Text(item.displayName) }
        .alert("连接失败", isPresented: Binding(get: { ownError != nil || library.errorMessage != nil || nearby.errorMessage != nil }, set: { _ in
            ownError = nil; library.errorMessage = nil; nearby.errorMessage = nil
        })) {
            Button("关闭", role: .cancel) {}
        } message: { Text(ownError ?? library.errorMessage ?? nearby.errorMessage ?? "") }
        .alert("导入完成", isPresented: Binding(get: { importResult != nil }, set: { if !$0 { importResult = nil } })) {
            Button("完成") {}
        } message: {
            if let result = importResult {
                let counts = "新增连接 \(result.connections) 个，新增文件夹 \(result.folders) 个，跳过重复连接 \(result.duplicates) 个。"
                let note = result.importedScreens && result.connections > 0
                    ? "\n已迁移连接地址、账户、分组及适用的 SSH 和观察设置。首次连接时请核对显示与输入偏好，并按需提供密码或密钥。" : ""
                let directoryNote = result.directoryFolders == 0 ? "" : String(localized: "\n另保留 \(result.directoryFolders) 个目录分组，可随归档导出。")
                Text(counts + directoryNote + note)
            }
        }
        .onChange(of: privacy.locked) { _, locked in
            guard !locked else { return }
            importPendingArchives()
            if activeSession == nil, let queuedRoute {
                self.queuedRoute = nil
                present(queuedRoute)
            }
        }
        .fileImporter(isPresented: $importFile, allowedContentTypes: ArchiveDocument.readableContentTypes + [vncLocationType]) { result in
            do {
                let url = try result.get()
                if url.pathExtension.lowercased() == "vncloc" {
                    present(.desktopLink(try InternetLocation.read(url)))
                } else {
                    try receiveArchive(at: url)
                }
            } catch let error as CocoaError where error.code == .userCancelled {
            } catch { ownError = error.localizedDescription }
        }
        .fileExporter(isPresented: $exportFile, document: exportDocument, contentType: exportDocument?.outputType ?? ArchiveDocument.type, defaultFilename: AppName.display) {
            if case .failure(let error) = $0 { ownError = error.localizedDescription }
            exportDocument = nil
        }
        .onOpenURL { url in
            #if targetEnvironment(macCatalyst)
            availability.libraryStartup.openRequestedContent()
            availability.restoreDockPolicyIfNeeded()
            if let request = MacStatusMenu.request(for: url) {
                if activeSession == nil { open(request) }
                else if case .connection(let id) = request { openConnectionWindow(id, tabs: connectionTabs) }
                else { openWindow(id: "desklink-library", value: request) }
                return
            }
            #endif
            do {
                if url.isFileURL && ["desklink", "screens"].contains(url.pathExtension.lowercased()) {
                    try receiveArchive(at: url)
                    return
                }
                let route: ConnectionRoute
                if url.isFileURL && url.pathExtension.lowercased() == "vncloc" {
                    route = .desktopLink(try InternetLocation.read(url))
                } else { route = try ConnectionRoute(url: url) }
                #if targetEnvironment(macCatalyst)
                if activeSession != nil, let source = windowSource.scene {
                    availability.connectionWindows.open(.route(route), from: source, tabs: connectionTabs) {
                        queuedRoute = route
                    }
                    return
                }
                #endif
                if activeSession != nil { queuedRoute = route } else { present(route) }
            } catch { ownError = error.localizedDescription }
        }
    }

    @ViewBuilder private func connectionSheet(for request: EditorRequest) -> some View {
        if let selection = request.discoveredSelection {
            if !privacy.locked {
                let profiles = selection.profiles(in: library)
                DiscoveredProfilePicker(selection: selection, profiles: ComputerOrder.name.arrange(profiles)) { profile in
                    guard !privacy.locked, editor?.id == request.id,
                          let chosen = selection.editor(selecting: profile, in: library) else { return }
                    editor = chosen
                }
            }
        } else {
            ConnectionEditor(request: request, library: library, tailnet: tailnet, privacy: privacy,
                             hiddenSources: hiddenItems, selectDevice: { computer, sshPort, addresses in
                guard editor?.id == request.id else { return }
                openDiscovered(computer, suggestedSSHPort: sshPort, quality: nil, resolvedAddresses: addresses)
            }, openLink: { value in
                let route: ConnectionRoute
                if value.lowercased().hasPrefix("desklink://"), let url = URL(string: value) {
                    route = try ConnectionRoute(url: url)
                } else { route = .desktopLink(try DesktopLink(text: value)) }
                editor = try editorRequest(for: route)
            }, didSave: {
                if request.purpose == .new, page == .recent { page = .all }
            }) { offer in
                start(offer)
            }
        }
    }

    private func receiveArchive(at url: URL) throws {
        pendingArchives.append(try ArchiveDocument(contentsOf: url))
        importPendingArchives()
    }

    private func importPendingArchives() {
        guard !privacy.locked, activeSession == nil, !pendingArchives.isEmpty else { return }
        let hadSavedConnections = library.archive.computers.contains(where: \.saved)
        let files = pendingArchives
        pendingArchives.removeAll()
        var total = importResult ?? ArchiveImportResult()
        for file in files {
            do {
                guard let result = try library.importArchive(file.data) else { continue }
                total.connections += result.connections
                total.folders += result.folders
                total.duplicates += result.duplicates
                total.directoryFolders += result.directoryFolders
                total.importedScreens = total.importedScreens || file.fromScreens
                importResult = total
            } catch { ownError = error.localizedDescription }
        }
        if page == .recent, !hadSavedConnections, library.archive.computers.contains(where: \.saved) {
            page = .all
        }
    }

    private var librarySidebar: some View {
        List(selection: $page) {
            if !hiddenItems.isSuperset(of: [.nearby, .recent, .favorites]) {
                Section {
                    nearbySidebarRow
                    if !hiddenItems.contains(.recent) {
                        Label("最近连接", systemImage: "clock")
                            .tag(CollectionPage.recent)
                            .accessibilityIdentifier("library.recent")
                    }
                    if !hiddenItems.contains(.favorites) {
                        Label("收藏", systemImage: "star")
                            .tag(CollectionPage.favorites)
                            .accessibilityIdentifier("library.favorites")
                    }
                }
            }
            if !hiddenItems.contains(.links) {
                Section("链接") {
                    folderDropTarget(Label("所有链接", systemImage: "link"), folder: nil, scope: .links)
                        .tag(CollectionPage.links)
                        .accessibilityIdentifier("library.links")
                    folderRows(in: .links)
                }
            }
            #if targetEnvironment(macCatalyst)
            Section("网络") {
                Label("异网接入", systemImage: "network")
                    .tag(CollectionPage.remoteAccess)
                    .accessibilityIdentifier("library.remoteAccess")
                tailscaleSidebarRow
            }
            #else
            if !hiddenItems.contains(.tailscale) {
                Section("网络") { tailscaleSidebarRow }
            }
            #endif
            Section("自定义连接") {
                folderDropTarget(Label("所有连接", systemImage: "desktopcomputer"), folder: nil, scope: .custom)
                    .tag(CollectionPage.all)
                    .accessibilityIdentifier("library.all")
                folderRows(in: .custom)
            }
        }
        #if !targetEnvironment(macCatalyst)
        .navigationTitle(AppName.display)
        #endif
        .navigationSplitViewColumnWidth(min: 165, ideal: 205, max: 290)
    }

    @ViewBuilder private var nearbySidebarRow: some View {
        if !hiddenItems.contains(.nearby) {
            Label("附近", systemImage: "dot.radiowaves.left.and.right")
                .badge(nearbyCount)
                .accessibilityValue(nearbyCount == 0 ? "" : nearbyCount.formatted())
                .accessibilityIdentifier("library.nearby")
                .tag(CollectionPage.nearby)
        }
    }

    @ViewBuilder private var tailscaleSidebarRow: some View {
        if !hiddenItems.contains(.tailscale) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tailscale")
                    Text(verbatim: tailnet.account?.tailnet ?? String(localized: "未关联"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } icon: { Image(systemName: "point.3.connected.trianglepath.dotted") }
            .tag(CollectionPage.tailscale)
            .accessibilityIdentifier("library.tailscale")
        }
    }

    @ViewBuilder private var unifiedResults: some View {
        let query = unifiedQuery
        let stored = query.storedMatches(in: library.archive.computers)
        let showsNearby = !hiddenItems.contains(.nearby)
        let local = showsNearby ? nearby.entries.filter { $0.matches(query) } : []
        let nearbyPermissionDenied = showsNearby && nearby.needsLocalNetworkAccess
        let peers = hiddenItems.contains(.tailscale) ? [] : tailnet.searchMatches(query)
        if stored.isEmpty && local.isEmpty && peers.isEmpty && !nearbyPermissionDenied {
            if discoversNearbyComputers && nearby.isSearching {
                ProgressView("正在查找附近的电脑…")
            } else {
                emptySearch
                    .accessibilityIdentifier("library.search.empty")
            }
        } else {
            List {
                searchSection("已保存的电脑", items: stored.saved, source: "saved", symbol: "desktopcomputer")
                searchSection("最近连接", items: stored.recent, source: "recent", symbol: "clock")
                searchSection("临时链接", items: stored.links, source: "link", symbol: "link")
                if nearbyPermissionDenied {
                    Section("附近") {
                        Label(NearbyNetworkPermissionActions.instructions, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.secondary)
                        NearbyNetworkPermissionActions(retry: nearby.retry)
                    }
                } else if !local.isEmpty {
                    Section("附近") {
                        ForEach(local) { item in
                            Button {
                                openNearbySearchResult(item, quality: nil)
                            } label: {
                                searchLabel(item.name, address: item.detail, symbol: item.symbol)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("library.search.nearby." + item.id)
                            .contextMenu {
                                DiscoveredConnectionActions { openNearbySearchResult(item, quality: $0) }
                                Button("保存到连接库") {
                                    nearby.select(item) { computer, addresses in
                                        endUnifiedSearch()
                                        saveDiscovered(computer, resolvedAddresses: addresses)
                                    }
                                }
                            }
                        }
                    }
                }
                if !peers.isEmpty {
                    Section("Tailscale") {
                        ForEach(peers) { item in
                            Button {
                                endUnifiedSearch()
                                openDiscovered(item.computer, suggestedSSHPort: item.sshPort, quality: nil,
                                               resolvedAddresses: item.advertisedEndpoints)
                            } label: {
                                searchLabel(item.computer.displayName, address: item.system.details(address: item.computer.endpoint.address),
                                            folder: item.folder, symbol: item.system.symbol)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("library.search.tailscale." + item.id)
                            .contextMenu {
                                DiscoveredConnectionActions(offersHighPerformance: item.offersHighPerformance) { quality in
                                    endUnifiedSearch()
                                    openDiscovered(item.computer, suggestedSSHPort: item.sshPort, quality: quality,
                                                   resolvedAddresses: item.advertisedEndpoints)
                                }
                                Button("保存到连接库") {
                                    endUnifiedSearch()
                                    saveDiscovered(item.computer, suggestedSSHPort: item.sshPort,
                                                   resolvedAddresses: item.advertisedEndpoints)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.interactively)
        }
    }

    @ViewBuilder private func searchSection(_ title: LocalizedStringKey, items: [Computer], source: String, symbol: String) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { item in
                    Button {
                        endUnifiedSearch()
                        open(item)
                    } label: {
                        searchLabel(item.displayName, address: item.endpoint.address,
                                    folder: item.saved ? item.folder : item.linkFolder, symbol: symbol)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("library.search." + source + "." + item.id.uuidString)
                    .contextMenu { actions(for: item) }
                }
            }
        }
    }

    private func searchLabel(_ name: String, address: String? = nil, folder: String? = nil, symbol: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: name)
                let details = [address, folder].compactMap { $0 }.joined(separator: " · ")
                if !details.isEmpty { Text(verbatim: details).font(.caption).foregroundStyle(.secondary) }
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(Color.accentColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func endUnifiedSearch() {
        sidebarSearchPresented = false
        detailSearchPresented = false
        search = ""
    }

    @ViewBuilder private var searchableCollection: some View {
        if offersCategorySearch {
            collection.searchable(text: $search, prompt: "搜索")
        } else {
            collection
        }
    }

    @ViewBuilder private var collection: some View {
        #if targetEnvironment(macCatalyst)
        if page == .remoteAccess {
            MacRemoteAccessPreferences(access: availability.remoteAccess)
        } else {
            connectionCollection
        }
        #else
        connectionCollection
        #endif
    }

    @ViewBuilder private var connectionCollection: some View {
        if page == .tailscale {
            TailnetView(directory: tailnet, archiveFolders: library.archive.screensDirectoryFolders?.tailscale ?? [],
                        query: categoryQuery, listLayout: listLayout, gridColumns: gridColumns,
                        select: { computer, sshPort, quality, addresses in
                            openDiscovered(computer, suggestedSSHPort: sshPort, quality: quality, resolvedAddresses: addresses)
                        },
                        save: { computer, sshPort, addresses in
                            saveDiscovered(computer, suggestedSSHPort: sshPort, resolvedAddresses: addresses)
                        })
        } else if page == .nearby {
            let query = categoryQuery
            let results = nearby.entries.filter { $0.matches(query) }
            Group {
                if let error = nearby.searchError {
                    ContentUnavailableView {
                        Label("无法查找附近的电脑", systemImage: "network.slash")
                    } description: {
                        if nearby.needsLocalNetworkAccess {
                            Text(NearbyNetworkPermissionActions.instructions)
                        } else {
                            Text(verbatim: error.localizedDescription)
                        }
                    } actions: {
                        if nearby.needsLocalNetworkAccess {
                            NearbyNetworkPermissionActions(retry: nearby.retry)
                        } else {
                            Button("重新查找") { nearby.retry() }
                                .accessibilityIdentifier("nearby.retry")
                        }
                    }
                } else if results.isEmpty && nearby.isSearching {
                    ProgressView("正在查找附近的电脑…")
                } else if results.isEmpty && !query.isEmpty && !nearby.entries.isEmpty {
                    emptySearch
                } else if results.isEmpty {
                    ContentUnavailableView {
                        Label("未找到附近的电脑", systemImage: "desktopcomputer")
                    } description: {
                        Text("请确认另一台电脑已启用屏幕共享或 VNC，并与这台设备在同一网络。")
                    } actions: {
                        Button("重新查找") { nearby.retry() }
                            .accessibilityIdentifier("nearby.retry")
                    }
                } else if listLayout {
                    List(results) { entry in
                        nearbyItem(entry, cornerRadius: 8) {
                            searchLabel(entry.name, address: entry.detail, symbol: entry.symbol)
                        }
                    }
                    .listStyle(.plain)
                    .accessibilityIdentifier("nearby.list")
                } else {
                    ScrollView {
                        LazyVGrid(columns: gridColumns, spacing: 14) {
                            ForEach(results) { entry in
                                nearbyItem(entry, cornerRadius: 16) {
                                    ConnectionTile(name: entry.name, address: entry.detail, symbol: entry.symbol)
                                }
                            }
                        }.padding(24)
                    }
                    .background(Color(uiColor: .systemGroupedBackground))
                    .accessibilityIdentifier("nearby.grid")
                }
            }
        } else if entries.isEmpty {
            emptyCollection
        } else if listLayout {
            let visible = entries
            #if targetEnvironment(macCatalyst)
            GeometryReader { geometry in
                let showsFolders = (page ?? .all).showsConnectionListFolders
                    && !typeSize.isAccessibilitySize && geometry.size.width >= connectionListFolderWidth + 270
                connectionList(visible, showsFolderColumn: showsFolders)
            }
            #else
            connectionList(visible, showsFolderColumn: false)
            #endif
        } else {
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: 14) {
                    ForEach(entries) { item in
                        gridButton(item) {
                            ConnectionTile(name: item.displayName, address: item.endpoint.address,
                                           symbol: item.screensOperatingSystem == 5 ? "cpu" : "desktopcomputer",
                                           folder: (page ?? .all).displayedFolder(for: item),
                                           favorite: item.favorite, usesSSH: item.ssh != nil, preview: library.previews[item.id])
                        }
                        .buttonStyle(.plain)
                        .overlay(alignment: .topTrailing) { resumeVideoButton(for: item) }
                    }
                }.padding(24)
            }.background(Color(uiColor: .systemGroupedBackground))
        }
    }

    private func nearbyItem<Content: View>(_ entry: NearbyComputer, cornerRadius: CGFloat,
                                           @ViewBuilder label: () -> Content) -> some View {
        DiscoveredConnectionItem(id: "nearby.computer." + entry.id, selection: $selectedConnection,
                                 cornerRadius: cornerRadius, endpoint: entry.endpoint) { quality in
            nearby.select(entry) { openDiscovered($0, suggestedSSHPort: nil, quality: quality, resolvedAddresses: $1) }
        } label: {
            label()
        } actions: {
            Button("保存到连接库") {
                nearby.select(entry) { saveDiscovered($0, resolvedAddresses: $1) }
            }
        }
    }

    private func connectionList(_ visible: [Computer], showsFolderColumn: Bool) -> some View {
        let reservesVideoSpace = showsFolderColumn && visible.contains { library.videoRetryDate(for: $0) != nil }
        return VStack(spacing: 0) {
            if showsFolderColumn {
                HStack(spacing: 8) {
                    Text("连接")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("文件夹")
                        .frame(width: connectionListFolderWidth, alignment: .leading)
                        .accessibilityIdentifier("library.list.folderHeading")
                    if reservesVideoSpace {
                        Color.clear.frame(width: 44, height: 1).accessibilityHidden(true)
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                Divider()
            }
            List {
                ForEach(visible) { item in
                    connectionListRow(item, showsFolderColumn: showsFolderColumn, reservesVideoSpace: reservesVideoSpace)
                        .listRowInsets(showsFolderColumn ? EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16) : nil)
                }
                .onMove(perform: page != .recent && order.wrappedValue == .manual ? { sources, destination in
                    var ids = visible.map(\.id)
                    ids.move(fromOffsets: sources, toOffset: destination)
                    _ = library.reorder(ids)
                } : nil)
            }
            .listStyle(.plain)
        }
    }

    private func connectionListRow(
        _ item: Computer, showsFolderColumn: Bool, reservesVideoSpace: Bool
    ) -> some View {
        let folder = (page ?? .all).displayedFolder(for: item)
        return HStack(spacing: 8) {
            let row = LibraryConnectionItem(id: "library.computer." + item.id.uuidString, selection: $selectedConnection) {
                open(item)
            } label: {
                HStack(spacing: 8) {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.displayName)
                            if item.endpoint.address != item.displayName {
                                Text(item.endpoint.address).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } icon: { Image(systemName: "desktopcomputer") }
                    Spacer(minLength: 8)
                    if showsFolderColumn {
                        Group {
                            if let folder {
                                Text(verbatim: folder).foregroundStyle(.secondary).lineLimit(2)
                            } else {
                                Color.clear.frame(height: 1).accessibilityHidden(true)
                            }
                        }
                        .frame(width: connectionListFolderWidth, alignment: .leading)
                    } else if let folder {
                        Label(folder, systemImage: "folder")
                            .labelStyle(.titleAndIcon).font(.caption)
                            .foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .contentShape(Rectangle())
            }
            .contextMenu { actions(for: item) }
            connectionDrag(row, item: item)
            if reservesVideoSpace {
                Color.clear.frame(width: 44, height: 44)
                    .overlay { resumeVideoButton(for: item) }
            } else {
                resumeVideoButton(for: item)
            }
        }
    }

    @ViewBuilder private func resumeVideoButton(for item: Computer) -> some View {
        if library.videoRetryDate(for: item) != nil {
            Button { library.resumeStreaming(for: item) } label: {
                Label("立即恢复流畅视频与音频", systemImage: "bolt.slash").labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.borderless)
            .help("立即恢复流畅视频与音频")
            .accessibilityIdentifier("library.resumeVideo." + item.id.uuidString)
        }
    }

    @ViewBuilder private func gridButton<Content: View>(_ item: Computer, @ViewBuilder label: () -> Content) -> some View {
        let button = LibraryConnectionItem(id: "library.computer." + item.id.uuidString, selection: $selectedConnection,
                                           cornerRadius: 16) {
            open(item)
        } label: { label() }
            .contextMenu { actions(for: item) }
        connectionDrag(button, item: item)
    }

    @ViewBuilder private func connectionDrag<Content: View>(_ content: Content, item: Computer) -> some View {
        let scope = page == .recent && !item.isLink ? .custom : (page ?? .all).folderScope
        if scope.includes(item) {
            let draggable = content.draggable(LibraryConnectionDrag(computerID: item.id, scope: scope))
            if page != .recent, order.wrappedValue == .manual {
                draggable.dropDestination(for: LibraryConnectionDrag.self) { items, _ in
                    guard items.count == 1, let source = items.first, source.scope == scope else { return false }
                    return library.move(source.computerID, to: item.id, within: Set(entries.map(\.id)))
                }
            } else {
                draggable
            }
        } else {
            content
        }
    }

    private func folderDropTarget<Content: View>(
        _ content: Content, folder: String?, scope: LibraryFolderScope
    ) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .dropDestination(for: LibraryConnectionDrag.self) { items, _ in
                guard items.count == 1, let source = items.first, source.scope == scope else { return false }
                return library.move(source.computerID, toFolder: folder, in: scope)
            }
    }

    private var gridColumns: [GridItem] {
        if typeSize.isAccessibilitySize { return [GridItem(.flexible())] }
        return [GridItem(.adaptive(minimum: 212, maximum: 340), spacing: 14, alignment: .topLeading)]
    }

    private var emptySearch: some View {
        ContentUnavailableView {
            Label("未找到匹配的连接", systemImage: "magnifyingglass")
        } actions: { Button("清除搜索") { search = "" } }
    }

    @ViewBuilder private var emptyCollection: some View {
        if !categoryQuery.isEmpty {
            emptySearch
        } else {
            switch page ?? .all {
            case .favorites:
                ContentUnavailableView {
                    Label("还没有收藏的电脑", systemImage: "star")
                } description: {
                    Text("在电脑的菜单中选择「添加到收藏」，它就会显示在这里。")
                } actions: {
                    Button("所有连接") { page = .all }.accessibilityIdentifier("library.empty.all")
                }
            case .recent:
                ContentUnavailableView {
                    Label("没有最近连接", systemImage: "clock")
                } description: {
                    Text("成功连接过的电脑会显示在这里。")
                } actions: {
                    Button("快速连接") { editor = EditorRequest(purpose: .quick) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("library.empty.quick")
                    Button("新建连接", action: newEntry)
                        .accessibilityIdentifier("library.empty.new")
                }
            case .all:
                ContentUnavailableView {
                    Text("添加第一台电脑").font(.title2.weight(.semibold))
                } description: {
                    Text("保存常用电脑，或输入地址连接一次。")
                } actions: {
                    Button("新建连接", action: newEntry).buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("library.empty.new")
                    Button("快速连接") { editor = EditorRequest(purpose: .quick) }
                        .accessibilityIdentifier("library.empty.quick")
                }
            case .folder:
                ContentUnavailableView {
                    Label("文件夹中没有连接", systemImage: "folder")
                } actions: { Button("新建连接", action: newEntry) }
            default:
                ContentUnavailableView {
                    Label("没有连接链接", systemImage: "link")
                } actions: { Button("快速连接") { editor = EditorRequest(purpose: .quick) } }
            }
        }
    }

    @ToolbarContentBuilder private var libraryToolbar: some ToolbarContent {
        #if targetEnvironment(macCatalyst)
        if libraryToolbarVisible { libraryToolbarItems }
        #else
        libraryToolbarItems
        #endif
    }

    private var supportsLibraryOrganization: Bool {
        #if targetEnvironment(macCatalyst)
        if page == .remoteAccess { return false }
        #endif
        return page != .nearby && page != .tailscale
    }

    private var showsDiscoveryLayout: Bool {
        page == .nearby || (page == .tailscale && tailnet.account != nil)
    }

    private var libraryToolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { editor = EditorRequest(purpose: .quick) } label: { Label("快速连接", systemImage: "bolt") }
                .keyboardShortcut("k", modifiers: .command)
                .accessibilityIdentifier("library.quick")
            #if targetEnvironment(macCatalyst)
            if page == .nearby && !nearby.entries.isEmpty {
                Button { nearby.retry() } label: { Label("重新查找附近的电脑", systemImage: "arrow.clockwise") }
                    .accessibilityIdentifier("nearby.refresh")
            }
            if supportsLibraryOrganization || showsDiscoveryLayout {
                libraryPresentationMenu
            }
            #endif
            Button { newEntry() } label: { Label("新建连接", systemImage: "plus") }
                .accessibilityIdentifier("library.new")
            Button { downloads = true } label: { Label("文件传输", systemImage: ConnectionActionSymbol.transfers) }
                .accessibilityIdentifier("library.transfers")
            Menu {
                if supportsLibraryOrganization {
                    Button {
                        editingFolderScope = page?.folderScope ?? .custom
                        renamingFolder = nil
                        folderName = ""
                        showFolder = true
                    } label: { Label("新建文件夹", systemImage: "folder.badge.plus") }
                }
                #if !targetEnvironment(macCatalyst)
                if supportsLibraryOrganization || showsDiscoveryLayout {
                    Button { listLayout.toggle() } label: {
                        Label(listLayout ? "网格" : "列表", systemImage: listLayout ? "square.grid.2x2" : "list.bullet")
                    }
                    .accessibilityIdentifier("library.changeLayout")
                }
                if supportsLibraryOrganization {
                    librarySortMenu
                }
                #endif
                Divider()
                Button("导入", systemImage: "square.and.arrow.down") { importFile = true }
                Button("导出", systemImage: "square.and.arrow.up") {
                    do { exportDocument = try ArchiveDocument(data: library.archive.encoded()); exportFile = true }
                    catch { ownError = error.localizedDescription }
                }
                Button("将已保存连接导出为 Screens 归档", systemImage: "doc.badge.arrow.up") {
                    do {
                        let knownMacs = library.archive.computers.filter { library.lastReport(for: $0.id)?.version == "RFB 3.889" }
                        let shares = preferences.object(forKey: "connection.sharedClipboard") as? Bool ?? true
                        let bytes = try ScreensArchive.export(library.archive, knownMacs: Set(knownMacs.map(\.id)), sharedClipboard: shares,
                                                              preferences: preferences)
                        exportDocument = ArchiveDocument(data: bytes, exportType: ArchiveDocument.screensType)
                        exportFile = true
                    } catch { ownError = error.localizedDescription }
                }
                Divider()
                Button("设置", systemImage: "gearshape") { settings = true }
            } label: { Label("更多", systemImage: "ellipsis.circle") }
            .accessibilityIdentifier("library.more")
        }
    }

    #if targetEnvironment(macCatalyst)
    private var libraryPresentationMenu: some View {
        Menu {
            Picker("显示方式", selection: $listLayout) {
                Label("网格", systemImage: "square.grid.2x2").tag(false)
                Label("列表", systemImage: "list.bullet").tag(true)
            }
            if supportsLibraryOrganization {
                librarySortMenu
            }
        } label: {
            Label("显示方式", systemImage: listLayout ? "list.bullet" : "square.grid.2x2")
        }
        .accessibilityIdentifier(showsDiscoveryLayout ? "library.discoveryLayout" : "library.presentation")
    }
    #endif

    private var librarySortMenu: some View {
        Menu("排序", systemImage: "arrow.up.arrow.down") {
            Picker("排序", selection: order) {
                ForEach(ComputerOrder.allCases.filter { page != .recent || $0 != .manual }, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }.pickerStyle(.inline)
        }
    }

    private func folderRows(in scope: LibraryFolderScope) -> some View {
        ForEach(library.archive.folders(in: scope), id: \.self) { name in
            folderDropTarget(Label(name, systemImage: "folder"), folder: name, scope: scope)
                .tag(CollectionPage.folder(name, in: scope))
                .accessibilityIdentifier((scope == .links ? "library.linkFolder." : "library.folder.") + name)
                .contextMenu {
                    Button("重命名文件夹") {
                        editingFolderScope = scope
                        folderName = name
                        renamingFolder = name
                        showFolder = true
                    }
                    Button("删除文件夹", role: .destructive) {
                        editingFolderScope = scope
                        deletingFolder = name
                    }
                }
        }
    }

    @ViewBuilder private func actions(for item: Computer) -> some View {
        Button("连接") { open(item) }
        if item.offersAppleDisplayOptions {
            Menu("连接模式") {
                ConnectionModeButtons { quality in open(item.connecting(with: quality, on: .current)) }
                if library.videoRetryDate(for: item) != nil {
                    Button("立即恢复流畅视频与音频") { library.resumeStreaming(for: item) }
                }
            }
        }
        if supportsMultipleWindows {
            Button("在新窗口中连接") {
                #if targetEnvironment(macCatalyst)
                openConnectionWindow(item.id, tabs: .never)
                #else
                openWindow(value: LibraryWindowRequest.connection(item.id))
                #endif
            }
        }
        if item.lastConnected != nil {
            Button("上次连接信息") {
                if let report = library.lastReport(for: item.id) { historicalReport = report }
                else { ownError = "此设备尚无这台电脑的连接信息。" }
            }
        }
        Button(item.saved ? "编辑连接" : "保存") { editor = EditorRequest(purpose: .edit, computer: item) }
        if let preview = library.previews[item.id] {
            Button("查看上次桌面快照") { selectedPreview = preview }
            Button("清除桌面快照", role: .destructive) {
                do { try library.clearPreview(for: item.id) }
                catch { ownError = error.localizedDescription }
            }
        }
        if item.saved {
            Button("复制连接") { editor = EditorRequest(purpose: .new, computer: library.archive.duplicate(of: item)) }
        }
        Button(item.favorite ? "取消收藏" : "添加到收藏") {
            var copy = item
            copy.saved = true
            copy.favorite.toggle()
            library.save(copy)
        }
        if item.saved, !library.archive.folders.isEmpty {
            Menu("移到文件夹") {
                Button("所有连接") { library.move(item.id, toFolder: nil, in: .custom) }
                ForEach(library.archive.folders, id: \.self) { name in
                    Button(name) { library.move(item.id, toFolder: name, in: .custom) }
                }
            }
        }
        if item.isLink, !library.archive.folders(in: .links).isEmpty {
            Menu("移到链接文件夹") {
                Button("所有链接") { library.move(item.id, toFolder: nil, in: .links) }
                ForEach(library.archive.folders(in: .links), id: \.self) { name in
                    Button(name) { library.move(item.id, toFolder: name, in: .links) }
                }
            }
        }
        if let url = item.sharedConnectionURL(for: .current) {
            ShareLink(item: url) { Label("链接", systemImage: "square.and.arrow.up") }
        }
        Button("删除", role: .destructive) { deletion = item }
    }

    private var canUseLibraryMenu: Bool {
        !privacy.locked && editor == nil && !settings && !downloads && !importFile && !exportFile
            && !showFolder && deletingFolder == nil && deletion == nil
    }

    #if targetEnvironment(macCatalyst)
    private var libraryMenu: MacLibraryMenuActions? {
        guard canUseLibraryMenu, !showsDiagnostics else { return nil }
        return MacLibraryMenuActions(quickConnect: { editor = EditorRequest(purpose: .quick) },
                                     create: newEntry, settings: { settings = true }, transfers: { downloads = true },
                                     diagnostics: { showsDiagnostics = true }, toolbarVisible: $libraryToolbarVisible)
    }
    #elseif os(iOS)
    private var padLibraryMenu: PadLibraryMenuActions? {
        guard UIDevice.current.userInterfaceIdiom == .pad, canUseLibraryMenu, scenePhase != .background else { return nil }
        return PadLibraryMenuActions(quickConnect: { editor = EditorRequest(purpose: .quick) }, create: newEntry,
                                     settings: { settings = true }, transfers: { downloads = true })
    }
    #endif

    private var canSaveFolder: Bool {
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && (name == renamingFolder || !library.archive.folders(in: editingFolderScope).contains(name))
    }

    private func newEntry() {
        if case let .folder(name) = page { editor = EditorRequest(purpose: .new, folder: name) }
        else { editor = EditorRequest(purpose: .new) }
    }

    private func open(_ request: LibraryWindowRequest) {
        switch request {
        case .connection(let id): present(.saved(id))
        case .quickConnect: present(.quick)
        case .collection(let destination):
            if hiddenItems.isDisjoint(with: destination.sidebarItem) {
                page = destination.fallback(in: library.archive, hiddenItems: hiddenItems) ?? destination
            }
        }
    }

    private func open(_ entry: Computer, suggestedSSHPort: UInt16? = nil) {
        guard !privacy.locked else { queuedRoute = .saved(entry.id); return }
        if entry.saved || entry.lastConnected != nil,
           let request = try? SessionRequest.remembered(for: entry, synchronize: preferences.bool(forKey: "credentials.synchronize")) {
            start(request)
        } else {
            editor = EditorRequest(purpose: .connect, computer: entry, suggestedSSHPort: suggestedSSHPort)
        }
    }

    private func start(_ request: SessionRequest) {
        editor = nil
        #if targetEnvironment(macCatalyst)
        if !isConnectionWindow, let source = windowSource.scene {
            availability.connectionWindows.open(.session(request), from: source, tabs: connectionTabs) {
                activeSession = request
            }
            return
        }
        #endif
        activeSession = request
    }

    #if targetEnvironment(macCatalyst)
    private func openConnectionWindow(_ id: UUID, tabs: MacConnectionTabs) {
        let request = LibraryWindowRequest.connection(id)
        guard let source = windowSource.scene else { openWindow(value: request); return }
        availability.connectionWindows.open(.route(.saved(id)), from: source, tabs: tabs) {
            openWindow(value: request)
        }
    }
    #endif

    private func saveDiscovered(_ entry: Computer, suggestedSSHPort: UInt16? = nil,
                                resolvedAddresses: Set<Endpoint> = []) {
        guard !privacy.locked else { return }
        editor = DiscoveredProfileSelection(computer: entry, suggestedSSHPort: suggestedSSHPort,
                                            intent: .save, resolvedAddresses: resolvedAddresses).request(in: library)
    }

    private func openNearbySearchResult(_ entry: NearbyComputer, quality: PictureQuality?) {
        nearby.select(entry) { computer, addresses in
            endUnifiedSearch()
            openDiscovered(computer, suggestedSSHPort: nil, quality: quality, resolvedAddresses: addresses)
        }
    }

    private func openDiscovered(_ entry: Computer, suggestedSSHPort: UInt16?, quality: PictureQuality?,
                                resolvedAddresses: Set<Endpoint> = []) {
        guard !privacy.locked else { return }
        editor = .connectingToDiscovered(entry, in: library, suggestedSSHPort: suggestedSSHPort, quality: quality,
                                         resolvedAddresses: resolvedAddresses)
    }

    private func present(_ route: ConnectionRoute) {
        guard !privacy.locked else { queuedRoute = route; return }
        do {
            let request = try editorRequest(for: route)
            if case .saved = route, let entry = request.computer { open(entry, suggestedSSHPort: request.suggestedSSHPort) }
            else { editor = request }
        } catch { ownError = error.localizedDescription }
    }

    private func editorRequest(for route: ConnectionRoute) throws -> EditorRequest {
        switch route {
        case .quick: return EditorRequest(purpose: .quick)
        case .address(let endpoint): return EditorRequest(purpose: .quick, initialAddress: endpoint.address)
        case .secureAddress(let endpoint, let port, let server):
            return EditorRequest(purpose: .quick, initialAddress: endpoint.address, initialSSHPort: port, initialSSHServer: server)
        case .sharedAddress(let endpoint, let port, let server, let options):
            return EditorRequest(purpose: .quick, initialAddress: endpoint.address, initialSSHPort: port,
                                 initialSSHServer: server, sharedOptions: options)
        case .desktopLink(let link):
            #if targetEnvironment(macCatalyst)
            return try EditorRequest.from(link, in: library.archive, allowUnsavedHost: true)
            #else
            return try EditorRequest.from(link, in: library.archive, allowUnsavedHost: false)
            #endif
        case .saved(let id):
            if let entry = library.archive.computers.first(where: { $0.id == id }) {
                return EditorRequest(purpose: .connect, computer: entry)
            }
            guard let entry = tailnet.computerForWidget(id) else {
                throw EditorRequest.LinkError.missingComputer
            }
            return EditorRequest(purpose: .connect, computer: entry, suggestedSSHPort: tailnet.ports(for: id)?.ssh)
        }
    }
}
