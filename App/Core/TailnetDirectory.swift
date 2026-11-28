import Foundation
import Network
import Observation

struct TailnetAccount: Codable, Equatable, Sendable {
    let tailnet: String
    let clientID: String

    // Tailscale's public CLI uses a placeholder client ID when given an OAuth secret.
    // Retain the ID on saved accounts so previously stored Keychain items still resolve.
    init(tailnet: String, clientID: String = "telescope") throws {
        let name = tailnet.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let valid = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-_@")
        guard !name.isEmpty, ![".", ".."].contains(name), name.utf8.count <= 253,
              name.unicodeScalars.allSatisfy(valid.contains),
              !id.isEmpty, id.utf8.count <= 256, id.unicodeScalars.allSatisfy(valid.contains) else { throw URLError(.badURL) }
        self.tailnet = name
        self.clientID = id
    }

    static func oauthSecret(from input: String) -> String? {
        let secret = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "tskey-client-"
        guard secret.hasPrefix(prefix), secret.utf8.count > prefix.utf8.count,
              secret.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        return secret
    }

    var devicesURL: URL {
        URL(string: "https://api.tailscale.com/api/v2/tailnet")!.appending(path: tailnet).appending(path: "devices")
    }

    func tokenRequest(secret: String) throws -> URLRequest {
        guard !secret.isEmpty else { throw URLError(.userAuthenticationRequired) }
        let values = [("grant_type", "client_credentials"), ("client_id", clientID), ("client_secret", secret), ("scope", "devices:core:read")]
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var request = URLRequest(url: URL(string: "https://api.tailscale.com/api/v2/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let encoded = try values.map { key, value in
            guard let text = value.addingPercentEncoding(withAllowedCharacters: unreserved) else { throw URLError(.badURL) }
            return key + "=" + text
        }
        request.httpBody = Data(encoded.joined(separator: "&").utf8)
        return request
    }

    func credentialKey() throws -> Computer {
        var result = Computer(endpoint: try Endpoint(address: "api.tailscale.com"))
        result.username = tailnet + "/" + clientID
        return result
    }
}

struct TailnetDevice: Decodable, Identifiable, Sendable {
    enum DesktopSystem: String, Codable, Sendable {
        case mac, windows, linux, raspberryPi, unspecified, other

        var name: String? {
            switch self {
            case .mac: "macOS"
            case .windows: "Windows"
            case .linux: "Linux"
            case .raspberryPi: "Raspberry Pi"
            case .unspecified, .other: nil
            }
        }

        var symbol: String {
            switch self {
            case .windows: "pc"
            case .raspberryPi: "cpu"
            default: "desktopcomputer"
            }
        }

        var offersHighPerformance: Bool { self == .mac || self == .unspecified }

        func details(address: String) -> String {
            guard let name else { return address }
            return "\(address) · \(name)"
        }

        func computer(name: String, endpoint: Endpoint) -> Computer {
            var computer = Computer(name: name, endpoint: endpoint)
            computer.saved = false
            switch self {
            case .mac:
                computer.desktopPlatform = .mac
                computer.screensOperatingSystem = 1
            case .raspberryPi:
                computer.desktopPlatform = .raspberryPi
                computer.screensOperatingSystem = 5
            case .windows: computer.desktopPlatform = .windows
            case .linux: computer.desktopPlatform = .linux
            case .unspecified, .other: break
            }
            if !offersHighPerformance { computer.hardwareKeyboardMode = .unicode }
            return computer
        }
    }

    let id: String
    let nodeId: String?
    let hostname: String
    let name: String
    let addresses: [String]
    let os: String?
    let authorized: Bool?

    var desktopSystem: DesktopSystem? {
        switch os?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "" {
        case "": .unspecified
        case "macos", "darwin": .mac
        case "windows": .windows
        case "linux": .linux
        case "raspbian", "raspberrypi", "raspberry pi os": .raspberryPi
        case "ios", "ipados", "android", "tvos", "visionos", "js": nil
        default: .other
        }
    }

    var computer: Computer? {
        guard authorized != false, let desktopSystem else { return nil }
        guard let address = addresses.compactMap({ try? Endpoint(address: $0) }).first ??
                (try? Endpoint(address: name)) else { return nil }
        return desktopSystem.computer(name: hostname.isEmpty ? name : hostname, endpoint: address)
    }

    func advertisedEndpoints(port: UInt16) -> Set<Endpoint> {
        var hosts = addresses.filter {
            switch NWEndpoint.Host($0) {
            case .ipv4, .ipv6: true
            default: false
            }
        }
        // The short machine name can also resolve outside this Tailnet.
        let qualifiedName = name.hasSuffix(".") ? String(name.dropLast()) : name
        if qualifiedName.contains("."), let host = try? Endpoint.hostOnly(qualifiedName) {
            hosts.append(host)
            hosts.append(host + ".")
        }
        return Set(hosts.compactMap { try? Endpoint(address: $0, defaultPort: port) })
    }

    func matches(_ query: LibrarySearchQuery, computer: Computer, folder: String? = nil) -> Bool {
        guard !query.isEmpty else { return true }
        let fields = [hostname, name, desktopSystem?.name, folder, computer.endpoint.address, String(computer.endpoint.port)]
        let sockets = advertisedEndpoints(port: computer.endpoint.port).map(\.address)
        return query.matches(fields + (addresses + sockets).map(Optional.some))
    }

    func directoryID(in account: TailnetAccount) -> UUID? {
        guard !id.isEmpty else { return nil }
        // The same node keeps its identity across renames and address changes.
        let identity = "local.nikey.desklink/tailnet/" + account.tailnet.lowercased() + "/" + id
        return UUID.derived(from: identity)
    }
}

struct TailnetDevicePorts: Codable, Equatable, Sendable {
    let vnc: UInt16?
    let ssh: UInt16?

    init(vnc: String, ssh: String) throws {
        self.vnc = try Self.parse(vnc)
        self.ssh = try Self.parse(ssh)
    }

    private static func parse(_ text: String) throws -> UInt16? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard value.utf8.allSatisfy({ (48...57).contains($0) }), let port = UInt16(value), port != 0 else {
            throw Endpoint.ParseError.invalidPort
        }
        return port
    }
}

struct TailnetFolder: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
}

struct TailnetFolderImportResult: Equatable {
    var foldersAdded = 0
    var devicesAssigned = 0
    var groupsSkipped = 0
}

struct TailnetSearchMatch: Identifiable, Equatable {
    let id: String
    let computer: Computer
    let folder: String?
    let sshPort: UInt16?
    let system: TailnetDevice.DesktopSystem
    let advertisedEndpoints: Set<Endpoint>
    var offersHighPerformance: Bool { system.offersHighPerformance }
}

private final class FixedServiceDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor @Observable
final class TailnetDirectory {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private struct Token: Decodable { let access_token: String; let token_type: String }
    private struct Listing: Decodable { let devices: [TailnetDevice] }
    private struct RememberedDirectory: Codable {
        let account: TailnetAccount
        // Older caches stored only name and address. Refresh them before offering those targets.
        let desktopTargets: [DesktopTarget]?
    }
    private struct DesktopTarget: Codable {
        let entity: ComputerEntity
        let system: TailnetDevice.DesktopSystem
    }
    private struct Folders: Codable {
        var entries = [TailnetFolder]()
        var assignments = [UUID: UUID]()
        var selection: UUID?
    }
    private static let hiddenDevicesKey = "tailnet.hiddenDevices"
    private static let devicePortsKey = "tailnet.devicePorts"
    private static let foldersKey = "tailnet.folders"
    private static let session = URLSession(configuration: .ephemeral, delegate: FixedServiceDelegate(), delegateQueue: nil)

    private let defaults: UserDefaults
    private let transport: Transport
    private let localAddresses: Set<String>?
    private var secret: String?
    private var attempt = UUID()
    private var hiddenIDs: Set<UUID>
    private var devicePorts: [UUID: TailnetDevicePorts]
    private var foldersByTailnet: [String: Folders]
    private var widgetCandidates = [DesktopTarget]()
    private(set) var account: TailnetAccount?
    private(set) var devices = [TailnetDevice]()
    private(set) var localNetworkDetected: Bool?
    @ObservationIgnored private var directoryAddresses = Set<NWEndpoint.Host>()
    private(set) var needsWidgetDirectoryRefresh = false
    private var hasLoadedDevices = false
    private(set) var loading = false
    var error: String?

    var visibleDevices: [TailnetDevice] { devices.filter { !isHidden($0) } }
    var hiddenDevices: [TailnetDevice] { devices.filter { isHidden($0) } }
    var folders: [TailnetFolder] { activeFolders.entries }
    var canImportArchiveFolders: Bool { account != nil && hasLoadedDevices && !loading && error == nil }
    var selectedFolder: TailnetFolder? {
        guard let selection = activeFolders.selection else { return nil }
        return folders.first { $0.id == selection }
    }
    var devicesInSelectedFolder: [TailnetDevice] {
        guard let selection = selectedFolder?.id else { return visibleDevices }
        return visibleDevices.filter { folderID(for: $0) == selection }
    }

    func devicesInSelectedFolder(matching query: LibrarySearchQuery) -> [TailnetDevice] {
        let devices = devicesInSelectedFolder
        guard !query.isEmpty else { return devices }
        return matchingDevices(devices, query: query).map(\.device)
    }

    func searchMatches(_ query: LibrarySearchQuery) -> [TailnetSearchMatch] {
        matchingDevices(visibleDevices, query: query).compactMap { device, computer, folder in
            guard let system = device.desktopSystem else { return nil }
            let sshPort = directoryID(for: device).flatMap { ports(for: $0)?.ssh }
            return TailnetSearchMatch(id: device.id, computer: computer, folder: folder,
                                      sshPort: sshPort, system: system,
                                      advertisedEndpoints: device.advertisedEndpoints(port: computer.endpoint.port))
        }
    }

    private func matchingDevices(_ devices: [TailnetDevice], query: LibrarySearchQuery)
        -> [(device: TailnetDevice, computer: Computer, folder: String?)]
    {
        let names = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.name) })
        return devices.compactMap { device in
            guard let computer = computer(for: device) else { return nil }
            let folder = folderID(for: device).flatMap { names[$0] }
            guard device.matches(query, computer: computer, folder: folder) else { return nil }
            return (device, computer, folder)
        }
    }

    private var activeFolders: Folders {
        guard let key = account?.tailnet.lowercased() else { return Folders() }
        return foldersByTailnet[key] ?? Folders()
    }

    var widgetComputers: [ComputerEntity] {
        widgetCandidates.map(\.entity).filter { !hiddenIDs.contains($0.id) }.map { item in
            guard devicePorts[item.id]?.vnc != nil, let endpoint = try? Endpoint(address: item.address) else { return item }
            let configured = configuredEndpoint(endpoint, for: item.id)
            return ComputerEntity(id: item.id, name: item.name, address: configured.address)
        }
    }

    init(defaults: UserDefaults = .standard,
         localAddresses: Set<String>? = nil,
         transport: Transport? = nil) {
        self.defaults = defaults
        self.localAddresses = localAddresses
        hiddenIDs = Set((defaults.stringArray(forKey: Self.hiddenDevicesKey) ?? []).compactMap(UUID.init(uuidString:)))
        devicePorts = defaults.data(forKey: Self.devicePortsKey)
            .flatMap { try? JSONDecoder().decode([UUID: TailnetDevicePorts].self, from: $0) } ?? [:]
        foldersByTailnet = defaults.data(forKey: Self.foldersKey)
            .flatMap { try? JSONDecoder().decode([String: Folders].self, from: $0) } ?? [:]
        self.transport = transport ?? { request in
            let (data, response) = try await Self.session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return (data, response)
        }
        if let data = defaults.data(forKey: "tailnet.account") {
            let decoder = JSONDecoder()
            let cache = try? decoder.decode(RememberedDirectory.self, from: data)
            if let stored = cache?.account ?? (try? decoder.decode(TailnetAccount.self, from: data)),
               let validated = try? TailnetAccount(tailnet: stored.tailnet, clientID: stored.clientID) {
                account = validated
                widgetCandidates = cache?.desktopTargets ?? []
                needsWidgetDirectoryRefresh = cache?.desktopTargets == nil
            }
        }
    }

    func link(_ new: TailnetAccount, secret: String, remember: Bool) async throws {
        let generation = UUID()
        attempt = generation
        loading = true
        defer { if attempt == generation { loading = false } }
        let listing = try await requestListing(new, secret: secret)
        try Task.checkCancellation()
        guard generation == attempt else { throw CancellationError() }
        if remember { try PasswordStore.write(secret, for: new.credentialKey(), kind: .tailnet) }
        if let previous = account, defaults.data(forKey: "tailnet.account") != nil, previous != new || !remember {
            try PasswordStore.write(nil, for: previous.credentialKey(), kind: .tailnet)
        }
        let desktops = desktopDevices(in: listing)
        try storeWidgetComputers(desktops, account: new, remember: remember)
        account = new
        self.secret = secret
        setLoadedDevices(from: listing, desktops: desktops)
        error = nil
    }

    #if DEBUG
    func installTestListing(_ json: String) {
        guard let listing = try? JSONDecoder().decode(Listing.self, from: Data(json.utf8)),
              let testAccount = try? TailnetAccount(tailnet: "fixture.invalid") else { return }
        account = testAccount
        setLoadedDevices(from: listing, desktops: desktopDevices(in: listing))
    }
    #endif

    func refresh() async {
        guard let account, !loading else { return }
        let generation = UUID()
        attempt = generation
        loading = true
        defer { if attempt == generation { loading = false } }
        do {
            guard let proof = try secret ?? PasswordStore.read(account.credentialKey(), kind: .tailnet) else {
                throw URLError(.userAuthenticationRequired)
            }
            let listing = try await requestListing(account, secret: proof)
            if attempt == generation {
                let desktops = desktopDevices(in: listing)
                try storeWidgetComputers(desktops, account: account, remember: defaults.data(forKey: "tailnet.account") != nil)
                setLoadedDevices(from: listing, desktops: desktops)
                error = nil
            }
        } catch {
            if attempt == generation, !Task.isCancelled { self.error = Self.authErrorMessage(error) }
        }
    }

    func unlink() throws {
        if let account, defaults.data(forKey: "tailnet.account") != nil {
            try PasswordStore.write(nil, for: account.credentialKey(), kind: .tailnet)
        }
        attempt = UUID()
        account = nil
        secret = nil
        devices = []
        localNetworkDetected = nil
        directoryAddresses = []
        hasLoadedDevices = false
        widgetCandidates = []
        needsWidgetDirectoryRefresh = false
        loading = false
        error = nil
        defaults.removeObject(forKey: "tailnet.account")
    }

    func setHidden(_ hidden: Bool, device: TailnetDevice) {
        guard let account, let id = device.directoryID(in: account) else { return }
        if hidden { hiddenIDs.insert(id) } else { hiddenIDs.remove(id) }
        defaults.set(hiddenIDs.map(\.uuidString).sorted(), forKey: Self.hiddenDevicesKey)
    }

    private func isHidden(_ device: TailnetDevice) -> Bool {
        guard let account, let id = device.directoryID(in: account) else { return false }
        return hiddenIDs.contains(id)
    }

    func directoryID(for device: TailnetDevice) -> UUID? {
        account.flatMap { device.directoryID(in: $0) }
    }

    func folderID(for device: TailnetDevice) -> UUID? {
        guard let id = directoryID(for: device) else { return nil }
        return activeFolders.assignments[id]
    }

    func selectFolder(_ id: UUID?) {
        guard id == nil || folders.contains(where: { $0.id == id }),
              id != selectedFolder?.id else { return }
        changeFolders { $0.selection = id }
    }

    func canNameFolder(_ input: String, excluding id: UUID? = nil) -> Bool {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return account != nil && !name.isEmpty && !folders.contains {
            $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
    }

    func addFolder(_ input: String) {
        guard canNameFolder(input) else { return }
        let folder = TailnetFolder(name: input.trimmingCharacters(in: .whitespacesAndNewlines))
        changeFolders {
            $0.entries.append(folder)
            $0.selection = folder.id
        }
    }

    func renameFolder(_ id: UUID, to input: String) {
        guard canNameFolder(input, excluding: id), let index = folders.firstIndex(where: { $0.id == id }) else { return }
        changeFolders { $0.entries[index].name = input.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func removeFolder(_ id: UUID) {
        guard folders.contains(where: { $0.id == id }) else { return }
        changeFolders {
            $0.entries.removeAll { $0.id == id }
            $0.assignments = $0.assignments.filter { $0.value != id }
            if $0.selection == id { $0.selection = nil }
        }
    }

    func moveDevice(_ id: UUID, to folder: UUID?) {
        guard devices.contains(where: { directoryID(for: $0) == id }),
              folder == nil || folders.contains(where: { $0.id == folder }),
              activeFolders.assignments[id] != folder else { return }
        changeFolders { $0.assignments[id] = folder }
    }

    func importArchiveFolders(_ groups: [ScreensDirectoryFolder], into target: TailnetAccount) throws -> TailnetFolderImportResult {
        guard account == target, canImportArchiveFolders else { throw URLError(.resourceUnavailable) }

        var deviceIDs: [String: Set<UUID>] = [:]
        for device in devices {
            guard let id = device.directoryID(in: target) else { continue }
            for identifier in [device.id, device.nodeId].compactMap({ $0 }).filter({ !$0.isEmpty }) {
                deviceIDs[identifier, default: []].insert(id)
            }
        }

        var requestedMemberships: [UUID: Int] = [:]
        let matchedGroups = groups.map { group in
            let members = Set((group.rawItems ?? []).compactMap { identifier -> UUID? in
                guard let matches = deviceIDs[identifier], matches.count == 1 else { return nil }
                return matches.first
            })
            for member in members { requestedMemberships[member, default: 0] += 1 }
            return (group, members)
        }

        var next = activeFolders
        var result = TailnetFolderImportResult()
        for (group, members) in matchedGroups {
            let name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let destination = next.entries.first { $0.id == group.id }
                ?? next.entries.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
            let assignments = members.filter { next.assignments[$0] == nil && requestedMemberships[$0] == 1 }
            let isEmptyGroup = group.items.isEmpty && (group.rawItems?.isEmpty ?? true)
            guard !name.isEmpty, !assignments.isEmpty || (isEmptyGroup && destination == nil) else {
                result.groupsSkipped += 1
                continue
            }

            let folder = destination ?? TailnetFolder(id: group.id, name: name)
            if destination == nil {
                next.entries.append(folder)
                result.foldersAdded += 1
            }
            for member in assignments { next.assignments[member] = folder.id }
            result.devicesAssigned += assignments.count
        }
        if result.foldersAdded > 0 || result.devicesAssigned > 0 {
            guard changeFolders({ $0 = next }) else { throw CocoaError(.fileWriteUnknown) }
        }
        return result
    }

    @discardableResult private func changeFolders(_ update: (inout Folders) -> Void) -> Bool {
        guard let key = account?.tailnet.lowercased() else { return false }
        var updated = foldersByTailnet
        update(&updated[key, default: Folders()])
        if updated[key]?.entries.isEmpty == true { updated[key] = nil }
        guard let data = try? JSONEncoder().encode(updated) else { return false }
        defaults.set(data, forKey: Self.foldersKey)
        foldersByTailnet = updated
        return true
    }

    func ports(for id: UUID) -> TailnetDevicePorts? { devicePorts[id] }

    func setPorts(_ ports: TailnetDevicePorts, for id: UUID) throws {
        guard devices.contains(where: { directoryID(for: $0) == id }) else { throw URLError(.resourceUnavailable) }
        var updated = devicePorts
        updated[id] = ports.vnc == nil && ports.ssh == nil ? nil : ports
        guard updated != devicePorts else { return }
        defaults.set(try JSONEncoder().encode(updated), forKey: Self.devicePortsKey)
        devicePorts = updated
    }

    func computer(for device: TailnetDevice) -> Computer? {
        guard var computer = device.computer else { return nil }
        if let id = directoryID(for: device) { computer.endpoint = configuredEndpoint(computer.endpoint, for: id) }
        return computer
    }

    private func configuredEndpoint(_ endpoint: Endpoint, for id: UUID) -> Endpoint {
        guard let port = devicePorts[id]?.vnc else { return endpoint }
        return (try? Endpoint(address: endpoint.host, defaultPort: port)) ?? endpoint
    }

    func computerForWidget(_ id: UUID) -> Computer? {
        guard !hiddenIDs.contains(id), let target = widgetCandidates.first(where: { $0.entity.id == id }),
              let endpoint = try? Endpoint(address: target.entity.address) else { return nil }
        return target.system.computer(name: target.entity.name, endpoint: configuredEndpoint(endpoint, for: id))
    }

    private func storeWidgetComputers(_ listing: [TailnetDevice], account: TailnetAccount, remember: Bool) throws {
        guard remember else {
            defaults.removeObject(forKey: "tailnet.account")
            widgetCandidates = []
            needsWidgetDirectoryRefresh = false
            return
        }
        let desktopTargets = listing.compactMap { device -> DesktopTarget? in
            guard let id = device.directoryID(in: account), let computer = device.computer,
                  let system = device.desktopSystem else { return nil }
            let entity = ComputerEntity(id: id, name: computer.displayName, address: computer.endpoint.address)
            return DesktopTarget(entity: entity, system: system)
        }
        let cache = RememberedDirectory(account: account, desktopTargets: desktopTargets)
        defaults.set(try JSONEncoder().encode(cache), forKey: "tailnet.account")
        widgetCandidates = desktopTargets
        needsWidgetDirectoryRefresh = false
    }

    private func requestListing(_ account: TailnetAccount, secret: String) async throws -> Listing {
        let authentication = try await data(for: account.tokenRequest(secret: secret))
        let token = try JSONDecoder().decode(Token.self, from: authentication)
        guard token.token_type.lowercased() == "bearer", !token.access_token.isEmpty else { throw URLError(.userAuthenticationRequired) }
        var request = URLRequest(url: account.devicesURL)
        request.setValue("Bearer " + token.access_token, forHTTPHeaderField: "Authorization")
        let response = try await data(for: request)
        try Task.checkCancellation()
        return try JSONDecoder().decode(Listing.self, from: response)
    }

    private func setLoadedDevices(from listing: Listing, desktops: [TailnetDevice]) {
        devices = desktops
        hasLoadedDevices = true
        // Keep mobile and local nodes available for detection even when they are not desktop targets.
        directoryAddresses = Self.numericHosts(listing.devices.lazy.filter { $0.authorized != false }.flatMap(\.addresses))
        refreshLocalNetworkStatus()
    }

    func refreshLocalNetworkStatus(tunnelAddresses: Set<String>? = nil) {
        guard hasLoadedDevices else { return }
        let detected = Self.numericHosts(tunnelAddresses ?? NearbyLocalIdentity.interfaceAddresses(tunnelsOnly: true))
            .contains { host in
                switch host {
                case .ipv6(let address):
                    return address.rawValue.starts(with: [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0])
                case .ipv4(let address):
                    // Providers and other VPNs may also use the CGNAT range.
                    return address.rawValue.first == 100 && (64...127).contains(address.rawValue[1])
                        && directoryAddresses.contains(host)
                default:
                    return false
                }
            }
        if localNetworkDetected != detected { localNetworkDetected = detected }
    }

    private func desktopDevices(in listing: Listing) -> [TailnetDevice] {
        let localHosts = Self.numericHosts(localAddresses ?? NearbyLocalIdentity.interfaceAddresses())
        return listing.devices.filter { device in
            let hosts = Self.numericHosts(device.addresses)
            return device.computer != nil && (hosts.isEmpty || !hosts.isSubset(of: localHosts))
        }.sorted { $0.hostname.localizedStandardCompare($1.hostname) == .orderedAscending }
    }

    private static func numericHosts(_ addresses: some Sequence<String>) -> Set<NWEndpoint.Host> {
        Set(addresses.compactMap { address in
            let host = NWEndpoint.Host(String(address.prefix { $0 != "%" }))
            switch host {
            case .ipv4, .ipv6: return host
            default: return nil
            }
        })
    }

    static func authErrorMessage(_ error: Error) -> String {
        if (error as? URLError)?.code == .userAuthenticationRequired {
            return String(localized: "Tailscale 无法授权。请检查账户信息及读取设备的权限。")
        }
        return error.localizedDescription
    }

    private func data(for request: URLRequest) async throws -> Data {
        var request = request
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await transport(request)
        if [401, 403].contains(response.statusCode) { throw URLError(.userAuthenticationRequired) }
        guard (200..<300).contains(response.statusCode) else { throw URLError(.badServerResponse) }
        return data
    }
}
