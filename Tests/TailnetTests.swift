import XCTest
@testable import DeskLink

final class TailnetTests: XCTestCase {
    @MainActor func testLocalNetworkDetectionUsesTunnelAddressesWithoutHidingRemoteDevices() async throws {
        let suite = "TelescopeTailnetNetwork." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = DirectoryFixture()
        await service.changeListing(to: #"""
        {"devices":[
            {"id":"remote","hostname":"Studio","name":"studio.fixture","addresses":["100.67.42.2"],"os":"macOS"},
            {"id":"mobile","hostname":"Tablet","name":"tablet.fixture","addresses":["100.68.42.3"],"os":"iOS"},
            {"id":"revoked","hostname":"Revoked","name":"revoked.fixture","addresses":["100.69.42.4"],"os":"iOS","authorized":false}
        ]}
        """#)
        let directory = TailnetDirectory(defaults: defaults, localAddresses: []) { try await service.reply(to: $0) }
        directory.refreshLocalNetworkStatus(tunnelAddresses: ["fd7a:115c:a1e0::10"])
        XCTAssertNil(directory.localNetworkDetected)
        try await directory.link(TailnetAccount(tailnet: "fixture.example"), secret: "fixture-only", remember: false)
        XCTAssertEqual(directory.visibleDevices.map(\.id), ["remote"])

        for addresses: Set<String> in [[], ["100.70.42.5"], ["100.69.42.4"], ["fd7a:115c:a1e1::10"]] {
            directory.refreshLocalNetworkStatus(tunnelAddresses: addresses)
            XCTAssertEqual(directory.localNetworkDetected, false)
        }
        directory.refreshLocalNetworkStatus(tunnelAddresses: ["100.68.42.3"])
        XCTAssertEqual(directory.localNetworkDetected, true)
        directory.refreshLocalNetworkStatus(tunnelAddresses: ["FD7A:115C:A1E0:0:0:0:0:10%utun2"])
        XCTAssertEqual(directory.localNetworkDetected, true)
        directory.refreshLocalNetworkStatus(tunnelAddresses: [])
        XCTAssertEqual(directory.localNetworkDetected, false)
        XCTAssertEqual(directory.visibleDevices.map(\.id), ["remote"])
        let requests = await service.methods
        XCTAssertEqual(requests, ["POST", "GET"])

        try directory.unlink()
        directory.refreshLocalNetworkStatus(tunnelAddresses: ["100.68.42.3"])
        XCTAssertNil(directory.localNetworkDetected)
    }

    @MainActor func testArchivedGroupsResolveExactDeviceIDsAndPreserveCurrentAssignments() async throws {
        let suite = "TelescopeTailnetImport." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = DirectoryFixture()
        await service.changeListing(to: #"""
        {"devices":[
            {"id":"1001","nodeId":"nStudio","hostname":"Desk","name":"desk.fixture","addresses":["100.64.1.1"],"os":"macOS"},
            {"id":"1002","nodeId":"nHome","hostname":"Home","name":"home.fixture","addresses":["100.64.1.2"],"os":"linux"},
            {"id":"1003","nodeId":"nConflict","hostname":"Shared","name":"shared.fixture","addresses":["100.64.1.3"],"os":"linux"},
            {"id":"1004","nodeId":"nRevoked","hostname":"Revoked","name":"revoked.fixture","addresses":["100.64.1.4"],"os":"linux","authorized":false}
        ]}
        """#)
        let account = try TailnetAccount(tailnet: "fixture.example", clientID: "fixture")
        let directory = TailnetDirectory(defaults: defaults) { try await service.reply(to: $0) }
        XCTAssertFalse(directory.canImportArchiveFolders)
        try await directory.link(account, secret: "fixture-only", remember: false)
        XCTAssertTrue(directory.canImportArchiveFolders)

        directory.addFolder("Studio")
        let existing = try XCTUnwrap(directory.selectedFolder)
        directory.addFolder("Home")
        let home = try XCTUnwrap(directory.selectedFolder)
        let homeDevice = try XCTUnwrap(directory.devices.first { $0.id == "1002" })
        directory.moveDevice(try XCTUnwrap(directory.directoryID(for: homeDevice)), to: home.id)
        let empty = UUID()
        let groups = [
            ScreensDirectoryFolder(id: UUID(), name: "studio", contentType: 16, items: [UUID()],
                                   rawItems: ["nStudio", "1001", "1002", "nConflict"]),
            ScreensDirectoryFolder(id: UUID(), name: "Conflicting", contentType: 16, items: [], rawItems: ["1003"]),
            ScreensDirectoryFolder(id: UUID(), name: "Unknown", contentType: 16, items: [UUID()],
                                   rawItems: ["shared.fixture", "100.64.1.3", "nRevoked"]),
            ScreensDirectoryFolder(id: empty, name: "Empty", contentType: 16, items: [], rawItems: []),
        ]

        let applied = try directory.importArchiveFolders(groups, into: account)
        XCTAssertEqual(applied, TailnetFolderImportResult(foldersAdded: 1, devicesAssigned: 1, groupsSkipped: 2))
        let desk = try XCTUnwrap(directory.devices.first { $0.id == "1001" })
        let conflict = try XCTUnwrap(directory.devices.first { $0.id == "1003" })
        XCTAssertEqual(directory.folderID(for: desk), existing.id)
        XCTAssertEqual(directory.folderID(for: homeDevice), home.id)
        XCTAssertNil(directory.folderID(for: conflict))
        XCTAssertEqual(directory.folders.map(\.id), [existing.id, home.id, empty])
        XCTAssertEqual(directory.selectedFolder, home)
        let initialRequests = await service.methods
        XCTAssertEqual(initialRequests, ["POST", "GET"])

        let reopened = TailnetDirectory(defaults: defaults) { try await service.reply(to: $0) }
        let other = try TailnetAccount(tailnet: "other.fixture", clientID: "different")
        try await reopened.link(other, secret: "fixture-only", remember: false)
        XCTAssertThrowsError(try reopened.importArchiveFolders(groups, into: account))
        XCTAssertTrue(reopened.folders.isEmpty)
        try await reopened.link(account, secret: "fixture-only", remember: false)
        XCTAssertEqual(reopened.folderID(for: desk), existing.id)
        XCTAssertEqual(try reopened.importArchiveFolders(groups, into: account), TailnetFolderImportResult(groupsSkipped: 4))
        XCTAssertEqual(reopened.folders.map(\.id), [existing.id, home.id, empty])
    }

    @MainActor func testUnifiedSearchFindsOutsideTheSelectedFolderAndKeepsPortsAndVisibility() async throws {
        let domain = "TelescopeTailnetSearch." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let service = DirectoryFixture()
        let directory = TailnetDirectory(defaults: defaults) { try await service.reply(to: $0) }
        try await directory.link(TailnetAccount(tailnet: "fixture.example", clientID: "fixture"),
                                 secret: "fixture-only", remember: false)
        let device = try XCTUnwrap(directory.visibleDevices.first)
        let id = try XCTUnwrap(directory.directoryID(for: device))
        directory.addFolder("Studio")
        let studio = try XCTUnwrap(directory.selectedFolder)
        directory.moveDevice(id, to: studio.id)
        directory.addFolder("Home")
        XCTAssertTrue(directory.devicesInSelectedFolder.isEmpty)
        try directory.setPorts(TailnetDevicePorts(vnc: "5910", ssh: "2200"), for: id)

        let query = LibrarySearchQuery("STUDIO 5910")
        let result = try XCTUnwrap(directory.searchMatches(query).first)
        XCTAssertEqual(result.id, device.id)
        XCTAssertEqual(result.folder, studio.name)
        XCTAssertEqual(result.computer.endpoint.port, 5910)
        XCTAssertEqual(result.sshPort, 2200)
        XCTAssertFalse(result.offersHighPerformance)
        XCTAssertTrue(directory.devicesInSelectedFolder(matching: query).isEmpty)

        directory.selectFolder(studio.id)
        XCTAssertEqual(directory.devicesInSelectedFolder(matching: query).map(\.id), [device.id])
        directory.renameFolder(studio.id, to: "Office")
        XCTAssertTrue(directory.devicesInSelectedFolder(matching: query).isEmpty)
        let renamedQuery = LibrarySearchQuery("OFFICE 5910")
        XCTAssertEqual(directory.devicesInSelectedFolder(matching: renamedQuery).map(\.id), [device.id])

        directory.setHidden(true, device: device)
        XCTAssertTrue(directory.searchMatches(renamedQuery).isEmpty)
        XCTAssertTrue(directory.devicesInSelectedFolder(matching: renamedQuery).isEmpty)
    }

    @MainActor func testDiscoveredProfilesUseAdvertisedAddressesAtTheConfiguredDesktopPort() async throws {
        let domain = "TelescopeTailnetProfiles." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let root = FileManager.default.temporaryDirectory.appending(path: domain, directoryHint: .isDirectory)
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        let service = DirectoryFixture()
        await service.changeListing(to: #"""
        {"devices":[
          {"id":"studio","hostname":"Studio","name":"studio.lab.ts.net.","addresses":["100.64.70.1","fd7a:115c:a1e0::9","not-a-node"],"os":"macOS"}
        ]}
        """#)
        let directory = TailnetDirectory(defaults: defaults, localAddresses: []) { try await service.reply(to: $0) }
        try await directory.link(TailnetAccount(tailnet: "fixture.example", clientID: "fixture"),
                                 secret: "fixture-only", remember: false)
        let device = try XCTUnwrap(directory.visibleDevices.first)
        try directory.setPorts(TailnetDevicePorts(vnc: "5917", ssh: "2207"),
                               for: try XCTUnwrap(directory.directoryID(for: device)))

        let match = try XCTUnwrap(directory.searchMatches(LibrarySearchQuery("[fd7a:115c:a1e0::9]:5917")).first)
        XCTAssertEqual(match.computer.endpoint, try Endpoint(address: "100.64.70.1:5917"))
        XCTAssertEqual(match.advertisedEndpoints, Set(try [
            "100.64.70.1:5917", "[fd7a:115c:a1e0::9]:5917", "studio.lab.ts.net:5917", "studio.lab.ts.net.:5917",
        ].map { try Endpoint(address: $0) }))
        XCTAssertTrue(directory.searchMatches(LibrarySearchQuery("[fd7a:115c:a1e0::9]:5900")).isEmpty)

        let library = ConnectionLibrary(file: root.appending(path: "library.json"))
        var magicDNS = Computer(name: "Support", endpoint: try Endpoint(address: "studio.lab.ts.net:5917"))
        magicDNS.username = "support"
        magicDNS.ssh = SSHSettings(port: 2231, username: "jump", server: "jump.fixture.invalid")
        let ipv6 = Computer(name: "Operator", endpoint: try Endpoint(address: "[fd7a:115c:a1e0:0:0:0:0:9]:5917"))
        let otherPort = Computer(name: "Other server", endpoint: try Endpoint(address: "studio.lab.ts.net:5901"))
        let shortName = Computer(name: "Another Studio", endpoint: try Endpoint(address: "studio:5917"))
        for profile in [magicDNS, ipv6, otherPort, shortName] { XCTAssertTrue(library.save(profile)) }

        let request = EditorRequest.connectingToDiscovered(match.computer, in: library, suggestedSSHPort: match.sshPort,
                                                           quality: .standard, resolvedAddresses: match.advertisedEndpoints)
        XCTAssertFalse(request.loadsStoredCredentials)
        let chooser = try XCTUnwrap(request.discoveredSelection)
        XCTAssertEqual(Set(chooser.profiles(in: library).map(\.id)), [magicDNS.id, ipv6.id])
        let selected = try XCTUnwrap(chooser.editor(selecting: magicDNS, in: library))
        XCTAssertEqual(selected.computer?.id, magicDNS.id)
        XCTAssertEqual(selected.computer?.endpoint, magicDNS.endpoint)
        XCTAssertEqual(selected.computer?.username, magicDNS.username)
        XCTAssertEqual(selected.computer?.ssh, magicDNS.ssh)
        XCTAssertTrue(selected.loadsStoredCredentials)
        let manual = try XCTUnwrap(chooser.editor(selecting: nil, in: library))
        XCTAssertEqual(manual.computer?.endpoint, match.computer.endpoint)
        XCTAssertEqual(manual.suggestedSSHPort, 2207)
        XCTAssertFalse(manual.loadsStoredCredentials)

        let save = DiscoveredProfileSelection(computer: match.computer, suggestedSSHPort: match.sshPort, intent: .save,
                                              resolvedAddresses: match.advertisedEndpoints).request(in: library)
        let saveChooser = try XCTUnwrap(save.discoveredSelection)
        let edit = try XCTUnwrap(saveChooser.editor(selecting: ipv6, in: library))
        XCTAssertEqual(edit.purpose, .edit)
        XCTAssertEqual(edit.computer?.id, ipv6.id)
        XCTAssertEqual(edit.computer?.endpoint, ipv6.endpoint)
    }

    func testAccountRejectsPathInjectionAndEscapesFormFields() throws {
        for invalid in ["", ".", "..", "example/other", "x?bearer", "//example", "two words"] {
            XCTAssertThrowsError(try TailnetAccount(tailnet: invalid, clientID: "id"))
        }
        let account = try TailnetAccount(tailnet: "fixture.example", clientID: "fixture")
        let request = try account.tokenRequest(secret: "generated+a&b=c")
        XCTAssertEqual(request.url?.absoluteString, "https://api.tailscale.com/api/v2/oauth/token")
        XCTAssertEqual(request.httpMethod, "POST")
        let value = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(value.contains("client_secret=generated%2Ba%26b%3Dc"))
        XCTAssertTrue(value.contains("scope=devices%3Acore%3Aread"))
    }

    func testPastedOAuthSecretNeedsNoClientIDAndRequestsOnlyDeviceReadAccess() throws {
        for invalid in ["", "tskey-client-", "tskey-api-fixture", "tskey-auth-fixture", "tskey-client-key part"] {
            XCTAssertNil(TailnetAccount.oauthSecret(from: invalid))
        }
        let proof = try XCTUnwrap(TailnetAccount.oauthSecret(from: "  tskey-client-fixture-id-proof\n"))
        let account = try TailnetAccount(tailnet: " fixture.example\n")
        let request = try account.tokenRequest(secret: proof)
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertEqual(body, "grant_type=client_credentials&client_id=telescope&client_secret=tskey-client-fixture-id-proof&scope=devices%3Acore%3Aread")
        XCTAssertEqual(account.devicesURL.path, "/api/v2/tailnet/fixture.example/devices")
    }

    @MainActor func testReadOnlyAccountListsAuthorizedDevicesWithoutPersistingTheLogin() async throws {
        let domain = "DeskLinkTailnetTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let service = DirectoryFixture()
        let directory = TailnetDirectory(defaults: defaults) { try await service.reply(to: $0) }
        let account = try TailnetAccount(tailnet: "fixture.example")
        let proof = try XCTUnwrap(TailnetAccount.oauthSecret(from: "tskey-client-fixture-id-proof"))
        try await directory.link(account, secret: proof, remember: false)
        XCTAssertEqual(directory.devices.map(\.id), ["a"])
        XCTAssertEqual(directory.devices.first?.computer?.endpoint.address, "[fd7a:115c:a1e0::1]")
        let methods = await service.methods
        XCTAssertEqual(methods, ["POST", "GET"])
        XCTAssertNil(defaults.data(forKey: "tailnet.account"))
        XCTAssertTrue(directory.widgetComputers.isEmpty)
        XCTAssertFalse(directory.loading)
        await directory.refresh()
        XCTAssertNil(directory.error)
        XCTAssertEqual(directory.devices.map(\.id), ["a"])
        try directory.unlink()
        XCTAssertNil(directory.account)
        XCTAssertTrue(directory.devices.isEmpty)
    }

    @MainActor func testLocalNodeIsExcludedFromDirectorySearchAndWidgets() async throws {
        let domain = "TelescopeTailnetLocalNode." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let service = DirectoryFixture()
        await service.changeListing(to: #"""
        {"devices":[
          {"id":"local","hostname":"Notebook","name":"local.fixture","addresses":["100.64.1.42","FD7A:115C:A1E0:0:0:0:0:42"],"os":"macOS"},
          {"id":"peer","hostname":"Notebook","name":"peer.fixture","addresses":["100.64.1.42","fd7a:115c:a1e0::43"],"os":"macOS"},
          {"id":"v6","hostname":"IPv6 only","name":"v6.fixture","addresses":["FD7A:115C:A1E0:0:0:0:0:42"],"os":"macOS"},
          {"id":"named","hostname":"Name only","name":"remote.fixture","addresses":[],"os":"linux"},
          {"id":"mobile","hostname":"Tablet","name":"tablet.fixture","addresses":["100.64.1.43"],"os":"iOS"}
        ]}
        """#)
        let directory = TailnetDirectory(defaults: defaults, localAddresses: ["100.64.1.42", "fd7a:115c:a1e0::42"]) {
            try await service.reply(to: $0)
        }
        let account = try TailnetAccount(tailnet: "fixture.example", clientID: "local-" + UUID().uuidString)
        defer {
            try? directory.unlink()
            defaults.removePersistentDomain(forName: domain)
        }
        try await directory.link(account, secret: "test-only-local-node-credential", remember: true)
        XCTAssertEqual(Set(directory.visibleDevices.map(\.id)), ["peer", "named"])
        let results = directory.searchMatches(LibrarySearchQuery("Notebook"))
        XCTAssertEqual(results.map(\.id), ["peer"])
        XCTAssertEqual(results.first?.offersHighPerformance, true)
        XCTAssertEqual(Set(directory.widgetComputers.map(\.name)), ["Notebook", "Name only"])
        let reopened = TailnetDirectory(defaults: defaults)
        XCTAssertFalse(reopened.needsWidgetDirectoryRefresh)
        XCTAssertEqual(directory.widgetComputers, reopened.widgetComputers)
        let linuxID = try XCTUnwrap(reopened.widgetComputers.first { $0.name == "Name only" }?.id)
        XCTAssertEqual(reopened.computerForWidget(linuxID)?.hardwareKeyboardMode, .unicode)
    }

    @MainActor func testDesktopPlatformsReachSearchAndTheConnectionEditor() async throws {
        let domain = "TelescopeTailnetDesktopPlatforms." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let account = try TailnetAccount(tailnet: "fixture.example", clientID: UUID().uuidString)
        let service = DirectoryFixture()
        let directory = TailnetDirectory(defaults: defaults, localAddresses: ["100.64.7.11"]) {
            try await service.reply(to: $0)
        }
        defer { defaults.removePersistentDomain(forName: domain) }
        await service.changeListing(to: #"""
        {"devices":[
          {"id":"local","hostname":"Local","name":"local.fixture","addresses":["100.64.7.11"],"os":"macOS"},
          {"id":"mobile","hostname":"Mobile","name":"mobile.fixture","addresses":["100.64.7.12"],"os":"  iOS "},
          {"id":"android","hostname":"Tablet","name":"tablet.fixture","addresses":["100.64.7.13"],"os":"android"},
          {"id":"tv","hostname":"TV","name":"tv.fixture","addresses":["100.64.7.14"],"os":"tvOS"},
          {"id":"mac","hostname":"Desk","name":"desk.fixture","addresses":["100.64.7.15"],"os":"Darwin"},
          {"id":"windows","hostname":"Studio","name":"studio.fixture","addresses":["100.64.7.16"],"os":"Windows"},
          {"id":"linux","hostname":"Build","name":"build.fixture","addresses":["100.64.7.17"],"os":"Linux"},
          {"id":"pi","hostname":"Lab","name":"lab.fixture","addresses":["100.64.7.18"],"os":"Raspbian"},
          {"id":"legacy","hostname":"Legacy","name":"legacy.fixture","addresses":["100.64.7.19"]},
          {"id":"bsd","hostname":"BSD","name":"bsd.fixture","addresses":["100.64.7.20"],"os":"freebsd"}
        ]}
        """#)
        try await directory.link(account, secret: "fixture-only", remember: false)
        XCTAssertEqual(Set(directory.visibleDevices.map(\.id)), ["mac", "windows", "linux", "pi", "legacy", "bsd"])
        XCTAssertTrue(directory.searchMatches(LibrarySearchQuery("100.64.7.12")).isEmpty)

        let windows = try XCTUnwrap(directory.searchMatches(LibrarySearchQuery("windows 7.16")).first)
        XCTAssertEqual(windows.system.details(address: windows.computer.endpoint.address), "100.64.7.16 · Windows")
        XCTAssertFalse(windows.offersHighPerformance)
        XCTAssertEqual(windows.computer.authentication, .automatic)
        XCTAssertEqual(windows.computer.hardwareKeyboardMode, .unicode)
        XCTAssertEqual(windows.computer.desktopPlatform, .windows)
        XCTAssertFalse(windows.computer.offersAppleDisplayOptions)
        XCTAssertEqual(windows.computer.connecting(with: .adaptive, on: .current).display(for: .current).quality, .standard)
        let mac = try XCTUnwrap(directory.searchMatches(LibrarySearchQuery("macos")).first)
        XCTAssertTrue(mac.offersHighPerformance)
        XCTAssertEqual(mac.computer.hardwareKeyboardMode, .keystrokes)
        let pi = try XCTUnwrap(directory.searchMatches(LibrarySearchQuery("Raspberry Pi")).first)
        XCTAssertEqual(pi.computer.screensOperatingSystem, 5)
        XCTAssertEqual(pi.computer.hardwareKeyboardMode, .unicode)
        XCTAssertFalse(try XCTUnwrap(directory.searchMatches(LibrarySearchQuery("BSD")).first).offersHighPerformance)
        XCTAssertTrue(try XCTUnwrap(directory.searchMatches(LibrarySearchQuery("Legacy")).first).offersHighPerformance)

        let root = FileManager.default.temporaryDirectory.appending(path: domain, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ConnectionLibrary(file: root.appending(path: "library.json"))
        let editor = EditorRequest.connectingToDiscovered(windows.computer, in: library, suggestedSSHPort: nil, quality: nil)
        XCTAssertEqual(editor.computer?.hardwareKeyboardMode, .unicode)
        XCTAssertEqual(editor.platform(for: windows.computer.endpoint), .windows)
        XCTAssertEqual(editor.platform(for: try Endpoint(address: "100.64.7.16:5901")), .windows)
        XCTAssertNil(editor.platform(for: try Endpoint(address: "another.fixture.invalid")))
        var profile = Computer(name: "My Studio", endpoint: windows.computer.endpoint)
        profile.hardwareKeyboardMode = .legacy
        profile.setDisplay(.init(quality: .adaptive, layout: .virtualPair, matchWindow: true, fixedDesktop: .standard),
                           for: .current)
        XCTAssertTrue(library.save(profile))
        let savedEditor = EditorRequest.connectingToDiscovered(windows.computer, in: library, suggestedSSHPort: nil, quality: nil)
        XCTAssertEqual(savedEditor.computer?.id, profile.id)
        XCTAssertEqual(savedEditor.computer?.hardwareKeyboardMode, .legacy)
        let resolvedProfile = try XCTUnwrap(savedEditor.computer)
        let display = resolvedProfile.display(for: .current)
        XCTAssertEqual(display.quality, .standard)
        XCTAssertEqual(display.layout, .single)
        XCTAssertFalse(display.matchWindow)
        XCTAssertNil(display.fixedDesktop)
        let configuration = resolvedProfile.configuration(preferences: defaults)
        XCTAssertEqual(configuration.videoQualityMode, .standard)
        XCTAssertFalse(configuration.usesMacHardwareKeyPositions)
        XCTAssertNil(library.archive.computers.first?.desktopPlatform)
        XCTAssertEqual(library.archive.computers.first?.display(for: .current).quality, .adaptive)
        library.recordSuccess(resolvedProfile)
        XCTAssertNil(library.archive.computers.first?.desktopPlatform)
        XCTAssertTrue(library.save(resolvedProfile))
        let restored = try XCTUnwrap(ConnectionLibrary(file: root.appending(path: "library.json")).archive.computers.first)
        XCTAssertEqual(restored.desktopPlatform, .windows)
        XCTAssertEqual(restored.hardwareKeyboardMode, .legacy)
    }

    @MainActor func testOlderWidgetDirectoryKeepsAccountAndWaitsForRefreshedTargets() async throws {
        let domain = "TelescopeTailnetOlderWidgetCache." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let account = try TailnetAccount(tailnet: "fixture.invalid", clientID: "fixture")
        let mobile = ComputerEntity(id: UUID(), name: "Mobile", address: "100.64.7.12")
        struct OldCache: Encodable {
            let account: TailnetAccount
            let computers: [ComputerEntity]
        }
        defaults.set(try JSONEncoder().encode(OldCache(account: account, computers: [mobile])), forKey: "tailnet.account")
        let directory = TailnetDirectory(defaults: defaults)
        XCTAssertEqual(directory.account, account)
        XCTAssertTrue(directory.needsWidgetDirectoryRefresh)
        XCTAssertTrue(directory.widgetComputers.isEmpty)
        XCTAssertNil(directory.computerForWidget(mobile.id))
    }

    @MainActor func testRefreshKeepsExistingDevicesWhenAuthorizationIsRevoked() async throws {
        let domain = "TelescopeTailnetRefresh." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let service = DirectoryFixture()
        let directory = TailnetDirectory(defaults: defaults, localAddresses: []) { try await service.reply(to: $0) }
        let account = try TailnetAccount(tailnet: "fixture.example", clientID: "fixture")
        try await directory.link(account, secret: "generated-credential", remember: false)

        await service.changeListingStatus(to: 403)
        await directory.refresh()
        XCTAssertFalse(directory.loading)
        XCTAssertNotNil(directory.error)
        XCTAssertEqual(directory.devices.map(\.id), ["a"])

        await service.changeListingStatus(to: 200)
        await directory.refresh()
        XCTAssertNil(directory.error)
        XCTAssertEqual(directory.devices.map(\.id), ["a"])
    }

    @MainActor func testRememberedDirectoryUpdatesWidgetTargetsAcrossRenameHidingAndRevocation() async throws {
        let domain = "TelescopeTailnetWidget." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let account = try TailnetAccount(tailnet: "fixture.example", clientID: UUID().uuidString)
        // Existing installations retain the linked account before the first directory refresh.
        defaults.set(try JSONEncoder().encode(account), forKey: "tailnet.account")
        let service = DirectoryFixture()
        let directory = TailnetDirectory(defaults: defaults) { try await service.reply(to: $0) }
        defer { try? directory.unlink() }
        XCTAssertEqual(directory.account, account)
        XCTAssertTrue(directory.widgetComputers.isEmpty)
        try await directory.link(account, secret: "test-only-widget-credential", remember: true)
        let desk = try XCTUnwrap(directory.widgetComputers.first)
        XCTAssertEqual(directory.widgetComputers.count, 1)
        let link = try ConnectionRoute(url: ConnectionRoute.savedURL(desk.id))
        XCTAssertEqual(link, .saved(desk.id))
        XCTAssertEqual(TailnetDirectory(defaults: defaults).computerForWidget(desk.id)?.endpoint.address, "[fd7a:115c:a1e0::1]")
        let storage = try XCTUnwrap(defaults.data(forKey: "tailnet.account"))
        XCTAssertFalse(String(decoding: storage, as: UTF8.self).contains("test-only-widget-credential"))

        let original = try XCTUnwrap(directory.visibleDevices.first)
        directory.setHidden(true, device: original)
        XCTAssertTrue(directory.visibleDevices.isEmpty)
        XCTAssertEqual(directory.hiddenDevices.map(\.id), [original.id])
        XCTAssertNil(directory.computerForWidget(desk.id))
        XCTAssertNil(TailnetDirectory(defaults: defaults).computerForWidget(desk.id))

        await service.changeListing(to: #"{"devices":[{"id":"a","hostname":"Office","name":"office.fixture","addresses":["100.64.0.22"],"os":"linux","authorized":true}]}"#)
        await directory.refresh()
        XCTAssertTrue(directory.visibleDevices.isEmpty)
        let renamed = try XCTUnwrap(directory.hiddenDevices.first)
        XCTAssertEqual(renamed.hostname, "Office")
        XCTAssertTrue(directory.widgetComputers.isEmpty)
        XCTAssertTrue(TailnetDirectory(defaults: defaults).widgetComputers.isEmpty)

        directory.setHidden(false, device: renamed)
        XCTAssertEqual(directory.visibleDevices.map(\.hostname), ["Office"])
        XCTAssertTrue(directory.hiddenDevices.isEmpty)
        XCTAssertEqual(directory.widgetComputers.map(\.id), [desk.id])
        let reopened = TailnetDirectory(defaults: defaults) { try await service.reply(to: $0) }
        XCTAssertEqual(reopened.account, account)
        await reopened.refresh()
        XCTAssertNil(reopened.error)
        XCTAssertEqual(reopened.visibleDevices.map(\.hostname), ["Office"])
        let resolved = try XCTUnwrap(reopened.computerForWidget(desk.id))
        XCTAssertEqual(resolved.displayName, "Office")
        XCTAssertEqual(resolved.endpoint.address, "100.64.0.22")
        XCTAssertFalse(resolved.saved)

        await service.changeListing(to: #"{"devices":[{"id":"a","hostname":"Office","name":"office.fixture","addresses":["100.64.0.22"],"os":"linux","authorized":false}]}"#)
        await directory.refresh()
        XCTAssertTrue(directory.widgetComputers.isEmpty)
        XCTAssertNil(TailnetDirectory(defaults: defaults).computerForWidget(desk.id))
        try directory.unlink()
        XCTAssertNil(TailnetDirectory(defaults: defaults).account)
    }

    @MainActor func testHiddenDeviceFollowsItsTailnetAcrossUnlinkAndNewOAuthClient() async throws {
        let domain = "TelescopeTailnetHidden." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let service = DirectoryFixture()
        let directory = TailnetDirectory(defaults: defaults) { try await service.reply(to: $0) }
        try await directory.link(TailnetAccount(tailnet: "fixture.example", clientID: "first"),
                                 secret: "fixture-only", remember: false)
        directory.setHidden(true, device: try XCTUnwrap(directory.visibleDevices.first))
        try directory.unlink()
        XCTAssertTrue(directory.hiddenDevices.isEmpty)
        try await directory.link(TailnetAccount(tailnet: "other.fixture", clientID: "second"),
                                 secret: "fixture-only", remember: false)
        XCTAssertEqual(directory.visibleDevices.map(\.id), ["a"])
        XCTAssertTrue(directory.hiddenDevices.isEmpty)
        try await directory.link(TailnetAccount(tailnet: "fixture.example", clientID: "third"),
                                 secret: "fixture-only", remember: false)
        XCTAssertTrue(directory.visibleDevices.isEmpty)
        XCTAssertEqual(directory.hiddenDevices.map(\.id), ["a"])
        XCTAssertNil(defaults.data(forKey: "tailnet.account"))
    }

    @MainActor func testFoldersAndSelectionFollowDeviceIdentityWithinTheirTailnet() async throws {
        let domain = "TelescopeTailnetFolders." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let service = DirectoryFixture()
        let account = try TailnetAccount(tailnet: "fixture.example", clientID: "first")
        let directory = TailnetDirectory(defaults: defaults) { try await service.reply(to: $0) }
        try await directory.link(account, secret: "fixture-only", remember: false)
        let device = try XCTUnwrap(directory.visibleDevices.first)
        let id = try XCTUnwrap(directory.directoryID(for: device))
        directory.addFolder("   ")
        XCTAssertTrue(directory.folders.isEmpty)
        directory.addFolder("  Studio  ")
        let studio = try XCTUnwrap(directory.selectedFolder)
        XCTAssertEqual(studio.name, "Studio")
        directory.addFolder("studio")
        XCTAssertEqual(directory.folders, [studio])
        XCTAssertTrue(directory.devicesInSelectedFolder.isEmpty)

        directory.moveDevice(id, to: studio.id)
        XCTAssertEqual(directory.devicesInSelectedFolder.map(\.id), ["a"])
        directory.setHidden(true, device: device)
        XCTAssertTrue(directory.devicesInSelectedFolder.isEmpty)
        directory.setHidden(false, device: device)
        XCTAssertEqual(directory.folderID(for: device), studio.id)
        directory.addFolder("Home")
        XCTAssertEqual(directory.selectedFolder?.name, "Home")
        directory.selectFolder(studio.id)
        directory.renameFolder(studio.id, to: "Archive")
        XCTAssertEqual(directory.selectedFolder?.name, "Archive")

        let reopened = TailnetDirectory(defaults: defaults) { try await service.reply(to: $0) }
        await service.changeListing(to: #"{"devices":[{"id":"a","hostname":"Renamed","name":"renamed.fixture","addresses":["100.64.8.9"],"os":"linux"}]}"#)
        let otherAccount = try TailnetAccount(tailnet: "other.fixture", clientID: "second")
        try await reopened.link(otherAccount, secret: "fixture-only", remember: false)
        XCTAssertTrue(reopened.folders.isEmpty)
        XCTAssertNil(reopened.selectedFolder)
        XCTAssertEqual(reopened.devicesInSelectedFolder.map(\.id), ["a"])
        reopened.addFolder("Other")

        let sameTailnet = try TailnetAccount(tailnet: "fixture.example", clientID: "third")
        try await reopened.link(sameTailnet, secret: "fixture-only", remember: false)
        XCTAssertEqual(reopened.selectedFolder?.id, studio.id)
        XCTAssertEqual(reopened.selectedFolder?.name, "Archive")
        let restored = try XCTUnwrap(reopened.devicesInSelectedFolder.first)
        XCTAssertEqual(restored.hostname, "Renamed")
        XCTAssertEqual(reopened.computer(for: restored)?.endpoint.host, "100.64.8.9")
        reopened.moveDevice(id, to: UUID())
        XCTAssertEqual(reopened.folderID(for: restored), studio.id)
        reopened.removeFolder(studio.id)
        XCTAssertNil(reopened.selectedFolder)
        XCTAssertNil(reopened.folderID(for: restored))
        XCTAssertEqual(reopened.devicesInSelectedFolder.map(\.id), ["a"])

        try await reopened.link(otherAccount, secret: "fixture-only", remember: false)
        XCTAssertEqual(reopened.selectedFolder?.name, "Other")
    }

    func testPortOverridesValidateEachFieldAndTreatBlankAsDefault() throws {
        let ports = try TailnetDevicePorts(vnc: " 65535 ", ssh: "1")
        XCTAssertEqual(ports.vnc, 65535)
        XCTAssertEqual(ports.ssh, 1)
        XCTAssertNil(try TailnetDevicePorts(vnc: "", ssh: "").vnc)
        XCTAssertNil(try TailnetDevicePorts(vnc: "", ssh: " ").ssh)
        for invalid in ["0", "65536", "-22", "22x", "２２"] {
            XCTAssertThrowsError(try TailnetDevicePorts(vnc: invalid, ssh: ""))
            XCTAssertThrowsError(try TailnetDevicePorts(vnc: "", ssh: invalid))
        }
    }

    @MainActor func testDevicePortsPersistWithoutSavingOAuthCredentials() async throws {
        let domain = "TelescopeTailnetSessionPorts." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let service = DirectoryFixture()
        let account = try TailnetAccount(tailnet: "fixture.example", clientID: "fixture")
        let first = TailnetDirectory(defaults: defaults) { try await service.reply(to: $0) }
        try await first.link(account, secret: "fixture-only", remember: false)
        let initial = try XCTUnwrap(first.visibleDevices.first)
        let id = try XCTUnwrap(first.directoryID(for: initial))
        try first.setPorts(TailnetDevicePorts(vnc: "5910", ssh: "2200"), for: id)
        XCTAssertNil(defaults.data(forKey: "tailnet.account"))
        try first.unlink()

        let reopened = TailnetDirectory(defaults: defaults) { try await service.reply(to: $0) }
        try await reopened.link(account, secret: "fixture-only", remember: false)
        XCTAssertEqual(reopened.ports(for: id)?.ssh, 2200)
        XCTAssertEqual(reopened.computer(for: try XCTUnwrap(reopened.visibleDevices.first))?.endpoint.port, 5910)
        try reopened.setPorts(TailnetDevicePorts(vnc: "", ssh: ""), for: id)
        XCTAssertNil(TailnetDirectory(defaults: defaults).ports(for: id))
    }

    @MainActor func testPortsFollowTheDeviceAcrossRefreshAndRelaunchAndUpdateWidgetRoutes() async throws {
        let domain = "TelescopeTailnetPorts." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let service = DirectoryFixture()
        let directory = TailnetDirectory(defaults: defaults) { try await service.reply(to: $0) }
        let account = try TailnetAccount(tailnet: "fixture.example", clientID: UUID().uuidString)
        defer { try? directory.unlink() }
        try await directory.link(account, secret: "test-only-port-credential", remember: true)

        let device = try XCTUnwrap(directory.visibleDevices.first)
        let id = try XCTUnwrap(directory.directoryID(for: device))
        let ports = try TailnetDevicePorts(vnc: "5907", ssh: "2201")
        XCTAssertNil(directory.ports(for: id))
        try directory.setPorts(ports, for: id)
        XCTAssertEqual(directory.computer(for: device)?.endpoint.address, "[fd7a:115c:a1e0::1]:5907")
        XCTAssertNil(directory.computer(for: device)?.ssh)
        XCTAssertEqual(directory.widgetComputers.first?.address, "[fd7a:115c:a1e0::1]:5907")
        XCTAssertEqual(TailnetDirectory(defaults: defaults).ports(for: id)?.ssh, 2201)
        XCTAssertEqual(TailnetDirectory(defaults: defaults).computerForWidget(id)?.endpoint.port, 5907)

        await service.changeListing(to: #"{"devices":[{"id":"a","hostname":"Renamed","name":"renamed.fixture","addresses":["100.64.0.20"],"os":"linux","authorized":true},{"id":"other","hostname":"Another","name":"another.fixture","addresses":["100.64.0.21"],"os":"linux","authorized":true}]}"#)
        await directory.refresh()
        let refreshed = try XCTUnwrap(directory.visibleDevices.first { $0.id == "a" })
        let other = try XCTUnwrap(directory.visibleDevices.first { $0.id == "other" })
        XCTAssertEqual(directory.computer(for: refreshed)?.endpoint.address, "100.64.0.20:5907")
        XCTAssertEqual(directory.computer(for: other)?.endpoint.port, 5900)
        XCTAssertEqual(TailnetDirectory(defaults: defaults).computerForWidget(id)?.displayName, "Renamed")

        try directory.unlink()
        try await directory.link(TailnetAccount(tailnet: "other.fixture", clientID: UUID().uuidString), secret: "fixture-only", remember: false)
        let differentTailnet = try XCTUnwrap(directory.visibleDevices.first { $0.id == "a" })
        XCTAssertEqual(directory.computer(for: differentTailnet)?.endpoint.port, 5900)
        XCTAssertThrowsError(try directory.setPorts(ports, for: id))
        try directory.unlink()
        try await directory.link(account, secret: "test-only-port-credential", remember: true)
        XCTAssertEqual(directory.ports(for: id), ports)

        try directory.setPorts(TailnetDevicePorts(vnc: "", ssh: ""), for: id)
        let reopened = TailnetDirectory(defaults: defaults)
        XCTAssertNil(reopened.ports(for: id))
        XCTAssertEqual(reopened.computerForWidget(id)?.endpoint.port, 5900)
    }
}

private actor DirectoryFixture {
    var methods = [String]()
    var listing = #"{"devices":[{"id":"a","hostname":"Desk","name":"desk.fixture","addresses":["fd7a:115c:a1e0::1"],"os":"linux","authorized":true},{"id":"b","hostname":"Unapproved","name":"other.fixture","addresses":["100.64.1.2"],"os":"linux","authorized":false}]}"#
    private var listingStatus = 200
    func changeListing(to value: String) { listing = value }
    func changeListingStatus(to value: Int) { listingStatus = value }
    func reply(to request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.host, "api.tailscale.com")
        methods.append(request.httpMethod ?? "")
        let body: String
        let status: Int
        switch url.path {
        case "/api/v2/oauth/token":
            body = #"{"access_token":"generated-access","token_type":"Bearer"}"#
            status = 200
        case "/api/v2/tailnet/fixture.example/devices", "/api/v2/tailnet/other.fixture/devices":
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer generated-access")
            body = listing
            status = listingStatus
        default: throw URLError(.badURL)
        }
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
        return (Data(body.utf8), response)
    }
}
