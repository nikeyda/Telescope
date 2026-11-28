import XCTest
#if !targetEnvironment(macCatalyst)
import UIKit
#endif

@MainActor
final class LibraryUITests: XCTestCase {
    #if !targetEnvironment(macCatalyst)
    func testNearbyBadgeCanBeHiddenIndependentlyOfDeviceDiscovery() async throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "The Nearby count is an iPhone sidebar feature.")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let row = app.descendants(matching: .any).matching(identifier: "library.nearby").firstMatch

        func waitFor(_ test: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
            let deadline = ContinuousClock.now + .seconds(12)
            while !test() {
                if ContinuousClock.now >= deadline {
                    XCTFail("Nearby sidebar did not reach the expected state. Value: \(String(describing: row.value))", file: file, line: line)
                    return
                }
                try await Task.sleep(for: .milliseconds(120))
            }
        }

        func acceptDiscoveryPermission() {
            let prompt = springboard.alerts.containing(
                NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS %@", "local network", "本地网络")
            ).firstMatch
            if prompt.waitForExistence(timeout: 3) {
                let allow = prompt.buttons.matching(NSPredicate(format: "label IN %@", ["Allow", "允许"])).firstMatch
                if allow.exists { allow.tap() }
            }
        }

        func showSidebar() {
            if row.isHittable { return }
            let button = app.buttons["ToggleSideBar"].firstMatch
            if button.isHittable {
                button.tap()
            } else {
                app.buttons["BackButton"].firstMatch.tap()
            }
            XCTAssertTrue(row.waitForExistence(timeout: 8))
            XCTAssertTrue(row.isHittable)
        }

        func setCountVisible(_ visible: Bool) {
            let more = app.buttons["library.more"].firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: 8))
            more.tap()
            app.buttons["设置"].firstMatch.tap()
            let sidebar = app.buttons["preferences.sidebar"].firstMatch
            XCTAssertTrue(sidebar.waitForExistence(timeout: 8))
            sidebar.tap()
            let toggle = app.switches["preferences.sidebar.nearbyCount"].firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            let target = visible ? "1" : "0"
            if toggle.value as? String != target {
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
            }
            XCTAssertEqual(toggle.value as? String, target)
            let close = app.buttons["关闭"].firstMatch
            if !close.isHittable { app.navigationBars.buttons["设置"].firstMatch.tap() }
            close.tap()
        }

        func capture(_ name: String) {
            let picture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            picture.name = name
            picture.lifetime = .keepAlways
            add(picture)
        }

        func displayedCount() -> Int {
            guard let value = row.value else { return 0 }
            return Int(String(describing: value)) ?? 0
        }

        app.launch()
        acceptDiscoveryPermission()
        showSidebar()
        row.tap()
        XCTAssertTrue(app.navigationBars["附近"].waitForExistence(timeout: 8))
        let discovered = app.scrollViews.firstMatch.buttons.firstMatch
        try XCTSkipUnless(discovered.waitForExistence(timeout: 10), "Advertise a Bonjour screen-sharing service to run this UI integration test.")
        let device = app.buttons[discovered.label].firstMatch
        showSidebar()
        try await waitFor { displayedCount() > 0 }
        let advertised = displayedCount()
        capture("Nearby device badge")

        row.tap()
        setCountVisible(false)
        showSidebar()
        XCTAssertEqual(displayedCount(), 0)
        capture("Nearby badge hidden")
        row.tap()
        XCTAssertTrue(device.waitForExistence(timeout: 8))

        app.terminate()
        app.launch()
        showSidebar()
        XCTAssertEqual(displayedCount(), 0)
        row.tap()
        XCTAssertTrue(device.waitForExistence(timeout: 8))
        setCountVisible(true)
        showSidebar()
        try await waitFor { displayedCount() > 0 }
        let receipt = XCTAttachment(string: "Before hiding: \(advertised)\nHidden after relaunch: 0\nAfter restoring: \(displayedCount())")
        receipt.name = "Nearby count observations"
        receipt.lifetime = .keepAlways
        add(receipt)
    }

    func testPencilKeyboardActionCanBeAssignedToBothGesturesAndSurvivesRelaunch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString, "-AppleLanguages", "(zh-Hans)"]
        let title = "显示或隐藏键盘"

        func openSettings() {
            let more = app.buttons["library.more"].firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: 10))
            more.tap()
            app.buttons["设置"].firstMatch.tap()
            XCTAssertTrue(app.navigationBars["设置"].firstMatch.waitForExistence(timeout: 8))
        }

        func picker(_ identifier: String) -> XCUIElement {
            let row = app.buttons[identifier].firstMatch
            let form = app.collectionViews.firstMatch
            let top = app.navigationBars["设置"].firstMatch.frame.maxY
            let lower = form.frame.maxY
            for _ in 0..<12 {
                let y = row.exists ? row.frame.midY : CGFloat.infinity
                if y > top + 14, y < lower - 14, row.isHittable { return row }
                let high = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
                let low = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.68))
                if y <= top + 14 {
                    high.press(forDuration: 0.05, thenDragTo: low, withVelocity: .slow, thenHoldForDuration: 0.1)
                } else {
                    low.press(forDuration: 0.05, thenDragTo: high, withVelocity: .slow, thenHoldForDuration: 0.1)
                }
            }
            XCTFail("The picker for \(identifier) never reached the visible part of Settings.")
            return row
        }

        func hasKeyboardAction(_ row: XCUIElement) -> Bool {
            row.label.contains(title) || (row.value as? String) == title
        }

        app.launch()
        openSettings()
        for identifier in ["pencil.doubleTap", "pencil.squeeze"] {
            let row = picker(identifier)
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            let option = app.buttons[title].firstMatch
            if !option.waitForExistence(timeout: 6) {
                let state = XCTAttachment(screenshot: app.screenshot())
                state.name = "Apple Pencil picker before selection"
                state.lifetime = .keepAlways
                add(state)
                XCTFail("The menu for \(identifier) did not open. \(row.debugDescription)")
                return
            }
            option.tap()
            XCTAssertTrue(hasKeyboardAction(row), row.debugDescription)
        }
        app.terminate()
        app.launch()
        openSettings()
        XCTAssertTrue(hasKeyboardAction(picker("pencil.doubleTap")))
        XCTAssertTrue(hasKeyboardAction(picker("pencil.squeeze")))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Apple Pencil keyboard actions"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testSidebarVisibilitySurvivesRelaunchAndCanBeRestored() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        let favorites = app.descendants(matching: .any).matching(identifier: "library.favorites").firstMatch
        let all = app.descendants(matching: .any).matching(identifier: "library.all").firstMatch
        let emptyLibrary = app.buttons["library.empty.new"].firstMatch

        func changeFavoritesVisibility() throws {
            let more = app.buttons["library.more"].firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: 10))
            more.tap()
            app.buttons["设置"].firstMatch.tap()
            let sidebar = app.buttons["preferences.sidebar"].firstMatch
            XCTAssertTrue(sidebar.waitForExistence(timeout: 8))
            sidebar.tap()
            let toggle = app.switches["preferences.sidebar.favorites"].firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            let previousValue = try XCTUnwrap(toggle.value as? String)
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", previousValue),
                                                    object: toggle)
            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "Sidebar preferences"
            attachment.lifetime = .keepAlways
            add(attachment)
            let close = app.buttons["关闭"].firstMatch
            if close.isHittable {
                close.tap()
            } else {
                app.navigationBars.buttons["设置"].firstMatch.tap()
                close.tap()
            }
        }

        XCTAssertTrue(favorites.waitForExistence(timeout: 10))
        favorites.tap()
        XCTAssertTrue(app.buttons["library.empty.all"].firstMatch.waitForExistence(timeout: 5))
        try changeFavoritesVisibility()
        XCTAssertTrue(emptyLibrary.waitForExistence(timeout: 5))
        XCTAssertFalse(favorites.exists)
        XCTAssertTrue(all.exists)

        app.terminate()
        app.launch()
        XCTAssertTrue(all.waitForExistence(timeout: 10))
        XCTAssertFalse(favorites.exists)
        try changeFavoritesVisibility()
        XCTAssertTrue(favorites.waitForExistence(timeout: 5))
        favorites.tap()
        XCTAssertTrue(app.buttons["library.empty.all"].firstMatch.waitForExistence(timeout: 5))
    }
    #endif

    func testEmptyLibraryOpensTheSaveAndQuickConnectionEditors() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString, "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        XCTAssertTrue(app.staticTexts["没有最近连接"].firstMatch.waitForExistence(timeout: 10))
        let recentQuick = app.buttons["library.empty.quick"].firstMatch
        XCTAssertTrue(recentQuick.isHittable)
        recentQuick.tap()
        XCTAssertTrue(app.textFields["connection.host"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["connection.name"].firstMatch.exists)
        app.buttons["取消"].firstMatch.tap()
        selectCollection("library.all", in: app)
        let save = app.buttons["library.empty.new"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["添加第一台电脑"].firstMatch.exists)
        let emptyLibrary = XCTAttachment(screenshot: app.screenshot())
        emptyLibrary.name = "Empty connection library"
        emptyLibrary.lifetime = .keepAlways
        add(emptyLibrary)
        save.tap()
        XCTAssertTrue(app.textFields["connection.name"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["取消"].firstMatch.tap()
        let quick = app.buttons["library.empty.quick"].firstMatch
        XCTAssertTrue(quick.waitForExistence(timeout: 5))
        quick.tap()
        XCTAssertTrue(app.textFields["connection.host"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["connection.name"].firstMatch.exists)
        XCTAssertFalse(app.buttons["connection.submit"].firstMatch.isEnabled)
        app.buttons["取消"].firstMatch.tap()
        selectCollection("library.favorites", in: app)
        XCTAssertTrue(app.staticTexts["还没有收藏的电脑"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["library.empty.all"].firstMatch.tap()
        XCTAssertTrue(save.waitForExistence(timeout: 5))
    }

    func testListShowsTheFolderBesideTheSavedComputer() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        let more = app.buttons["library.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))

        func press(_ element: XCUIElement) {
            #if targetEnvironment(macCatalyst)
            element.click()
            #else
            element.tap()
            #endif
        }
        func choose(_ title: String) {
            press(more)
            let action = app.buttons[title].firstMatch
            if action.exists { press(action) } else { press(app.menuItems[title].firstMatch) }
        }
        selectCollection("library.all", in: app)
        choose("新建文件夹")
        #if targetEnvironment(macCatalyst)
        let folderPrompt = app.sheets["新建文件夹"].firstMatch
        #else
        let folderPrompt = app.alerts["新建文件夹"].firstMatch
        #endif
        let name = folderPrompt.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        press(name)
        name.typeText("QA114-Desk")
        let folder = try XCTUnwrap(name.value as? String)
        XCTAssertFalse(folder.isEmpty)
        let saveFolder = folderPrompt.buttons["保存"].firstMatch
        XCTAssertTrue(saveFolder.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        press(saveFolder)
        XCTAssertTrue(folderPrompt.waitForNonExistence(timeout: 5))
        press(app.buttons["library.new"])
        let host = app.textFields["connection.host"]
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        press(host)
        host.typeText("group-test.invalid")
        press(app.buttons["connection.submit"])
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.computer.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        #if targetEnvironment(macCatalyst)
        press(app.buttons["library.presentation"].firstMatch)
        XCTAssertTrue(app.menuItems["排序"].firstMatch.exists || app.buttons["排序"].firstMatch.exists)
        let layout = app.menuItems["列表"].firstMatch
        press(layout.exists ? layout : app.buttons["列表"].firstMatch)
        #else
        choose("列表")
        #endif
        let folderHeading = app.staticTexts["library.list.folderHeading"].firstMatch
        XCTAssertFalse(folderHeading.exists)
        XCTAssertFalse(row.label.contains(folder))
        press(app.descendants(matching: .any).matching(identifier: "library.all").firstMatch)
        #if targetEnvironment(macCatalyst)
        XCTAssertTrue(folderHeading.waitForExistence(timeout: 5))
        XCTAssertEqual(folderHeading.label, "文件夹")
        XCTAssertTrue(row.buttons["group-test.invalid"].firstMatch.exists)
        let grouped = row.buttons[folder].firstMatch
        XCTAssertTrue(grouped.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(abs(grouped.frame.minX - folderHeading.frame.minX), 2)
        let window = app.windows.containing(.button, identifier: "library.more").firstMatch
        let capture = XCTAttachment(screenshot: window.screenshot())
        #else
        let grouped = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@ AND label CONTAINS %@",
            "library.computer.", "group-test.invalid", folder)).firstMatch
        XCTAssertTrue(grouped.waitForExistence(timeout: 5))
        let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        XCTAssertFalse(folderHeading.exists)
        #endif
        capture.name = "Grouped connection list"
        capture.lifetime = .keepAlways
        add(capture)
    }

    func testCategorySearchMatchesNameAndPortAndClearsForSetup() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString, "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        func press(_ element: XCUIElement) {
            #if targetEnvironment(macCatalyst)
            element.click()
            #else
            element.tap()
            #endif
        }
        XCTAssertTrue(app.buttons["library.quick"].firstMatch.waitForExistence(timeout: 10))
        let id = UUID()
        let file = FileManager.default.temporaryDirectory.appending(path: id.uuidString + ".screens")
        defer { try? FileManager.default.removeItem(at: file) }
        let fixture: [String: Any] = [
            "filename": "Search fixture", "folders": [],
            "screens": [["id": id.uuidString, "name": "Studio Fixture", "hostname": "studio.fixture.invalid",
                         "version": 6, "type": ["saved": [:]], "port": 5916, "clientProtocol": "vnc",
                         "users": [], "authenticationMethod": 2, "operatingSystem": 6, "startInObserveMode": false,
                         "onDisconnectAction": 0, "useSharedClipboard": true, "useSecureConnection": false]]
        ]
        try JSONSerialization.data(withJSONObject: fixture).write(to: file)
        app.open(file)
        let done = app.buttons["完成"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 8))
        press(done)

        let item = app.buttons["library.computer." + id.uuidString].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 8))
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 6))
        press(search)
        search.typeText("5916 Studio")
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        search.typeText(" missing")
        XCTAssertTrue(item.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["未找到匹配的连接"].firstMatch.waitForExistence(timeout: 5))
        let picture = XCTAttachment(screenshot: app.screenshot())
        picture.name = "Collection search has no matches"
        picture.lifetime = .keepAlways
        add(picture)

        #if targetEnvironment(macCatalyst)
        selectCollection("library.remoteAccess", in: app)
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))
        selectCollection("library.all", in: app)
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        #endif
    }

    func testDiscoveryDistinguishesTailscaleSetupFromDirectoryAuthorization() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString, "-AppleLanguages", "(zh-Hans)"]
        app.launch()

        #if targetEnvironment(macCatalyst)
        app.open(URL(string: "desklink:///menu/nearby")!)
        let layout = app.buttons["library.discoveryLayout"].firstMatch
        XCTAssertTrue(layout.waitForExistence(timeout: 8))
        attachLibraryScreenshot(app, name: "Mac Nearby discovery")
        app.open(URL(string: "desklink:///menu/tailscale")!)
        #else
        selectCollection("library.tailscale", in: app)
        #endif

        let link = app.buttons["tailnet.linkAccount"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "tailnet.setup").firstMatch.exists)
        #if targetEnvironment(macCatalyst)
        XCTAssertTrue(app.searchFields.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(layout.waitForNonExistence(timeout: 5))
        #else
        if UIDevice.current.userInterfaceIdiom != .phone {
            XCTAssertTrue(app.searchFields.firstMatch.waitForNonExistence(timeout: 5))
        }
        #endif
        attachLibraryScreenshot(app, name: "Tailscale discovery setup")
        link.tap()
        let tailnet = app.textFields["tailnet.login.tailnet"].firstMatch
        let secret = app.secureTextFields["tailnet.login.secret"].firstMatch
        let submit = app.buttons["tailnet.login.submit"].firstMatch
        XCTAssertTrue(tailnet.waitForExistence(timeout: 8))
        XCTAssertTrue(secret.exists)
        XCTAssertTrue(submit.exists)
        XCTAssertFalse(app.textFields["tailnet.login.client"].firstMatch.exists)
        XCTAssertFalse(submit.isEnabled)
        attachLibraryScreenshot(app, name: "Tailscale two-field authorization")
        tailnet.tap()
        tailnet.typeText("fixture.example")
        XCTAssertFalse(submit.isEnabled)
        secret.tap()
        secret.typeText("tskey-client-fixture-id-proof")
        XCTAssertTrue(submit.wait(for: \.isEnabled, toEqual: true, timeout: 6))
        app.buttons["取消"].firstMatch.tap()
        XCTAssertTrue(link.waitForExistence(timeout: 5))
    }

    #if targetEnvironment(simulator)
    func testTailnetCategorySearchMatchesFolderAndDeviceTermsTogether() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString, "-AppleLanguages", "(zh-Hans)"]
        app.launchEnvironment["DESKLINK_TEST_TAILNET_LISTING"] = #"""
        {"devices":[
            {"id":"search-pc","hostname":"Workstation","name":"workstation.fixture.invalid","addresses":["100.64.7.81"],"os":"windows"},
            {"id":"search-mac","hostname":"Mini","name":"mini.fixture.invalid","addresses":["100.64.7.82"],"os":"macOS"}
        ]}
        """#
        app.launch()
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".screens")
        defer { try? FileManager.default.removeItem(at: file) }
        let groups: [[String: Any]] = [
            ["id": UUID().uuidString, "name": "Editing Room", "items": [String](),
             "rawItems": ["search-pc"], "contentType": 16]
        ]
        try JSONSerialization.data(withJSONObject: ["filename": "Directory search",
                                                     "screens": [], "folders": [], "tsFolders": groups]).write(to: file)
        app.open(file)
        let done = app.buttons["完成"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        done.tap()

        selectCollection("library.tailscale", in: app)
        let pc = app.buttons["tailnet.device.search-pc"].firstMatch
        let mac = app.buttons["tailnet.device.search-mac"].firstMatch
        XCTAssertTrue(pc.waitForExistence(timeout: 8))
        XCTAssertTrue(mac.exists)
        app.buttons["tailnet.menu"].firstMatch.tap()
        let importGroups = app.buttons["tailnet.folder.import"].firstMatch
        XCTAssertTrue(importGroups.waitForExistence(timeout: 5))
        importGroups.tap()
        let confirmation = app.alerts["导入归档分组"].firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["导入"].tap()

        XCTAssertTrue(app.staticTexts["tailnet.folder.importResult"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(pc.exists)
        XCTAssertTrue(mac.exists)
        let search = app.searchFields.firstMatch
        if !search.exists {
            let searchButton = app.navigationBars["Tailscale"].buttons["搜索"].firstMatch
            XCTAssertTrue(searchButton.waitForExistence(timeout: 5))
            searchButton.tap()
        }
        XCTAssertTrue(search.waitForExistence(timeout: 6))
        search.tap()
        search.typeText("editing Windows")
        XCTAssertTrue(pc.waitForExistence(timeout: 5))
        XCTAssertTrue(mac.waitForNonExistence(timeout: 5))
        attachLibraryScreenshot(app, name: "Tailscale search by folder and operating system")

        search.typeText(" missing")
        XCTAssertTrue(pc.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["未找到匹配的连接"].firstMatch.waitForExistence(timeout: 5))
    }

    func testLinkedTailnetExplainsMissingLocalNetworkAndCanDismissTheNotice() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString, "-AppleLanguages", "(zh-Hans)"]
        app.launchEnvironment["DESKLINK_TEST_TAILNET_LISTING"] = #"""
        {"devices":[
            {"id":"network-studio","hostname":"Fixture Studio","name":"studio.fixture.invalid","addresses":["100.71.7.19"],"os":"macOS"}
        ]}
        """#
        app.launch()
        selectCollection("library.tailscale", in: app)
        let notice = app.descendants(matching: .any).matching(identifier: "tailnet.localNetworkNotice").firstMatch
        let dismiss = app.buttons["tailnet.ignoreLocalNetworkNotice"].firstMatch
        let card = app.buttons["tailnet.device.network-studio"].firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 8))
        XCTAssertTrue(card.isHittable)
        attachLibraryScreenshot(app, name: "Tailscale local network notice")
        dismiss.tap()
        XCTAssertTrue(notice.waitForNonExistence(timeout: 5))
        XCTAssertTrue(card.isHittable)
    }

    func testQuickConnectOpensTailnetDeviceWithItsConfiguredPorts() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString, "-AppleLanguages", "(zh-Hans)"]
        app.launchEnvironment["DESKLINK_TEST_TAILNET_LISTING"] = #"""
        {"devices":[
            {"id":"quick-studio","hostname":"Fixture Studio","name":"studio.fixture.invalid","addresses":["100.64.7.19"],"os":"macOS","authorized":true},
            {"id":"unapproved","hostname":"Unapproved","name":"unapproved.fixture.invalid","addresses":["100.64.7.20"],"os":"linux","authorized":false}
        ]}
        """#
        app.launch()
        selectCollection("library.tailscale", in: app)
        let card = app.buttons["tailnet.device.quick-studio"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 8))
        card.press(forDuration: 0.8)
        let portSettings = app.buttons["端口设置"].firstMatch
        XCTAssertTrue(portSettings.waitForExistence(timeout: 8))
        portSettings.tap()
        let vnc = app.textFields["tailnet.ports.vnc"].firstMatch
        let ssh = app.textFields["tailnet.ports.ssh"].firstMatch
        XCTAssertTrue(vnc.waitForExistence(timeout: 8))
        vnc.tap()
        vnc.typeText("15971")
        ssh.tap()
        ssh.typeText("2207")
        app.buttons["tailnet.ports.save"].firstMatch.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 8))

        app.buttons["library.quick"].firstMatch.tap()
        let choose = app.buttons["connection.chooseDevice"].firstMatch
        XCTAssertTrue(choose.waitForExistence(timeout: 8))
        choose.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let prompt = springboard.alerts.containing(
            NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS %@", "local network", "本地网络")
        ).firstMatch
        if prompt.waitForExistence(timeout: 3) {
            prompt.buttons.matching(NSPredicate(format: "label IN %@", ["Allow", "允许"])).firstMatch.tap()
        }
        let device = app.buttons["connection.device.tailscale.quick-studio"].firstMatch
        XCTAssertTrue(device.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["connection.device.tailscale.unapproved"].firstMatch.exists)
        attachLibraryScreenshot(app, name: "Quick Connect device chooser")
        device.tap()
        let host = app.textFields["connection.host"].firstMatch
        XCTAssertTrue(host.waitForExistence(timeout: 8))
        XCTAssertEqual(host.value as? String, "100.64.7.19")
        XCTAssertEqual(app.textFields["connection.port"].firstMatch.value as? String, "15971")
        let form = app.collectionViews["connection.form"].firstMatch
        let useSSH = app.switches["connection.useSSH"].firstMatch
        for _ in 0..<4 where !useSSH.isHittable { form.swipeUp() }
        XCTAssertTrue(useSSH.isHittable)
        if useSSH.value as? String == "0" {
            useSSH.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        }
        XCTAssertEqual(useSSH.value as? String, "1")
        let sshPort = app.textFields["connection.sshPort"].firstMatch
        for _ in 0..<4 where !sshPort.exists { form.swipeUp() }
        XCTAssertEqual(sshPort.value as? String, "2207")
    }

    func testTailnetComputerShowsItsPlatformAndOpensWithThePcKeyboardDefault() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString, "-AppleLanguages", "(zh-Hans)"]
        app.launchEnvironment["DESKLINK_TEST_TAILNET_LISTING"] = #"""
        {"devices":[
          {"id":"pc","hostname":"Workstation","name":"workstation.fixture.invalid","addresses":["100.64.7.91"],"os":"windows"},
          {"id":"mobile","hostname":"Phone","name":"phone.fixture.invalid","addresses":["100.64.7.92"],"os":"android"}
        ]}
        """#
        app.launch()
        selectCollection("library.tailscale", in: app)
        let pc = app.buttons["tailnet.device.pc"].firstMatch
        XCTAssertTrue(pc.waitForExistence(timeout: 8))
        XCTAssertTrue(pc.label.contains("Windows") || pc.staticTexts["100.64.7.91 · Windows"].exists)
        XCTAssertFalse(app.buttons["tailnet.device.mobile"].firstMatch.exists)
        attachLibraryScreenshot(app, name: "Tailscale desktop directory")
        pc.tap()

        let host = app.textFields["connection.host"].firstMatch
        XCTAssertTrue(host.waitForExistence(timeout: 8))
        XCTAssertEqual(host.value as? String, "100.64.7.91")
        let form = app.collectionViews["connection.form"].firstMatch
        func reveal(_ element: XCUIElement) {
            for _ in 0..<10 {
                if element.isHittable,
                   form.frame.insetBy(dx: 0, dy: 18).contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) { return }
                let start = form.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.78))
                let end = form.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.38))
                start.press(forDuration: 0.05, thenDragTo: end)
            }
            XCTFail("Could not reveal \(element.identifier).")
        }
        let display = app.buttons["显示器"].firstMatch
        reveal(display)
        display.tap()
        let quality = app.buttons["connection.quality"].firstMatch
        reveal(quality)
        quality.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).tap()
        let standard = app.buttons["标准"].firstMatch
        XCTAssertTrue(standard.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["高性能"].firstMatch.exists)
        XCTAssertTrue(app.buttons["完整质量"].firstMatch.exists)
        attachLibraryScreenshot(app, name: "Windows picture quality choices")
        standard.tap()
        XCTAssertFalse(app.buttons["connection.adaptiveQuality"].firstMatch.exists)
        let keyboard = app.buttons["connection.hardwareKeyboard"].firstMatch
        reveal(keyboard)
        XCTAssertTrue(keyboard.label.contains("发送本地字符") || (keyboard.value as? String) == "发送本地字符",
                      keyboard.debugDescription)
        XCTAssertFalse(app.switches["connection.momentum"].firstMatch.exists)
        attachLibraryScreenshot(app, name: "Windows hardware keyboard default")
    }

    func testDiscoveredComputerLetsMeChooseASavedProfileOrEnterAnAccountManually() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString, "-AppleLanguages", "(zh-Hans)"]
        app.launchEnvironment["DESKLINK_TEST_TAILNET_LISTING"] = #"""
        {"devices":[
          {"id":"profile-studio","hostname":"Fixture Studio","name":"studio.fixture.invalid.","addresses":["100.64.7.19","fd7a:115c:a1e0::19"],"os":"macOS","authorized":true},
          {"id":"mobile","hostname":"Fixture iPad","name":"ipad.fixture.invalid","addresses":["100.64.7.21"],"os":"iOS"}
        ]}
        """#
        app.launch()
        XCTAssertTrue(app.buttons["library.new"].waitForExistence(timeout: 10))

        let firstID = UUID().uuidString
        let secondID = UUID().uuidString
        func record(id: String, name: String, host: String, account: String) -> [String: Any] {
            [
                "version": 6, "id": id, "type": ["saved": [:] as [String: String]], "name": name,
                "hostname": host, "port": 5900, "clientProtocol": "vnc",
                "users": [["username": account]], "authenticationMethod": 1, "operatingSystem": 1,
                "startInObserveMode": false, "onDisconnectAction": 0,
                "useSharedClipboard": true, "useSecureConnection": false
            ]
        }
        let records = [record(id: firstID, name: "Fixture Support", host: "studio.fixture.invalid", account: "support-fixture"),
                       record(id: secondID, name: "Fixture Operator", host: "fd7a:115c:a1e0:0:0:0:0:19", account: "operator-fixture")]
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".screens")
        defer { try? FileManager.default.removeItem(at: file) }
        try JSONSerialization.data(withJSONObject: ["filename": "Profile choices", "screens": records, "folders": []])
            .write(to: file)
        app.open(file)
        let imported = app.alerts["导入完成"]
        XCTAssertTrue(imported.waitForExistence(timeout: 10))
        imported.buttons.firstMatch.tap()

        selectCollection("library.tailscale", in: app)
        let device = app.buttons["tailnet.device.profile-studio"].firstMatch
        XCTAssertTrue(device.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["tailnet.device.mobile"].firstMatch.exists)
        device.tap()
        let support = app.buttons["connection.profile." + firstID].firstMatch
        let operatorProfile = app.buttons["connection.profile." + secondID].firstMatch
        XCTAssertTrue(support.waitForExistence(timeout: 8))
        XCTAssertTrue(operatorProfile.label.contains("operator-fixture"))
        XCTAssertTrue(support.label.contains("support-fixture"))
        XCTAssertFalse(app.textFields["connection.username"].firstMatch.exists)
        attachLibraryScreenshot(app, name: "Saved profiles for a discovered computer")
        operatorProfile.tap()

        let username = app.textFields["connection.username"].firstMatch
        XCTAssertTrue(username.waitForExistence(timeout: 8))
        XCTAssertEqual(username.value as? String, "operator-fixture")
        XCTAssertEqual(app.textFields["connection.host"].firstMatch.value as? String, "fd7a:115c:a1e0:0:0:0:0:19")
        app.navigationBars.buttons["取消"].firstMatch.tap()

        XCTAssertTrue(device.waitForExistence(timeout: 8))
        device.press(forDuration: 0.8)
        let save = app.buttons["保存到连接库"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 8))
        save.tap()
        XCTAssertTrue(support.waitForExistence(timeout: 8))
        support.tap()
        XCTAssertTrue(username.waitForExistence(timeout: 8))
        XCTAssertEqual(username.value as? String, "support-fixture")
        XCTAssertEqual(app.textFields["connection.host"].firstMatch.value as? String, "studio.fixture.invalid")
        XCTAssertEqual(app.buttons["connection.submit"].firstMatch.label, "保存")
        app.navigationBars.buttons["取消"].firstMatch.tap()

        app.buttons["library.quick"].firstMatch.tap()
        let chooseDevice = app.buttons["connection.chooseDevice"].firstMatch
        XCTAssertTrue(chooseDevice.waitForExistence(timeout: 8))
        chooseDevice.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let networkPrompt = springboard.alerts.containing(
            NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS %@", "local network", "本地网络")
        ).firstMatch
        if networkPrompt.waitForExistence(timeout: 3) {
            networkPrompt.buttons.matching(NSPredicate(format: "label IN %@", ["Allow", "允许"])).firstMatch.tap()
        }
        let quickDevice = app.buttons["connection.device.tailscale.profile-studio"].firstMatch
        XCTAssertTrue(quickDevice.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["connection.device.tailscale.mobile"].firstMatch.exists)
        quickDevice.tap()
        let manual = app.buttons["connection.profile.manual"].firstMatch
        XCTAssertTrue(manual.waitForExistence(timeout: 8))
        manual.tap()
        XCTAssertTrue(username.waitForExistence(timeout: 8))
        XCTAssertTrue((username.value as? String ?? "").isEmpty || username.value as? String == username.placeholderValue)
        XCTAssertEqual(app.textFields["connection.host"].firstMatch.value as? String, "100.64.7.19")
    }

    func testOpeningScreensDirectoryArchiveReportsPreservedFolders() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString, "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        XCTAssertTrue(app.buttons["library.new"].waitForExistence(timeout: 10))
        let data = Data(#"{"filename":"Fixture","screens":[],"folders":[],"tsFolders":[{"id":"EA5E2C8A-84E5-46F4-BF4C-331B2900677A","name":"Test","items":[],"rawItems":["fixture-node"],"contentType":16}]}"#.utf8)
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".screens")
        defer { try? FileManager.default.removeItem(at: file) }
        try data.write(to: file)
        app.open(file)
        let alert = app.alerts["导入完成"]
        XCTAssertTrue(alert.waitForExistence(timeout: 12))
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "另保留 1 个目录分组，可随归档导出。")).firstMatch.exists)
        XCTAssertFalse(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "已迁移连接地址")).firstMatch.exists)
        let picture = XCTAttachment(screenshot: app.screenshot())
        picture.name = "Imported Screens directory groups"
        picture.lifetime = .keepAlways
        add(picture)
    }

    func testOpenArchiveDocumentTwiceUsingTheSystemFileRoute() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.buttons["library.new"].waitForExistence(timeout: 10))
        let data: Data
        if let encoded = ProcessInfo.processInfo.environment["DESKLINK_ARCHIVE_BASE64"] {
            data = try XCTUnwrap(Data(base64Encoded: encoded))
        } else {
            data = Data(#"{"version":1,"folders":["文稿往返"],"computers":[]}"#.utf8)
        }
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let computers = try XCTUnwrap(envelope["computers"] as? [[String: Any]])
        let folders = try XCTUnwrap(envelope["folders"] as? [String])
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".desklink")
        defer { try? FileManager.default.removeItem(at: file) }
        try data.write(to: file)
        for expected in ["新增连接 \(computers.count) 个，新增文件夹 \(folders.count) 个，跳过重复连接 0 个。",
                         "新增连接 0 个，新增文件夹 0 个，跳过重复连接 \(computers.count) 个。"] {
            app.open(file)
            let alert = app.alerts["导入完成"]
            XCTAssertTrue(alert.waitForExistence(timeout: 12))
            XCTAssertTrue(alert.staticTexts[expected].exists)
            alert.buttons["完成"].tap()
        }
    }
    #endif

    func testManualDragAndNameSortSurviveRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        let create = app.buttons["library.new"]
        XCTAssertTrue(create.waitForExistence(timeout: 12))
        func add(_ name: String, host: String) {
            create.tap()
            app.textFields["connection.name"].tap()
            app.textFields["connection.name"].typeText(name)
            app.textFields["connection.host"].tap()
            app.textFields["connection.host"].typeText(host)
            app.buttons["connection.submit"].tap()
            XCTAssertTrue(app.buttons["connection.submit"].waitForNonExistence(timeout: 5))
        }
        func layout(_ action: String) {
            app.buttons["library.more"].tap()
            app.buttons[action].firstMatch.tap()
        }
        func order(_ name: String) {
            layout("排序")
            app.buttons[name].firstMatch.tap()
        }
        let tiles = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.computer."))
        add("Desktop 2", host: "two.fixture.invalid")
        add("Desktop 10", host: "ten.fixture.invalid")
        func tile(_ name: String) -> XCUIElement {
            tiles.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        }
        let two = tile("Desktop 2"), ten = tile("Desktop 10")
        XCTAssertTrue(two.waitForExistence(timeout: 5))
        XCTAssertTrue(ten.waitForExistence(timeout: 5))
        XCTAssertLessThan(two.frame.midX, ten.frame.midX)
        two.press(forDuration: 0.5, thenDragTo: ten, withVelocity: .slow, thenHoldForDuration: 0.4)
        func waitForOrder(_ check: @escaping () -> Bool) {
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in check() }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 6), .completed)
        }
        waitForOrder { ten.frame.midX < two.frame.midX }
        order("名称")
        waitForOrder { two.frame.midX < ten.frame.midX }
        app.terminate()
        app.launch()
        XCTAssertTrue(ten.waitForExistence(timeout: 8))
        XCTAssertLessThan(two.frame.midX, ten.frame.midX)
        order("自定顺序")
        waitForOrder { ten.frame.midX < two.frame.midX }
        layout("列表")
        waitForOrder { ten.frame.midY < two.frame.midY }
        ten.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.6, thenDragTo: two.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)),
                   withVelocity: .slow, thenHoldForDuration: 0.4)
        waitForOrder { two.frame.midY < ten.frame.midY }
    }

    func testDuplicateCanBeCancelledThenSavedWithoutChangingTheSource() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        let create = app.buttons["library.new"]
        XCTAssertTrue(create.waitForExistence(timeout: 12))
        create.tap()
        let name = app.textFields["connection.name"]
        name.tap()
        name.typeText("Studio")
        let host = app.textFields["connection.host"]
        host.tap()
        host.typeText("127.0.0.1:5917")
        app.buttons["connection.submit"].tap()
        let items = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.computer."))
        let original = items.firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        let originalID = original.identifier
        func duplicate() {
            app.buttons[originalID].press(forDuration: 0.8)
            app.buttons["复制连接"].firstMatch.tap()
            XCTAssertTrue(name.waitForExistence(timeout: 5))
            XCTAssertEqual(name.value as? String, "Studio 副本")
        }
        duplicate()
        app.buttons["取消"].tap()
        XCTAssertTrue(name.waitForNonExistence(timeout: 5))
        XCTAssertEqual(items.count, 1)
        duplicate()
        app.buttons["connection.submit"].tap()
        let copy = items.matching(NSPredicate(format: "label CONTAINS %@", "Studio 副本")).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        XCTAssertNotEqual(copy.identifier, originalID)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons[originalID].waitForExistence(timeout: 10))
        XCTAssertTrue(copy.exists)
        XCTAssertEqual(items.count, 2)
    }

    func testCreateRelaunchAndDeleteSavedDesktop() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString, "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let emptyRecent = app.staticTexts["没有最近连接"].firstMatch
        XCTAssertTrue(emptyRecent.waitForExistence(timeout: 10))
        attachLibraryScreenshot(app, name: "Empty recent connections")
        let create = app.buttons["library.empty.new"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 12))
        create.tap()
        let name = app.textFields["connection.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("DeskLink QA")
        app.textFields["connection.host"].tap()
        app.textFields["connection.host"].typeText("127.0.0.1:5917")
        app.buttons["connection.submit"].tap()
        let entry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                     "library.computer.", "DeskLink QA")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 6))
        attachLibraryScreenshot(app, name: "First saved computer")
        app.terminate()
        app.launch()
        XCTAssertTrue(entry.waitForExistence(timeout: 12))
        entry.press(forDuration: 1)
        app.buttons["删除"].firstMatch.tap()
        app.alerts.buttons["删除"].tap()
        XCTAssertTrue(entry.waitForNonExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(emptyRecent.waitForExistence(timeout: 10))
        app.buttons["library.more"].tap()
        app.buttons["设置"].firstMatch.tap()
        let backups = app.buttons["preferences.backups"]
        for _ in 0..<4 where !backups.isHittable { app.swipeUp() }
        XCTAssertTrue(backups.isHittable)
        backups.tap()
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                    "backup.", "1 个连接")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        saved.tap()
        app.alerts.buttons["取消"].tap()
        saved.tap()
        app.alerts.buttons["恢复备份"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "backup.restored").firstMatch.waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
    }

    #if os(iOS) && !targetEnvironment(macCatalyst)
    func testImportScreensArchiveUsingSystemPicker() throws {
        guard let raw = ProcessInfo.processInfo.environment["DESKLINK_SCREENS_DOCUMENT"],
              let id = UUID(uuidString: raw) else { throw XCTSkip("Requires the known synthetic .screens file on the iPad.") }
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        let more = app.buttons["library.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        app.buttons["导入"].tap()
        func named(_ labels: [String]) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@ OR identifier IN %@", labels, labels)).firstMatch
        }
        let grid = app.collectionViews["File View"].cells
        let document = grid.matching(NSPredicate(format: "identifier CONTAINS[c] %@ OR label CONTAINS[c] %@", raw, raw)).firstMatch
        func choose(_ element: XCUIElement, _ name: String) throws {
            guard element.waitForExistence(timeout: 8), element.isHittable else {
                #if targetEnvironment(simulator)
                let snapshot = XCTAttachment(screenshot: app.screenshot())
                snapshot.name = "Archive picker at " + name
                snapshot.lifetime = .keepAlways
                add(snapshot)
                #endif
                throw NSError(domain: "TelescopeArchiveTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Picker did not show " + name])
            }
            let icon = element.images.firstMatch
            if icon.exists { icon.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
            else { element.tap() }
        }
        if !document.waitForExistence(timeout: 2) {
            let names = ["On My iPad", "在我的 iPad 上", "我的iPad", "我的 iPad"]
            let location = app.cells.containing(NSPredicate(format: "label IN %@", names)).firstMatch
            let sidebar = app.buttons["ToggleSideBar"]
            if !location.isHittable, sidebar.isHittable { sidebar.tap() }
            try choose(location.isHittable ? location : named(names), "On My iPad")
            let buttons = app.buttons.matching(NSPredicate(format: "label IN %@", ["Search", "搜索"]))
            if let searchButton = buttons.allElementsBoundByIndex.last(where: { $0.isHittable }) {
                searchButton.tap()
                // Files owns the focused field in a separate process. The app's
                // search field behind the sheet remains visible to XCTest.
                XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
                app.typeText(raw + "\n")
                let suggestion = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", raw)).firstMatch
                if suggestion.waitForExistence(timeout: 2), suggestion.isHittable { suggestion.tap() }
            } else {
                let container = grid.matching(NSPredicate(format: "identifier BEGINSWITH %@ OR identifier BEGINSWITH %@", "远程随航,", "Telescope,")).firstMatch
                try choose(container, "Telescope")
                let downloads = grid.matching(NSPredicate(format: "label BEGINSWITH[c] %@ OR label BEGINSWITH %@", "Downloads", "下载")).firstMatch
                try choose(downloads, "Downloads")
            }
        }
        try choose(document, raw)
        let confirm = app.buttons.matching(NSPredicate(format: "label IN %@", ["打开", "Open"])).firstMatch
        if confirm.isHittable { confirm.tap() }
        let result = app.alerts["导入完成"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertTrue(result.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "SSH")).firstMatch.exists)
        result.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["library.computer." + id.uuidString].waitForExistence(timeout: 8))
    }

    func testOpenReceivedArchiveFromSystemFiles() throws {
        guard let raw = ProcessInfo.processInfo.environment["DESKLINK_FILES_FIXTURE"], let id = UUID(uuidString: raw) else {
            throw XCTSkip("Run after receiving the matching archive on this iPad.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.buttons["library.new"].waitForExistence(timeout: 10))
        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        files.activate()
        func named(_ labels: [String]) -> XCUIElement {
            files.descendants(matching: .any).matching(NSPredicate(format: "label IN %@ OR identifier IN %@", labels, labels)).firstMatch
        }
        let cells = files.collectionViews["File View"].cells
        func folder(_ labels: [String]) -> XCUIElement {
            cells.containing(NSPredicate(format: "label IN %@", labels)).firstMatch
        }
        func openItem(_ entry: XCUIElement, named label: String) throws {
            guard entry.waitForExistence(timeout: 10) else {
                throw CocoaError(.fileReadNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Files did not list " + label])
            }
            let icon = entry.images.firstMatch
            if icon.exists { icon.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
            else { entry.tap() }
        }
        let start = named(["Continue", "继续"])
        if start.waitForExistence(timeout: 2), start.isHittable { start.tap() }
        let appNames = ["远程随航", "Telescope"]
        let local = ["On My iPad", "在我的 iPad 上", "我的iPad", "我的 iPad"]
        let appFolder = folder(appNames)
        let downloads = folder(["Downloads", "下载项", "下载"])
        let base = "DeskLink-" + id.uuidString
        let document = cells.matching(NSPredicate(format: "identifier CONTAINS[c] %@ OR label CONTAINS[c] %@", id.uuidString, id.uuidString)).firstMatch
        if !document.exists {
            if !appFolder.exists {
                let browse = named(["Browse", "浏览"])
                if browse.exists, browse.isHittable { browse.tap() }
                let location = files.cells.containing(NSPredicate(format: "label IN %@", local)).firstMatch
                let sidebar = files.buttons["ToggleSideBar"]
                if !location.isHittable, sidebar.isHittable { sidebar.tap() }
                let localEntry = location.isHittable ? location : named(local)
                XCTAssertTrue(localEntry.waitForExistence(timeout: 6))
                localEntry.tap()
            }
            // Another provider can also have a Downloads folder. Enter ours from On My iPad.
            try openItem(appFolder, named: appNames[0])
            try openItem(downloads, named: "Downloads")
        }
        try openItem(document, named: base)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let result = app.alerts["导入完成"]
        XCTAssertTrue(result.waitForExistence(timeout: 8))
        result.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["library.computer." + id.uuidString].waitForExistence(timeout: 8))
    }

    #endif

    func testTransferLibraryAndPreferences() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        let transfers = app.buttons["library.transfers"]
        XCTAssertTrue(transfers.waitForExistence(timeout: 12))
        transfers.tap()
        XCTAssertTrue(app.staticTexts["没有传输"].waitForExistence(timeout: 5))
        app.buttons["关闭"].tap()
        func openPreferences() {
            app.buttons["library.more"].tap()
            app.buttons["设置"].firstMatch.tap()
        }
        openPreferences()
        let setting = app.switches["preferences.transfers"]
        XCTAssertTrue(setting.waitForExistence(timeout: 5))
        let original = try XCTUnwrap(setting.value as? String)
        // The Form exposes the full labeled row as a switch on iPad. Its
        // thumb is at the trailing edge of the row.
        setting.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        let didChange = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", original), object: setting)
        if XCTWaiter.wait(for: [didChange], timeout: 5) != .completed {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "Transfer permission switch"
            shot.lifetime = .keepAlways
            add(shot)
            XCTFail("The transfer switch did not change after tapping its thumb")
            return
        }
        let changed = try XCTUnwrap(setting.value as? String)
        XCTAssertNotEqual(original, changed)
        app.terminate()
        app.launch()
        openPreferences()
        XCTAssertTrue(setting.waitForExistence(timeout: 5))
        XCTAssertEqual(setting.value as? String, changed)
    }

    private func selectCollection(_ identifier: String, in app: XCUIApplication) {
        let item = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        if !item.isHittable {
            let sidebar = app.buttons["ToggleSideBar"].firstMatch
            if sidebar.isHittable { sidebar.tap() }
            else if app.buttons["BackButton"].firstMatch.isHittable { app.buttons["BackButton"].firstMatch.tap() }
            else if app.buttons["显示边栏"].firstMatch.isHittable { app.buttons["显示边栏"].firstMatch.tap() }
        }
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        #if targetEnvironment(macCatalyst)
        item.click()
        #else
        item.tap()
        #endif
    }

    private func attachLibraryScreenshot(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
