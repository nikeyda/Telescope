import CryptoKit
import XCTest
@testable import DeskLink

final class DesktopLinkTests: XCTestCase {
    func testURLCredentialsAndPortHaveSeparateDestinations() throws {
        let link = try DesktopLink(text: "vnc://editor:p%40ss%3A7@[::1]:5998?observe=true")
        XCTAssertEqual(link.target, .address(try Endpoint(address: "[::1]:5998")))
        XCTAssertEqual(link.username, "editor")
        XCTAssertEqual(link.password, "p@ss:7")
        XCTAssertEqual(link.observe, true)
        XCTAssertNil(link.sshPort)
        let ssh = try DesktopLink(text: "ssh://tunnel@example.invalid:2213?ssh-key=Test%20Key&observe=false")
        XCTAssertEqual(ssh.target, .address(try Endpoint(address: "example.invalid")))
        XCTAssertEqual(ssh.sshPort, 2213)
        XCTAssertEqual(ssh.keyName, "Test Key")
        XCTAssertEqual(ssh.observe, false)
        XCTAssertEqual(try DesktopLink(text: "ssh://[fe80::1%25en0]").target, .address(try Endpoint(address: "[fe80::1%en0]")))
        XCTAssertEqual(try DesktopLink(text: "ssh://host").sshPort, 22)
        XCTAssertNil(try DesktopLink(text: "vnc://host/").observe)
        for scheme in DesktopLink.supportedSchemes {
            let observe = try DesktopLink(text: scheme + "://example.invalid?guest=0&observe=1")
            XCTAssertEqual(observe.observe, true)
            XCTAssertFalse(observe.requestsGuest)
            let guest = try DesktopLink(text: scheme + "://example.invalid?guest=1&observe=0")
            XCTAssertEqual(guest.observe, false)
            XCTAssertTrue(guest.requestsGuest)
        }
    }

    func testScreensSSHLinksUseTheSameTunnelAsSSHLinks() throws {
        let suffix = "://test@[2001:db8::5]:2228?ssh-key=Fixture%20Key&observe=1"
        let expected = try DesktopLink(text: "ssh" + suffix)
        let url = try XCTUnwrap(URL(string: "ScReEnS-SsH" + suffix))
        XCTAssertEqual(try ConnectionRoute(url: url), .desktopLink(expected))
        let request = try EditorRequest.from(DesktopLink(text: url.absoluteString), in: LibraryArchive(), allowUnsavedHost: true)
        XCTAssertEqual(request.initialSSHPort, 2228)
        XCTAssertEqual(request.link?.keyName, "Fixture Key")
        XCTAssertEqual(request.link?.observe, true)
        XCTAssertThrowsError(try DesktopLink(text: "screens-ssh://test.invalid:bad"))
    }

    func testNamedLinksResolveOnlyAnUnambiguousSavedComputer() throws {
        let endpoint = try Endpoint(address: "studio.local:5905")
        var first = Computer(name: "剪辑 Mac", endpoint: endpoint)
        first.username = "first"
        var second = Computer(name: first.name, endpoint: try Endpoint(address: "spare.local"))
        second.username = "second"
        var recent = Computer(name: first.name, endpoint: endpoint)
        recent.saved = false
        let archive = LibraryArchive(computers: [first, recent, second])
        let named = try DesktopLink(text: "screens://second:example@剪辑%20Mac?observe=true")
        XCTAssertEqual(try EditorRequest.from(named, in: archive, allowUnsavedHost: false).computer?.id, second.id)
        XCTAssertThrowsError(try EditorRequest.from(DesktopLink(text: "screens://剪辑 Mac"), in: archive, allowUnsavedHost: false))
        let direct = try DesktopLink(text: "screens://studio.local:5905")
        XCTAssertEqual(try EditorRequest.from(direct, in: archive, allowUnsavedHost: false).computer?.id, first.id)
        let unknown = try DesktopLink(text: "screens://unknown.local")
        XCTAssertThrowsError(try EditorRequest.from(unknown, in: archive, allowUnsavedHost: false))
        XCTAssertEqual(try EditorRequest.from(unknown, in: archive, allowUnsavedHost: true).initialAddress, "unknown.local")
        let guest = try DesktopLink(text: "vnc://my-mac.local?guest=true")
        XCTAssertTrue(guest.requestsGuest)
        XCTAssertThrowsError(try EditorRequest.from(guest, in: archive, allowUnsavedHost: true))
    }

    func testSavedHostnameLinksKeepTheConfiguredPortAndRoute() throws {
        let endpoints = ["render.local:5915", "192.0.2.10:5915", "[2001:db8::5]:5915", "rendershort:5915"]
        for address in endpoints {
            let endpoint = try Endpoint(address: address)
            let authority = endpoint.host.contains(":") ? "[\(endpoint.host)]" : endpoint.host
            var saved = Computer(name: "Render station", endpoint: endpoint)
            saved.ssh = SSHSettings(port: 2250, username: "jump", server: "relay.invalid")
            var recent = Computer(endpoint: try Endpoint(address: authority))
            recent.saved = false
            let archive = LibraryArchive(computers: [recent, saved])
            let link = try DesktopLink(text: "screens://\(authority)?observe=1")
            let request = try EditorRequest.from(link, in: archive, allowUnsavedHost: false)
            XCTAssertEqual(request.computer?.id, saved.id)
            XCTAssertEqual(request.computer?.endpoint, endpoint)
            XCTAssertEqual(request.computer?.ssh, saved.ssh)
            XCTAssertEqual(request.link?.observe, true)
        }
    }

    func testSavedHostRequiresAUniqueProfileAndHonorsAnExplicitPort() throws {
        let host = "studio.local"
        var editor = Computer(name: "Editor", endpoint: try Endpoint(address: host + ":5915"))
        editor.username = "editor"
        var reader = Computer(name: "Reader", endpoint: try Endpoint(address: host))
        reader.username = "reader"
        let decoy = Computer(name: host, endpoint: try Endpoint(address: "other.invalid"))
        let portDecoy = Computer(name: host + ":5915", endpoint: decoy.endpoint)
        let alias = Computer(name: "Backup.Mac", endpoint: try Endpoint(address: "backup.invalid"))
        let archive = LibraryArchive(computers: [decoy, portDecoy, editor, reader, alias])
        let ambiguous = try DesktopLink(text: "screens://\(host)")
        XCTAssertThrowsError(try EditorRequest.from(ambiguous, in: archive, allowUnsavedHost: false)) { error in
            guard case .ambiguousName? = error as? EditorRequest.LinkError else { return XCTFail("Expected an ambiguous host") }
        }
        for (url, id) in [("screens://editor@\(host)", editor.id), ("screens://\(host):5900", reader.id),
                          ("screens://\(host):5915", editor.id), ("screens://Editor", editor.id),
                          ("screens://Backup.Mac", alias.id)] {
            let request = try EditorRequest.from(DesktopLink(text: url), in: archive, allowUnsavedHost: false)
            XCTAssertEqual(request.computer?.id, id)
        }
        let onlyEditor = LibraryArchive(computers: [editor])
        let explicit = try DesktopLink(text: "screens://\(host):5900")
        XCTAssertThrowsError(try EditorRequest.from(explicit, in: onlyEditor, allowUnsavedHost: false))
        let unsaved = try EditorRequest.from(explicit, in: onlyEditor, allowUnsavedHost: true)
        XCTAssertNil(unsaved.computer)
        XCTAssertEqual(unsaved.initialAddress, host)
    }

    func testMalformedLinksCannotBecomeAnOrdinaryConnection() {
        for invalid in ["ssh://host:0", "ssh://host:65536", "vnc://a@b@host", "vnc://host/path",
                        "vnc://host?Observe=true", "vnc://host?observe=yes", "vnc://host?guest=true&guest=false",
                        "vnc://host?ssh-key=some", "ssh://host?ssh-key=", "vnc://host?observe", "vnc://host#anything",
                        "vnc://name%0A:password@host", "vnc://vnc%3A%2F%2Fhost", "ssh://host:", "screens://"] {
            XCTAssertThrowsError(try DesktopLink(text: invalid))
        }
    }

    func testVNCLinkWithASavedDisplayNameUsesTheMacLibrary() throws {
        let url = try XCTUnwrap(URL(string: "vnc://John%27s%20Studio%20Mac?observe=true"))
        #if targetEnvironment(macCatalyst)
        guard case .desktopLink(let link) = try ConnectionRoute(url: url) else { return XCTFail("Expected a desktop link") }
        let computer = Computer(name: "John's Studio Mac", endpoint: try Endpoint(address: "studio.local:5915"))
        var duplicate = computer
        duplicate.id = UUID()
        let archive = LibraryArchive(computers: [computer])
        let request = try EditorRequest.from(link, in: archive, allowUnsavedHost: true)
        XCTAssertEqual(request.computer?.id, computer.id)
        XCTAssertEqual(request.computer?.endpoint.port, 5915)
        XCTAssertEqual(request.link?.observe, true)
        XCTAssertThrowsError(try EditorRequest.from(link, in: LibraryArchive(), allowUnsavedHost: true))
        XCTAssertThrowsError(try EditorRequest.from(link, in: LibraryArchive(computers: [computer, duplicate]), allowUnsavedHost: true))
        #else
        XCTAssertThrowsError(try ConnectionRoute(url: url))
        #endif
        XCTAssertThrowsError(try DesktopLink(text: "vnc://studio.local:bad%20port"))
    }

    func testNamedKeyRetainsExactCaseAndArchiveContainsOnlyItsName() throws {
        let name = "DeskLink fixture " + UUID().uuidString
        let key = P256.Signing.PrivateKey().pemRepresentation
        try PasswordStore.addNamedKey(key, name: name, synchronize: false)
        defer { try? PasswordStore.removeNamedKey(name, synchronize: false) }
        XCTAssertTrue(try PasswordStore.keyNames(synchronize: false).contains(name))
        XCTAssertTrue(try PasswordStore.namedKey(name, synchronize: false) == key)
        XCTAssertTrue(try PasswordStore.namedKey(name.lowercased(), synchronize: false) == nil)
        XCTAssertThrowsError(try PasswordStore.addNamedKey(key, name: name, synchronize: false))
        var computer = Computer(endpoint: try Endpoint(address: "test.invalid"))
        computer.ssh = SSHSettings(username: "fixture", usesKey: true, keyName: name)
        let encoded = try LibraryArchive(computers: [computer]).encoded()
        XCTAssertNil(encoded.range(of: Data("PRIVATE KEY".utf8)))
        XCTAssertEqual(try LibraryArchive.read(encoded).computers.first?.ssh?.keyName, name)
        let oldSettings = Data(#"{"port":22,"username":"legacy","usesKey":true}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(SSHSettings.self, from: oldSettings).keyName)
        try PasswordStore.removeNamedKey(name, synchronize: false)
        XCTAssertTrue(try PasswordStore.namedKey(name, synchronize: false) == nil)
    }

    func testVNCAddressesAndShortNamesUseTheExpectedConnection() throws {
        let computer = Computer(name: "Studio", endpoint: try Endpoint(address: "editing.local:5915"))
        let decoy = Computer(name: "editing.local:5915", endpoint: try Endpoint(address: "other.invalid"))
        let archive = LibraryArchive(computers: [decoy, computer])
        let shortLink = try DesktopLink(text: "vnc://Studio?observe=true")
        let exact = try DesktopLink(text: "vnc://editing.local:5915")
        let ssh = try DesktopLink(text: "ssh://Studio:2222")
        let tunneled = try EditorRequest.from(ssh, in: archive, allowUnsavedHost: true)
        XCTAssertNil(tunneled.computer)
        XCTAssertEqual(tunneled.initialSSHPort, 2222)
        #if targetEnvironment(macCatalyst)
        for link in [shortLink, try DesktopLink(text: "screens://Studio"), exact] {
            XCTAssertEqual(try EditorRequest.from(link, in: archive, allowUnsavedHost: true).computer?.id, computer.id)
        }
        let missing = try EditorRequest.from(shortLink, in: LibraryArchive(), allowUnsavedHost: true)
        XCTAssertEqual(missing.initialAddress, "studio")
        let explicit = try DesktopLink(text: "vnc://Studio:5900")
        let explicitRequest = try EditorRequest.from(explicit, in: archive, allowUnsavedHost: true)
        XCTAssertNil(explicitRequest.computer)
        XCTAssertEqual(explicitRequest.initialAddress, "studio")
        #else
        for link in [shortLink, exact] {
            let request = try EditorRequest.from(link, in: archive, allowUnsavedHost: false)
            XCTAssertNil(request.computer)
            XCTAssertFalse(request.initialAddress.isEmpty)
        }
        #endif
    }
}
