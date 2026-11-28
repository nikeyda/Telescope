import Foundation
import Network
import Observation
import dnssd
import Darwin

struct NearbyComputer: Identifiable {
    let service: NetService
    var endpoint: Endpoint? = nil
    var numericAddresses: [String] = []
    var macFamily: NearbyMacFamily? = nil
    var id: String { Self.id(for: service) }
    var name: String { service.name }
    var address: String? { endpoint?.address }
    var symbol: String { macFamily?.symbol ?? "desktopcomputer" }
    var detail: String? {
        guard let family = macFamily?.rawValue, !name.localizedCaseInsensitiveContains(family) else { return address }
        return address.map { "\(family) · \($0)" } ?? family
    }

    func matches(_ query: LibrarySearchQuery) -> Bool {
        guard let endpoint else { return query.matches([name]) }
        let addresses = ([endpoint.host] + numericAddresses).map { host in
            let literal = host.contains(":") ? "[\(host)]" : host
            return "\(literal):\(endpoint.port)"
        }
        return query.matches([name, macFamily?.rawValue] + addresses.map(Optional.some))
    }

    static func id(for service: NetService) -> String {
        service.domain + "/" + service.type + "/" + service.name
    }
}

enum NearbyMacFamily: String {
    case macBook = "MacBook"
    case macMini = "Mac mini"
    case iMac = "iMac"
    case macStudio = "Mac Studio"
    case macPro = "Mac Pro"

    var symbol: String {
        switch self {
        case .macBook: "laptopcomputer"
        case .macMini: "macmini"
        case .iMac: "desktopcomputer"
        case .macStudio: "macstudio"
        case .macPro: "macpro.gen3"
        }
    }

    init?(txtRecord: Data) {
        let values = NetService.dictionary(fromTXTRecord: txtRecord)
        guard let model = values["model"].flatMap({ String(data: $0, encoding: .utf8) })?.lowercased() else { return nil }
        // Older identifiers encode the family. Recent generic Mac identifiers must match an Apple model listing.
        switch model {
        case "mac14,2", "mac14,5", "mac14,6", "mac14,7", "mac14,9", "mac14,10", "mac14,15",
             "mac15,3", "mac15,6", "mac15,7", "mac15,8", "mac15,9", "mac15,10", "mac15,11", "mac15,12", "mac15,13",
             "mac16,1", "mac16,5", "mac16,6", "mac16,7", "mac16,8", "mac16,12", "mac16,13",
             "mac17,2", "mac17,3", "mac17,4", "mac17,6", "mac17,7", "mac17,8", "mac17,9":
            self = .macBook
        case "mac14,3", "mac14,12", "mac16,10", "mac16,11", "mac17,16", "mac18,5":
            self = .macMini
        case "mac15,4", "mac15,5", "mac16,2", "mac16,3":
            self = .iMac
        case "mac13,1", "mac13,2", "mac14,13", "mac14,14", "mac15,14", "mac16,9", "mac17,14", "mac17,15":
            self = .macStudio
        case "mac14,8":
            self = .macPro
        default:
            let prefix = model.prefix { $0.isLetter }
            guard model.dropFirst(prefix.count).wholeMatch(of: /[0-9]+,[0-9]+/) != nil else { return nil }
            switch prefix {
            case "macbook", "macbookair", "macbookpro": self = .macBook
            case "macmini": self = .macMini
            case "imac", "imacpro": self = .iMac
            case "macpro": self = .macPro
            default: return nil
            }
        }
    }
}

@MainActor private final class NearbyMacModelQuery {
    private var reference: DNSServiceRef?
    private let update: (NearbyMacFamily?) -> Void

    private init(update: @escaping (NearbyMacFamily?) -> Void) { self.update = update }

    static func start(for service: NetService, update: @escaping (NearbyMacFamily?) -> Void) -> NearbyMacModelQuery? {
        var name = [CChar](repeating: 0, count: Int(kDNSServiceMaxDomainName))
        guard DNSServiceConstructFullName(&name, service.name, "_device-info._tcp", service.domain) == 0 else { return nil }
        let query = NearbyMacModelQuery(update: update)
        var reference: DNSServiceRef?
        let code = DNSServiceQueryRecord(&reference, DNSServiceFlags(kDNSServiceFlagsForceMulticast), 0, name,
                                         UInt16(kDNSServiceType_TXT), UInt16(kDNSServiceClass_IN),
                                         { _, flags, _, error, _, _, _, count, data, _, context in
            guard error == kDNSServiceErr_NoError, flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0, let data, let context,
                  let family = NearbyMacFamily(txtRecord: Data(bytes: data, count: Int(count))) else { return }
            MainActor.assumeIsolated {
                Unmanaged<NearbyMacModelQuery>.fromOpaque(context).takeUnretainedValue().finish(family)
            }
        }, Unmanaged.passUnretained(query).toOpaque())
        guard code == kDNSServiceErr_NoError, let reference else { return nil }
        guard DNSServiceSetDispatchQueue(reference, .main) == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(reference)
            return nil
        }
        query.reference = reference
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak query] in query?.finish(nil) }
        return query
    }

    private func finish(_ family: NearbyMacFamily?) {
        guard let reference else { return }
        self.reference = nil
        DNSServiceRefDeallocate(reference)
        update(family)
    }

    isolated deinit {
        if let reference { DNSServiceRefDeallocate(reference) }
    }
}

enum NearbyLocalIdentity {
    static func matches(_ service: NetService) -> Bool {
        let addresses = numericAddresses(for: service)
        return matches(host: service.hostName, addresses: addresses, localHost: ProcessInfo.processInfo.hostName,
                       localAddresses: addresses.isEmpty ? [] : interfaceAddresses())
    }

    static func numericAddresses(for service: NetService) -> [String] {
        (service.addresses ?? []).compactMap { data in
            data.withUnsafeBytes { bytes -> String? in
                guard bytes.count >= MemoryLayout<sockaddr>.size,
                      let address = bytes.bindMemory(to: sockaddr.self).baseAddress,
                      Int(address.pointee.sa_len) <= bytes.count else { return nil }
                return numericHost(address)
            }
        }
    }

    static func matches(host: String?, addresses: [String], localHost: String, localAddresses: Set<String>) -> Bool {
        if !addresses.isEmpty && addresses.allSatisfy(localAddresses.contains) { return true }
        let dots = CharacterSet(charactersIn: ".")
        var current = localHost.trimmingCharacters(in: dots).lowercased()
        guard !current.isEmpty else { return false }
        // A Mac can report an unqualified hostname while Bonjour appends .local.
        if !current.contains(".") { current += ".local" }
        return current.hasSuffix(".local") && host?.trimmingCharacters(in: dots).lowercased() == current
    }

    static func interfaceAddresses(tunnelsOnly: Bool = false) -> Set<String> {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }
        var addresses: Set<String> = []
        var next: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = next?.pointee {
            next = interface.ifa_next
            if tunnelsOnly {
                let required = UInt32(IFF_UP | IFF_RUNNING)
                let name = String(cString: interface.ifa_name)
                guard interface.ifa_flags & required == required,
                      name.hasPrefix("utun") || name.hasPrefix("tun") else { continue }
            }
            if let address = interface.ifa_addr, let host = numericHost(address) { addresses.insert(host) }
        }
        return addresses
    }

    private static func numericHost(_ address: UnsafePointer<sockaddr>) -> String? {
        let family = Int32(address.pointee.sa_family)
        let size: Int
        switch family {
        case AF_INET: size = MemoryLayout<sockaddr_in>.size
        case AF_INET6: size = MemoryLayout<sockaddr_in6>.size
        default: return nil
        }
        guard Int(address.pointee.sa_len) >= size else { return nil }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, socklen_t(size), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
            return nil
        }
        return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

@MainActor @Observable
final class NearbyComputers: NSObject, @preconcurrency NetServiceDelegate {
    private enum Discovery {
        case resolving(NetService)
        case hidden
        case visible(NearbyComputer)
    }

    private(set) var entries: [NearbyComputer] = []
    private(set) var isSearching = false
    var errorMessage: String?
    private(set) var searchError: NWError?
    var needsLocalNetworkAccess: Bool { searchError == .dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied)) }
    var isResolvingSelection: Bool { resolving != nil }
    private var browser: NWBrowser?
    private var discovery: [String: Discovery] = [:]
    private var modelQueries: [String: NearbyMacModelQuery] = [:]
    private var resolving: NetService?
    private var selection: ((Computer, Set<Endpoint>) -> Void)?
    private let isLocalComputer: ((NetService) -> Bool)?

    static var defaultLocalFilter: ((NetService) -> Bool)? {
        #if targetEnvironment(macCatalyst)
        NearbyLocalIdentity.matches
        #else
        nil
        #endif
    }

    init(localFilter: ((NetService) -> Bool)? = NearbyComputers.defaultLocalFilter) {
        isLocalComputer = localFilter
        super.init()
    }

    func start() {
        guard browser == nil else { return }
        entries = []
        errorMessage = nil
        searchError = nil
        isSearching = true
        let browser = NWBrowser(for: .bonjour(type: "_rfb._tcp", domain: "local."), using: .tcp)
        self.browser = browser
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            MainActor.assumeIsolated {
                guard let self, let browser, browser === self.browser else { return }
                self.updateSearchState(state)
            }
        }
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            MainActor.assumeIsolated {
                guard let self, let browser, browser === self.browser else { return }
                var found: [String: NearbyComputer] = [:]
                for result in results {
                    guard case let .service(name, type, domain, _) = result.endpoint else { continue }
                    let service = NetService(domain: domain, type: type, name: name)
                    let entry = NearbyComputer(service: service)
                    found[entry.id] = entry
                }
                self.updateDiscovered(found)
            }
        }
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        clearDiscovered()
        cancelSelection()
    }

    func retry() {
        stop()
        start()
    }

    func retryAfterLocalNetworkDenial() {
        guard browser != nil, needsLocalNetworkAccess else { return }
        retry()
    }

    func select(_ entry: NearbyComputer, completion: @escaping (Computer, Set<Endpoint>) -> Void) {
        guard entries.contains(where: { $0.id == entry.id }) else {
            reportMissingSelection()
            return
        }
        cancelSelection()
        errorMessage = nil
        let service = NetService(domain: entry.service.domain, type: entry.service.type, name: entry.name)
        resolving = service
        selection = completion
        service.delegate = self
        service.resolve(withTimeout: 8)
    }

    private func cancelSelection() {
        if let resolving { stopResolving(resolving) }
        resolving = nil
        selection = nil
    }

    private func reportMissingSelection() {
        cancelSelection()
        errorMessage = String(localized: "这台电脑已离开附近设备列表。请重新查找。")
    }

    func updateSearchState(_ state: NWBrowser.State) {
        switch state {
        case .waiting(let error), .failed(let error):
            searchError = error
            clearDiscovered()
            cancelSelection()
        case .ready:
            searchError = nil
            if discovery.isEmpty { isSearching = false }
        default: break
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        let endpoint = Self.endpoint(for: sender)
        if sender !== resolving {
            guard isLocalComputer?(sender) != true else {
                completeDiscovery(sender, result: .hidden)
                return
            }
            guard let endpoint else {
                completeDiscovery(sender, result: unresolvedDiscovery(sender))
                return
            }
            let entry = NearbyComputer(service: sender, endpoint: endpoint,
                                       numericAddresses: NearbyLocalIdentity.numericAddresses(for: sender))
            completeDiscovery(sender, result: .visible(entry))
            return
        }
        let action = selection
        let isLocal = isLocalComputer?(sender) == true
        let numericAddresses = NearbyLocalIdentity.numericAddresses(for: sender)
        cancelSelection()
        guard !isLocal else {
            let id = NearbyComputer.id(for: sender)
            modelQueries[id] = nil
            discovery[id] = .hidden
            publishDiscovered()
            errorMessage = String(localized: "这台电脑是本机。请选择另一台电脑。")
            return
        }
        guard let endpoint else {
            errorMessage = URLError(.cannotFindHost).localizedDescription
            return
        }
        var entry = Computer(name: sender.name, endpoint: endpoint)
        entry.saved = false
        let addresses = Set(numericAddresses.compactMap {
            try? Endpoint(address: $0, defaultPort: endpoint.port)
        })
        action?(entry, addresses)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        guard sender === resolving else {
            completeDiscovery(sender, result: unresolvedDiscovery(sender))
            return
        }
        errorMessage = Self.description(errorDict)
        cancelSelection()
    }

    private func updateDiscovered(_ found: [String: NearbyComputer]) {
        if let resolving, found[NearbyComputer.id(for: resolving)] == nil { reportMissingSelection() }
        for id in Array(discovery.keys) where found[id] == nil {
            modelQueries[id] = nil
            if case .resolving(let service) = discovery.removeValue(forKey: id) { stopResolving(service) }
        }
        for (id, entry) in found where discovery[id] == nil {
            discovery[id] = .resolving(entry.service)
            entry.service.delegate = self
            entry.service.resolve(withTimeout: 5)
        }
        publishDiscovered()
    }

    private func unresolvedDiscovery(_ service: NetService) -> Discovery {
        // Mobile keeps the discoverable row so the user can retry it by selecting it.
        isLocalComputer == nil ? .visible(NearbyComputer(service: service)) : .hidden
    }

    private func completeDiscovery(_ sender: NetService, result: Discovery) {
        let id = NearbyComputer.id(for: sender)
        guard case .resolving(let service) = discovery[id], service === sender else { return }
        stopResolving(sender)
        discovery[id] = result
        publishDiscovered()
        if case .visible(let entry) = result, entry.endpoint != nil {
            modelQueries[id] = NearbyMacModelQuery.start(for: sender) { [weak self] family in
                guard let self else { return }
                self.modelQueries[id] = nil
                guard let family, case .visible(var current) = self.discovery[id] else { return }
                current.macFamily = family
                self.discovery[id] = .visible(current)
                self.publishDiscovered()
            }
        }
    }

    private func publishDiscovered() {
        entries = sorted(discovery.values.compactMap {
            switch $0 {
            case .visible(let entry): entry
            case .resolving(let service) where isLocalComputer == nil: NearbyComputer(service: service)
            default: nil
            }
        })
        isSearching = discovery.values.contains {
            if case .resolving = $0 { return true }
            return false
        }
    }

    private func clearDiscovered() {
        for case .resolving(let service) in discovery.values { stopResolving(service) }
        modelQueries.removeAll()
        discovery.removeAll()
        entries = []
        isSearching = false
    }

    private func stopResolving(_ service: NetService) {
        service.delegate = nil
        service.stop()
    }

    private func sorted(_ entries: some Sequence<NearbyComputer>) -> [NearbyComputer] {
        entries.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    private static func endpoint(for service: NetService) -> Endpoint? {
        guard let host = service.hostName, let port = UInt16(exactly: service.port), port > 0 else { return nil }
        return try? Endpoint(address: host.trimmingCharacters(in: CharacterSet(charactersIn: ".")), defaultPort: port)
    }

    private static func description(_ error: [String: NSNumber]) -> String {
        NSError(domain: "NSNetServicesErrorDomain", code: error[NetService.errorCode]?.intValue ?? -1).localizedDescription
    }
}
