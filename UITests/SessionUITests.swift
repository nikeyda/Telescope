import UIKit
import XCTest

@MainActor
final class SessionUITests: XCTestCase {
    #if !targetEnvironment(macCatalyst)
    func testClearingASavedDesktopPreviewFromConnectionSettingsSurvivesRelaunch() async throws {
        continueAfterFailure = false
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString, "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        XCTAssertTrue(app.buttons["library.new"].firstMatch.waitForExistence(timeout: 10))
        let id = UUID().uuidString
        let file = FileManager.default.temporaryDirectory.appending(path: id + ".screens")
        defer { try? FileManager.default.removeItem(at: file) }
        let archive = """
            {"filename":"Preview fixture","folders":[],"screens":[{
            "version":6,"id":"\(id)","type":{"saved":{}},"name":"Preview Fixture",
            "hostname":"127.0.0.1","port":\(port),"clientProtocol":"vnc",
            "users":[],"authenticationMethod":3,"operatingSystem":6,"startInObserveMode":false,
            "onDisconnectAction":0,"grabScreenshot":true,"useSharedClipboard":false,"useSecureConnection":false}]}
            """
        try Data(archive.utf8).write(to: file)
        app.open(file)
        let imported = app.alerts["导入完成"]
        XCTAssertTrue(imported.waitForExistence(timeout: 10))
        imported.buttons["完成"].tap()

        let row = app.buttons["library.computer." + id].firstMatch
        func makePreview() async throws {
            let frames = desktop.frameCount
            XCTAssertTrue(row.waitForExistence(timeout: 8))
            row.tap()
            let close = app.buttons["session.close"].firstMatch
            try await waitUntil { desktop.frameCount > frames && close.isHittable && Self.hasColorChart(app.screenshot().image) }
            let count = desktop.closedConnections
            desktop.expectsClientDisconnect = true
            close.tap()
            try await waitUntil { desktop.closedConnections > count && row.isHittable }
            desktop.expectsClientDisconnect = false
        }
        let form = app.collectionViews["connection.form"].firstMatch
        let capture = form.switches["connection.disconnectScreenshot"].firstMatch
        let preview = form.buttons["connection.desktopPreview"].firstMatch
        let clear = form.buttons["connection.clearDesktopPreview"].firstMatch
        func openSettings() {
            XCTAssertTrue(row.waitForExistence(timeout: 8))
            row.press(forDuration: 0.8)
            app.buttons["编辑连接"].firstMatch.tap()
            XCTAssertTrue(form.waitForExistence(timeout: 8))
            for _ in 0..<5 where !capture.isHittable { form.swipeUp() }
            XCTAssertTrue(capture.isHittable)
        }

        try await makePreview()
        openSettings()
        XCTAssertEqual(capture.value as? String, "1")
        XCTAssertTrue(preview.waitForExistence(timeout: 6))
        attachToolbarScreenshot(app, name: "Saved desktop preview in connection settings")
        preview.tap()
        let viewer = app.navigationBars["上次桌面快照"]
        XCTAssertTrue(viewer.waitForExistence(timeout: 6))
        try await waitUntil { Self.hasColorChart(app.screenshot().image) }
        let back = viewer.buttons["BackButton"].firstMatch
        if back.exists { back.tap() }
        else { viewer.buttons.firstMatch.tap() }
        for _ in 0..<4 where !clear.isHittable { form.swipeUp() }
        XCTAssertTrue(clear.isHittable)
        clear.tap()
        let confirmation = app.alerts["清除桌面快照？"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 6))
        confirmation.buttons["取消"].tap()
        XCTAssertTrue(preview.exists)
        clear.tap()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 6))
        confirmation.buttons["清除快照"].tap()
        XCTAssertTrue(preview.waitForNonExistence(timeout: 8))
        XCTAssertEqual(capture.value as? String, "1")
        app.buttons["取消"].firstMatch.tap()

        app.terminate()
        app.launch()
        openSettings()
        XCTAssertEqual(capture.value as? String, "1")
        XCTAssertFalse(preview.exists)
        XCTAssertFalse(clear.exists)
        app.buttons["取消"].firstMatch.tap()
        try await makePreview()
        openSettings()
        XCTAssertTrue(preview.waitForExistence(timeout: 6))
    }

    func testSavedClipboardPolicyOverridesTheDefaultAndKeepsManualTransfers() async throws {
        continueAfterFailure = false
        let desktop = LocalTestDisplay()
        desktop.sendsClipboardWithFrames = false
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString, "-AppleLanguages", "(zh-Hans)"]
        app.launch()

        let create = app.buttons["library.new"].firstMatch
        let submit = app.buttons["connection.submit"].firstMatch
        let form = app.collectionViews["connection.form"].firstMatch
        let policy = form.buttons["connection.sharedClipboard"].firstMatch
        func setPolicy(from previous: String, to choice: String) {
            for _ in 0..<5 where !policy.isHittable { form.swipeUp() }
            XCTAssertTrue(policy.isHittable, form.debugDescription)
            XCTAssertTrue(policy.label.hasSuffix(previous), policy.debugDescription)
            policy.tap()
            app.buttons[choice].firstMatch.tap()
            XCTAssertTrue(policy.label.hasSuffix(choice), policy.debugDescription)
        }

        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.tap()
        let authentication = app.buttons["connection.authentication"].firstMatch
        XCTAssertTrue(authentication.waitForExistence(timeout: 8))
        authentication.tap()
        app.buttons["无认证"].firstMatch.tap()
        setPolicy(from: "跟随应用设置", to: "关闭")

        let name = "Clipboard Policy Fixture"
        let nameField = app.textFields["connection.name"].firstMatch
        for _ in 0..<5 where !nameField.isHittable { form.swipeDown() }
        XCTAssertTrue(nameField.isHittable)
        nameField.tap()
        nameField.typeText(name)
        let hostField = app.textFields["connection.host"].firstMatch
        hostField.tap()
        hostField.typeText("127.0.0.1:\(port)")
        submit.tap()
        XCTAssertTrue(submit.waitForNonExistence(timeout: 8))

        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                    "library.computer.", name)).firstMatch
        let clipboard = app.buttons["session.clipboard"].firstMatch
        func connect() async throws {
            let frames = desktop.frameCount
            XCTAssertTrue(row.waitForExistence(timeout: 8))
            row.tap()
            try await waitUntil { desktop.frameCount > frames && clipboard.isHittable }
        }
        func disconnect() async throws {
            let closed = desktop.closedConnections
            desktop.expectsClientDisconnect = true
            app.buttons["session.close"].firstMatch.tap()
            try await waitUntil { desktop.closedConnections > closed && row.isHittable }
            desktop.expectsClientDisconnect = false
        }
        func clipboardAction(_ name: String) async throws {
            clipboard.tap()
            let button = app.buttons[name].firstMatch
            do { try await waitUntil { button.exists && button.isEnabled } }
            catch {
                XCTFail("The clipboard action \(name) was unavailable: \(button.debugDescription)")
                throw error
            }
            button.tap()
        }
        func sendLocalClipboard(_ expected: String) async throws {
            let writes = desktop.clipboardWrites
            try await clipboardAction("发送剪贴板")
            do {
                try await waitUntil { desktop.clipboardWrites > writes && desktop.receivedClipboard == Data(expected.utf8) }
            } catch {
                XCTFail("Unexpected clipboard fixture data: \(String(decoding: desktop.receivedClipboard, as: UTF8.self)); peer: \(desktop.failure ?? "available")")
                throw error
            }
        }

        try await connect()
        try await desktop.publishClipboard("First remote value")
        try await clipboardAction("接收剪贴板")
        try await sendLocalClipboard("First remote value")
        try await desktop.publishClipboard("This value must stay remote")
        try await Task.sleep(for: .milliseconds(250))
        try await sendLocalClipboard("First remote value")
        try await disconnect()

        app.buttons["library.more"].firstMatch.tap()
        app.buttons["设置"].firstMatch.tap()
        let applicationDefault = app.switches["preferences.sharedClipboard"].firstMatch
        XCTAssertTrue(applicationDefault.waitForExistence(timeout: 8))
        XCTAssertEqual(applicationDefault.value as? String, "1")
        applicationDefault.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(applicationDefault.value as? String, "0")
        app.buttons["关闭"].firstMatch.tap()

        row.press(forDuration: 0.8)
        app.buttons["编辑连接"].firstMatch.tap()
        setPolicy(from: "关闭", to: "开启")
        attachToolbarScreenshot(app, name: "Clipboard override enabled for one saved computer")
        submit.tap()
        XCTAssertTrue(submit.waitForNonExistence(timeout: 8))
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        app.launch()

        try await connect()
        try await desktop.publishClipboard("Automatically received on this saved connection")
        try await Task.sleep(for: .milliseconds(250))
        try await sendLocalClipboard("Automatically received on this saved connection")
        XCTAssertEqual(desktop.acceptedConnections, 2)
        try await disconnect()
    }

    func testSavedDesktopRestoresObservationAfterRelaunchWithoutSendingInput() async throws {
        continueAfterFailure = false
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString, "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        XCTAssertTrue(app.buttons["library.new"].firstMatch.waitForExistence(timeout: 10))

        let id = UUID().uuidString
        let file = FileManager.default.temporaryDirectory.appending(path: id + ".screens")
        defer { try? FileManager.default.removeItem(at: file) }
        let fixture = """
            {"filename":"Observe mode fixture","folders":[],"screens":[{
            "version":6,"id":"\(id)","type":{"saved":{}},"name":"Observe Mode Fixture",
            "hostname":"127.0.0.1","port":\(port),"clientProtocol":"vnc",
            "users":[],"authenticationMethod":3,"operatingSystem":6,"startInObserveMode":false,
            "onDisconnectAction":0,"useSharedClipboard":false,"useSecureConnection":false}]}
            """
        try Data(fixture.utf8).write(to: file)
        app.open(file)
        let imported = app.alerts["导入完成"]
        XCTAssertTrue(imported.waitForExistence(timeout: 10))
        imported.buttons["完成"].tap()

        let row = app.buttons["library.computer." + id].firstMatch
        let mode = app.buttons["session.mode"].firstMatch
        let input = app.descendants(matching: .any).matching(identifier: "session.input").firstMatch
        let desktopCenter = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        func connect(_ expected: String) async throws {
            XCTAssertTrue(row.waitForExistence(timeout: 8))
            let frames = desktop.frameCount
            row.tap()
            try await waitUntil { desktop.frameCount > frames }
            try await waitUntil { mode.exists && mode.label == expected }
        }
        func disconnect() async throws {
            let closed = desktop.closedConnections
            desktop.expectsClientDisconnect = true
            app.buttons["session.close"].firstMatch.tap()
            try await waitUntil { desktop.closedConnections > closed && row.isHittable }
            desktop.expectsClientDisconnect = false
        }

        try await connect("控制")
        mode.tap()
        try await waitUntil { mode.label == "仅观察" }
        try await disconnect()
        app.terminate()
        app.launch()

        app.buttons["library.quick"].firstMatch.tap()
        applyLink("screens://Observe%20Mode%20Fixture?observe=false", in: app)
        let framesBeforeLink = desktop.frameCount
        let submit = app.buttons["connection.submit"].firstMatch
        XCTAssertTrue(submit.waitForExistence(timeout: 8))
        submit.tap()
        try await waitUntil { desktop.frameCount > framesBeforeLink && mode.label == "控制" }
        try await disconnect()

        try await connect("仅观察")
        XCTAssertFalse(input.exists)
        let clicks = desktop.clicks
        desktopCenter.tap()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(desktop.clicks, clicks)
        attachToolbarScreenshot(app, name: "Saved connection reopened in Observe mode")
        mode.tap()
        try await waitUntil { mode.label == "控制" && input.exists }
        desktopCenter.tap()
        try await waitUntil { desktop.clicks > clicks }
        try await disconnect()
        app.terminate()
        app.launch()

        try await connect("控制")
        XCTAssertEqual(desktop.acceptedConnections, 4)
        try await disconnect()
    }

    func testRememberedComputerConnectsFromItsTileAndWidgetURL() async throws {
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        let name = "Desk " + String(UUID().uuidString.prefix(8))
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        let new = app.buttons["library.new"]
        XCTAssertTrue(new.waitForExistence(timeout: 10))
        new.tap()
        let remember = app.switches["connection.remember"]
        let thumb = remember.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
        thumb.tap()
        guard remember.value as? String == "1" else {
            XCTFail("The new connection form did not enable password storage.")
            return
        }
        let host = app.textFields["connection.host"]
        let computerName = app.textFields["connection.name"]
        computerName.tap()
        computerName.typeText(name)
        host.tap()
        host.typeText("127.0.0.1:\(port)")
        let username = app.textFields["connection.username"]
        username.tap()
        username.typeText("fixture-" + UUID().uuidString.lowercased())
        let secret = app.secureTextFields["connection.password"]
        secret.tap()
        secret.typeText("one-tap-fixture")
        XCTAssertEqual(remember.value as? String, "1")
        let save = app.buttons["connection.submit"]
        save.tap()
        let dismissPasswordManager = app.alerts["保存密码？"].buttons["以后"]
        if dismissPasswordManager.waitForExistence(timeout: 3) { dismissPasswordManager.tap() }
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                  "library.computer.", name)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        let id = try XCTUnwrap(row.identifier.split(separator: ".").last.flatMap { UUID(uuidString: String($0)) })
        let route = try XCTUnwrap(URL(string: "desklink:///connect/" + id.uuidString))
        func openWidgetURL() {
            XCUIDevice.shared.system.open(route)
            let confirm = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["打开"]
            if confirm.waitForExistence(timeout: 2) { confirm.tap() }
        }
        for fromWidget in [false, true] {
            let before = desktop.frameCount, closedBefore = desktop.closedConnections
            if fromWidget { openWidgetURL() } else { row.tap() }
            // The test peer handles its handshake on the runner's main actor. Give it time
            // to send the frame before XCTest synchronously asks the viewer for its UI.
            do { try await waitUntil(timeout: 30) { desktop.frameCount > before } }
            catch {
                XCTFail("No frame from \(fromWidget ? "widget URL" : "library tile"). Accepted \(desktop.acceptedConnections), closed \(desktop.closedConnections), overlapping \(desktop.overlappingConnections), server error \(desktop.failure ?? "none").")
                return
            }
            try await waitUntil(timeout: 30) {
                if dismissPasswordManager.exists && dismissPasswordManager.isHittable {
                    dismissPasswordManager.tap()
                    return false
                }
                return app.buttons["session.mode"].exists && Self.hasColorChart(app.screenshot().image)
            }
            app.typeKey("c", modifierFlags: [.shift, .control, .command])
            try await waitUntil { !app.buttons["session.mode"].exists && row.isHittable }
            do { try await waitUntil { desktop.closedConnections > closedBefore } }
            catch {
                XCTFail("The viewer returned to the library without closing its connection to the test display.")
                return
            }
        }
        // Forget only this test account, then check that credentials are requested again.
        row.press(forDuration: 0.8)
        app.buttons["编辑连接"].firstMatch.tap()
        XCTAssertEqual(remember.value as? String, "1")
        remember.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        save.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let frameCount = desktop.frameCount
        openWidgetURL()
        XCTAssertTrue(host.waitForExistence(timeout: 8))
        XCTAssertEqual(remember.value as? String, "0")
        XCTAssertEqual(desktop.frameCount, frameCount)
    }

    private func reveal(_ element: XCUIElement, in form: XCUIElement) -> Bool {
        for _ in 0..<9 {
            if element.exists && element.isHittable
                && form.frame.insetBy(dx: 0, dy: 15).contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) {
                return true
            }
            let start = form.coordinate(withNormalizedOffset: CGVector(dx: 0.48, dy: 0.76))
            let end = form.coordinate(withNormalizedOffset: CGVector(dx: 0.48, dy: 0.32))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        return false
    }

    func testPinchRespectsTheConnectionSettingAndKeepsPointerCoordinatesAligned() async throws {
        for allowsZoom in [true, false] {
            let desktop = LocalTestDisplay()
            let port = try await desktop.start()
            defer { desktop.stop() }
            let app = XCUIApplication()
            app.launchArguments = ["--test-library", UUID().uuidString]
            app.launch()
            XCTAssertTrue(app.buttons["library.quick"].waitForExistence(timeout: 10))
            app.open(try XCTUnwrap(URL(string: "vnc://127.0.0.1:\(port)")))
            let form = app.collectionViews["connection.form"].firstMatch
            XCTAssertTrue(form.waitForExistence(timeout: 8))
            let display = app.buttons["显示器"].firstMatch
            XCTAssertTrue(reveal(display, in: form))
            display.tap()
            let setting = app.switches["connection.viewportZoom"].firstMatch
            XCTAssertTrue(reveal(setting, in: form))
            XCTAssertEqual(setting.value as? String, "1")
            if !allowsZoom {
                setting.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
                XCTAssertEqual(setting.value as? String, "0")
            }
            app.buttons["connection.submit"].tap()
            let surface = app.descendants(matching: .any).matching(identifier: "session.input").firstMatch
            try await waitUntil { desktop.frameCount > 0 && surface.isHittable && Self.hasColorChart(app.screenshot().image) }
            let point = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
            func clickedX() async throws -> Int {
                let earlier = desktop.primaryPresses.count
                point.tap()
                try await waitUntil { desktop.primaryPresses.count > earlier }
                return desktop.primaryPresses[earlier]
            }
            let before = try await clickedX()
            let coverageBefore = Self.chartFractions(XCUIScreen.main.screenshot().image).reduce(0, +)
            surface.pinch(withScale: 2.5, velocity: 1.5)
            let after = try await clickedX()
            let rendered = XCUIScreen.main.screenshot()
            let coverageAfter = Self.chartFractions(rendered.image).reduce(0, +)
            XCTAssertGreaterThan(coverageBefore, 0.2)
            XCTContext.runActivity(named: "Pinch enabled = \(allowsZoom), remote x = \(before) then \(after)") { activity in
                let screenshot = XCTAttachment(screenshot: rendered)
                screenshot.name = allowsZoom ? "Magnified desktop" : "Fitted desktop"
                screenshot.lifetime = .keepAlways
                activity.add(screenshot)
            }
            if allowsZoom {
                XCTAssertGreaterThan(coverageAfter - coverageBefore, 0.04)
                XCTAssertGreaterThan(after - before, 8, "Pinching should bring the sampled point nearer the center of the 160-pixel desktop.")
            } else {
                XCTAssertEqual(coverageAfter, coverageBefore, accuracy: 0.025)
                XCTAssertEqual(Double(after), Double(before), accuracy: 1)
            }
            app.terminate()
        }
    }

    func testRotatingAMagnifiedDesktopKeepsItsCenterAndClickMapping() async throws {
        let device = XCUIDevice.shared
        device.orientation = .portrait
        defer { device.orientation = .portrait }
        let desktop = LocalTestDisplay()
        var clicks: [CGPoint] = []
        desktop.onWirePointer = { buttons, point in
            if buttons & 1 != 0 { clicks.append(point) }
        }
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port)
        let surface = app.descendants(matching: .any)["session.input"].firstMatch
        try await waitUntil { desktop.frameCount > 0 && surface.isHittable && surface.frame.height > surface.frame.width }

        func sample(_ horizontal: CGFloat) async throws -> CGPoint {
            let next = clicks.count
            surface.coordinate(withNormalizedOffset: CGVector(dx: horizontal, dy: 0.5)).tap()
            try await waitUntil { clicks.count > next }
            return clicks[next]
        }

        let fittedCenter = try await sample(0.5)
        let fittedLeft = try await sample(0.25)
        let fittedDistance = fittedCenter.x - fittedLeft.x
        surface.pinch(withScale: 2.5, velocity: 1.5)
        let portraitCenter = try await sample(0.5)
        let portraitLeft = try await sample(0.25)
        XCTAssertLessThan(portraitCenter.x - portraitLeft.x, fittedDistance - 8)

        device.orientation = .landscapeLeft
        try await waitUntil { surface.isHittable && surface.frame.width > surface.frame.height }
        let landscapeCenter = try await sample(0.5)
        let landscapeLeft = try await sample(0.25)
        XCTAssertEqual(landscapeCenter.x, portraitCenter.x, accuracy: 2)
        XCTAssertEqual(landscapeCenter.y, portraitCenter.y, accuracy: 2)
        XCTAssertGreaterThan(landscapeCenter.x - landscapeLeft.x, 3)
        XCTAssertLessThan(landscapeCenter.x - landscapeLeft.x, fittedDistance - 5)

        let receipt = XCTAttachment(string: "Portrait center: \(portraitCenter)\nLandscape center: \(landscapeCenter)")
        receipt.name = "Remote pointer coordinates across rotation"
        receipt.lifetime = .keepAlways
        add(receipt)
    }

    func testMagnifiedDesktopKeepsItsViewportAfterBackgroundAuthentication() async throws {
        continueAfterFailure = false
        let device = XCUIDevice.shared
        device.orientation = .portrait
        let desktop = LocalTestDisplay()
        var clicks: [CGPoint] = []
        desktop.onWirePointer = { buttons, point in
            if buttons & 1 != 0 { clicks.append(point) }
        }
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        openProtectedChart(app, port: port)
        let input = app.descendants(matching: .any)["session.input"].firstMatch
        try await waitUntil { desktop.frameCount > 0 && input.isHittable && Self.hasColorChart(app.screenshot().image) }

        func sample(_ horizontal: CGFloat) async throws -> CGPoint {
            let index = clicks.count
            input.coordinate(withNormalizedOffset: .init(dx: horizontal, dy: 0.5)).tap()
            try await waitUntil { clicks.count > index }
            return clicks[index]
        }

        let fittedLeft = try await sample(0.25)
        input.pinch(withScale: 2.5, velocity: 1.5)
        let magnifiedLeft = try await sample(0.25)
        let magnifiedCenter = try await sample(0.5)
        XCTAssertGreaterThan(magnifiedLeft.x - fittedLeft.x, 8)
        let before = XCUIScreen.main.screenshot()

        device.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.activate()
        XCTAssertTrue(app.buttons["身份验证"].firstMatch.waitForExistence(timeout: 8))
        XCTAssertFalse(Self.hasColorChart(XCUIScreen.main.screenshot().image))
        tapCoveredAuthentication(in: app)
        try await waitUntil { input.isHittable && Self.hasColorChart(app.screenshot().image) }
        let resumedLeft = try await sample(0.25)
        let resumedCenter = try await sample(0.5)
        let after = XCUIScreen.main.screenshot()
        let receipt = XCTAttachment(string: "Fit: \(fittedLeft)\nMagnified: \(magnifiedLeft), \(magnifiedCenter)\nResumed: \(resumedLeft), \(resumedCenter)")
        receipt.name = "Remote positions before and after authentication"
        receipt.lifetime = .keepAlways
        add(receipt)
        let resumedPicture = XCTAttachment(screenshot: after)
        resumedPicture.name = "Magnified desktop after authentication"
        resumedPicture.lifetime = .keepAlways
        add(resumedPicture)
        XCTAssertEqual(resumedLeft.x, magnifiedLeft.x, accuracy: 2, "Unlocking reset the magnified desktop")
        XCTAssertEqual(resumedLeft.y, magnifiedLeft.y, accuracy: 2)
        XCTAssertEqual(resumedCenter.x, magnifiedCenter.x, accuracy: 2)
        XCTAssertEqual(resumedCenter.y, magnifiedCenter.y, accuracy: 2)
        XCTAssertEqual(Self.chartFractions(after.image).reduce(0, +), Self.chartFractions(before.image).reduce(0, +), accuracy: 0.035)
        XCTAssertEqual(desktop.acceptedConnections, 1)

        let closed = desktop.closedConnections
        desktop.expectsClientDisconnect = true
        app.buttons["session.close"].tap()
        try await waitUntil { desktop.closedConnections > closed && app.buttons["library.quick"].exists }
        desktop.expectsClientDisconnect = false
        connectChart(app, port: port)
        try await waitUntil { desktop.acceptedConnections == 2 && input.isHittable && Self.hasColorChart(app.screenshot().image) }
        let nextSessionLeft = try await sample(0.25)
        XCTAssertEqual(nextSessionLeft.x, fittedLeft.x, accuracy: 2)
        XCTAssertEqual(nextSessionLeft.y, fittedLeft.y, accuracy: 2)
    }

    func testObservationKeepsTheMagnifiedPictureAndBlocksRemotePointerInput() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let desktop = LocalTestDisplay()
        var clicks: [CGPoint] = []
        desktop.onWirePointer = { buttons, point in
            if buttons & 1 != 0 { clicks.append(point) }
        }
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port)
        let input = app.descendants(matching: .any)["session.input"].firstMatch
        let mode = app.buttons["session.mode"].firstMatch
        try await waitUntil { desktop.frameCount > 0 && input.isHittable && mode.isHittable && Self.hasColorChart(app.screenshot().image) }
        let toggle = app.buttons["toolbar.toggle"].firstMatch
        if toggle.exists, toggle.label == "隐藏工具栏" { toggle.tap() }

        func coverage() -> Double { Self.chartFractions(XCUIScreen.main.screenshot().image).reduce(0, +) }
        let fitCoverage = coverage()
        input.pinch(withScale: 2.5, velocity: 1.5)
        try await waitUntil { coverage() > fitCoverage + 0.08 }
        let zoomedCoverage = coverage()

        func sample() async throws -> CGPoint {
            let index = clicks.count
            input.coordinate(withNormalizedOffset: .init(dx: 0.28, dy: 0.5)).tap()
            try await waitUntil { clicks.count > index }
            return clicks[index]
        }
        let before = try await sample()
        let presses = clicks.count
        mode.tap()
        try await waitUntil { mode.label == "仅观察" && !input.exists && Self.hasColorChart(app.screenshot().image) }
        let observedCoverage = coverage()
        XCTAssertEqual(observedCoverage, zoomedCoverage, accuracy: 0.05, "Observation must retain the current magnification")
        app.coordinate(withNormalizedOffset: .init(dx: 0.28, dy: 0.54)).tap()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(clicks.count, presses)
        let picture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        picture.name = "Magnified read-only desktop"
        picture.lifetime = .keepAlways
        add(picture)

        mode.tap()
        try await waitUntil { mode.label == "控制" && input.isHittable }
        let after = try await sample()
        XCTAssertEqual(after.x, before.x, accuracy: 2)
        XCTAssertEqual(after.y, before.y, accuracy: 2)
        XCTAssertEqual(desktop.acceptedConnections, 1)
        let receipt = XCTAttachment(string: "Fit: \(fitCoverage)\nMagnified: \(zoomedCoverage)\nObservation: \(observedCoverage)\nPointer before and after: \(before), \(after)")
        receipt.name = "Viewport coverage and remote positions"
        receipt.lifetime = .keepAlways
        add(receipt)
    }

    func testHardwareControlReachesTheServerAsCommandWhenEnabledInTheEditor() async throws {
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.buttons["library.quick"].waitForExistence(timeout: 10))
        app.open(try XCTUnwrap(URL(string: "vnc://127.0.0.1:\(port)")))
        let form = app.collectionViews["connection.form"].firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 8))
        let display = app.buttons["显示器"].firstMatch
        guard reveal(display, in: form) else { XCTFail("Display options are not visible in the connection form."); return }
        display.tap()
        let swap = app.switches["connection.swapCommandControl"].firstMatch
        guard reveal(swap, in: form) else { XCTFail("The keyboard switch is not visible in the connection form."); return }
        XCTAssertEqual(swap.value as? String, "0")
        swap.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(swap.value as? String, "1")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Hardware keyboard settings"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["connection.submit"].tap()
        try await waitUntil { desktop.frameCount > 0 && app.buttons["session.info"].exists }
        app.descendants(matching: .any).matching(identifier: "session.input").firstMatch.tap()
        app.typeKey("x", modifierFlags: .control)
        try await waitUntil { desktop.keyDowns.contains(0x78) }
        XCTAssertEqual(Array(desktop.keyDowns.suffix(2)), [0xFFEB, 0x78])
        XCTAssertFalse(desktop.keyDowns.contains(0xFFE3))
    }

    func testIPadSessionKeyboardShortcutsActOnTheViewerAndRemoteDesktop() async throws {
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port)
        let surface = app.descendants(matching: .any).matching(identifier: "session.input").firstMatch
        try await waitUntil { desktop.frameCount > 0 && app.buttons["session.info"].exists }
        XCTAssertTrue(surface.waitForExistence(timeout: 5))
        surface.tap()
        let chord: XCUIElement.KeyModifierFlags = [.shift, .control, .command]
        app.typeKey("w", modifierFlags: chord)
        // This peer uses PC conventions. Close Window expands to Alt-F4.
        try await waitUntil { desktop.keyDowns.contains(0xFFC1) }
        XCTAssertTrue(desktop.keyDowns.contains(0xFFE9))
        XCTAssertFalse(desktop.keyDowns.contains(0x77))

        app.typeKey("r", modifierFlags: chord)
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"])).firstMatch
        guard cancel.waitForExistence(timeout: 30) else {
            XCTFail("The screenshot shortcut did not open the system export sheet.")
            return
        }
        cancel.tap()
        XCTAssertFalse(desktop.keyDowns.contains(0x72))
        app.typeKey("c", modifierFlags: chord)
        XCTAssertTrue(app.buttons["library.quick"].waitForExistence(timeout: 8))
        XCTAssertFalse(desktop.keyDowns.contains(0x63))
    }

    func testQuickConnectionCanBeFiledAsALinkWithoutSavingACustomComputer() async throws {
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port)
        try await waitUntil { desktop.frameCount > 0 && app.buttons["session.close"].exists }
        app.buttons["session.close"].tap()
        let entry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.computer.")).firstMatch
        let quick = app.buttons["library.quick"]
        XCTAssertTrue(quick.waitForExistence(timeout: 8))
        XCTAssertFalse(entry.exists)
        func selectPage(_ identifier: String) {
            let row = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
            if !row.isHittable {
                let sidebar = app.buttons.matching(NSPredicate(format: "label IN %@", ["显示边栏", "显示侧边栏", "Show Sidebar"])).firstMatch
                if sidebar.isHittable { sidebar.tap() }
            }
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.tap()
        }
        selectPage("library.links")
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        app.buttons["library.more"].tap()
        app.buttons["新建文件夹"].tap()
        let alert = app.alerts["新建文件夹"]
        let folder = "临时桌面"
        alert.textFields.firstMatch.tap()
        alert.textFields.firstMatch.typeText(folder)
        alert.buttons["保存"].tap()
        XCTAssertTrue(entry.waitForNonExistence(timeout: 5))
        selectPage("library.links")
        entry.press(forDuration: 0.8)
        app.buttons["移到链接文件夹"].tap()
        app.buttons[folder].firstMatch.tap()
        app.terminate()
        app.launch()
        selectPage("library.linkFolder." + folder)
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertTrue(entry.label.contains("127.0.0.1"))
    }

    func testAutomaticReconnectReportIdentifiesTheInterruptedTransport() async throws {
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port)
        let info = app.buttons["session.info"]
        try await waitUntil { info.exists && desktop.frameCount > 0 }
        let initialFrames = desktop.frameCount
        desktop.dropCurrentConnection()
        try await waitUntil { desktop.frameCount > initialFrames && info.isEnabled }
        info.tap()
        let trigger = app.descendants(matching: .any)["details.reconnect"].firstMatch
        try await waitUntil { trigger.value as? String == "传输连接中断" }
    }

    func testFirstPictureStatusWaitsForNewFramesAfterReconnect() async throws {
        let desktop = LocalTestDisplay()
        desktop.withholdFramesAfterConnection = 0
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port)
        let waiting = app.descendants(matching: .any)["session.waitingForScreen"].firstMatch
        let statusAction = app.buttons["session.statusAction"]
        try await waitUntil { waiting.exists && statusAction.exists }
        XCTAssertEqual(desktop.frameCount, 0)
        XCTAssertEqual(statusAction.label, "取消")
        attachToolbarScreenshot(app, name: "Waiting for the first remote picture")
        desktop.withholdFramesAfterConnection = nil
        try await waitUntil { !waiting.exists && desktop.frameCount > 0 }

        let mode = app.buttons["session.mode"]
        mode.tap()
        try await waitUntil { mode.label == "仅观察" }
        desktop.withholdFramesAfterConnection = 1
        let frames = desktop.frameCount
        desktop.dropCurrentConnection()
        try await waitUntil { desktop.acceptedConnections == 2 && waiting.exists }
        XCTAssertEqual(desktop.frameCount, frames)
        XCTAssertEqual(statusAction.label, "停止重新连接")
        XCTAssertTrue(Self.hasColorChart(app.screenshot().image))
        attachToolbarScreenshot(app, name: "Reconnecting while the old picture is still visible")
        desktop.withholdFramesAfterConnection = nil
        try await waitUntil { !waiting.exists && desktop.frameCount > frames }
        XCTAssertEqual(mode.label, "仅观察")

        desktop.withholdFramesAfterConnection = 2
        desktop.dropCurrentConnection()
        try await waitUntil { desktop.acceptedConnections == 3 && waiting.exists }
        statusAction.tap()
        XCTAssertTrue(app.buttons["session.reconnect"].waitForExistence(timeout: 8))
        XCTAssertFalse(waiting.exists)
        XCTAssertEqual(desktop.acceptedConnections, 3)
    }

    func testReconnectWaitsForFreshPictureBeforeRestoringDesktopInput() async throws {
        continueAfterFailure = false
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port)
        let input = app.descendants(matching: .any)["session.input"].firstMatch
        let control = app.buttons["toolbar.control"]
        let tab = app.buttons["toolbar.tab"]
        let waiting = app.descendants(matching: .any)["session.waitingForScreen"].firstMatch
        try await waitUntil { desktop.frameCount > 0 && input.isHittable && control.isHittable }
        control.tap()
        XCTAssertEqual(control.value as? String, "已选中")

        let previousFrames = desktop.frameCount
        let previousKeys = desktop.keyDowns
        let previousClicks = desktop.clicks
        desktop.withholdFramesAfterConnection = 1
        desktop.dropCurrentConnection()
        try await waitUntil { desktop.acceptedConnections == 2 && waiting.exists }
        XCTAssertEqual(desktop.frameCount, previousFrames)
        XCTAssertTrue(Self.hasColorChart(app.screenshot().image))
        XCTAssertFalse(input.exists)
        XCTAssertFalse(tab.isEnabled)
        XCTAssertEqual(app.buttons["session.statusAction"].label, "停止重新连接")
        app.coordinate(withNormalizedOffset: .init(dx: 0.23, dy: 0.38)).tap()
        if tab.isHittable { tab.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).tap() }
        app.typeKey("x", modifierFlags: [.control])
        attachToolbarScreenshot(app, name: "Previous picture with remote input paused")

        desktop.withholdFramesAfterConnection = nil
        try await waitUntil { desktop.frameCount > previousFrames && !waiting.exists && input.isHittable && tab.isEnabled }
        XCTAssertNotEqual(control.value as? String, "已选中")
        tab.tap()
        input.tap()
        try await waitUntil { desktop.keyDowns.count > previousKeys.count && desktop.clicks > previousClicks }
        XCTAssertEqual(desktop.keyDowns, previousKeys + [0xff09])
        XCTAssertEqual(desktop.clicks, previousClicks + 1)
        XCTAssertEqual(desktop.acceptedConnections, 2)
    }

    func testCancellingBeforeTheFirstPictureReturnsToTheLibrary() async throws {
        let desktop = LocalTestDisplay()
        desktop.expectsClientDisconnect = true
        desktop.withholdFramesAfterConnection = 0
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port)
        let waiting = app.descendants(matching: .any)["session.waitingForScreen"].firstMatch
        let cancel = app.buttons["session.statusAction"]
        try await waitUntil { waiting.exists && cancel.isHittable }
        cancel.tap()
        XCTAssertTrue(app.buttons["library.quick"].waitForExistence(timeout: 8))
        XCTAssertFalse(waiting.exists)
        XCTAssertFalse(app.buttons["session.reconnect"].exists)
        desktop.withholdFramesAfterConnection = nil
        try await waitUntil { desktop.closedConnections == 1 }
        XCTAssertEqual(desktop.acceptedConnections, 1)
    }

    func testManualReconnectAfterPeerClosesUsesTheSameOpenSession() async throws {
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port) {
            app.buttons["library.more"].tap()
            app.buttons["设置"].tap()
            let automatic = app.switches["自动重新连接"]
            XCTAssertEqual(automatic.value as? String, "1")
            automatic.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
            XCTAssertEqual(automatic.value as? String, "0")
            app.buttons["关闭"].tap()
        }
        let info = app.buttons["session.info"]
        try await waitUntil { info.exists && desktop.frameCount > 0 }
        desktop.dropCurrentConnection()
        let retry = app.buttons["session.reconnect"]
        XCTAssertTrue(retry.waitForExistence(timeout: 12))
        XCTAssertTrue(app.buttons["session.editConnection"].exists)
        let frames = desktop.frameCount
        retry.tap()
        try await waitUntil { info.exists && desktop.frameCount > frames && !retry.exists }
        XCTAssertFalse(app.textFields["connection.host"].exists)
        app.buttons["toolbar.tab"].tap()
        try await waitUntil { desktop.keyDowns.contains(0xFF09) }
        info.tap()
        try await waitUntil { app.descendants(matching: .any)["details.reconnect"].firstMatch.value as? String == "手动重试" }
    }
    #endif

    func testSharedClipboardDefaultAndManualReceiveUseOnlyTheCurrentSession() async throws {
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port)
        let menu = app.buttons["session.clipboard"]
        try await waitUntil { desktop.frameCount > 0 && menu.exists }
        func select(_ label: String) {
            menu.tap()
            app.buttons[label].firstMatch.tap()
        }
        func checkLocalClipboard(_ value: String) async throws {
            let previous = desktop.clipboardWrites
            select("发送剪贴板")
            try await waitUntil { desktop.clipboardWrites > previous && desktop.receivedClipboard == Data(value.utf8) }
        }
        try await desktop.publishClipboard("First remote copy")
        try await checkLocalClipboard("First remote copy")
        select("自动共享剪贴板")
        try await desktop.publishClipboard("Second remote copy")
        try await checkLocalClipboard("First remote copy")
        select("接收剪贴板")
        try await checkLocalClipboard("Second remote copy")
        app.buttons["session.mode"].tap()
        XCTAssertTrue(menu.waitForNonExistence(timeout: 5))
        app.buttons["session.mode"].tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        try await desktop.publishClipboard("Third remote copy")
        try await checkLocalClipboard("Second remote copy")
    }

    #if !targetEnvironment(macCatalyst)
    func testClipboardReturnsWhenAuthenticationFinishesBeforeTheReconnection() async throws {
        continueAfterFailure = false
        let desktop = LocalTestDisplay()
        desktop.expectsClientDisconnect = true
        let port = try await desktop.start()
        defer { desktop.stop() }

        let app = XCUIApplication()
        openProtectedChart(app, port: port)
        let authenticate = app.buttons["身份验证"].firstMatch
        let clipboard = app.buttons["session.clipboard"].firstMatch
        try await waitUntil { desktop.frameCount > 0 && clipboard.exists }

        desktop.withholdHandshakesAfterConnection = 1
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        desktop.dropCurrentConnection()
        try await waitUntil { desktop.closedConnections == 1 }
        app.activate()
        XCTAssertTrue(authenticate.waitForExistence(timeout: 8))
        try await waitUntil { desktop.acceptedConnections == 2 }
        let frameCount = desktop.frameCount
        XCTAssertFalse(clipboard.exists, "The privacy gate must remove clipboard controls")
        tapCoveredAuthentication(in: app)
        XCTAssertTrue(authenticate.waitForNonExistence(timeout: 6))
        XCTAssertEqual(desktop.frameCount, frameCount, "The replacement handshake is still held during unlock")

        desktop.withholdHandshakesAfterConnection = nil
        try await waitUntil { desktop.frameCount > frameCount }
        XCTAssertTrue(clipboard.waitForExistence(timeout: 6), "The connected desktop did not restore clipboard controls")
        let text = "Clipboard after reconnect"
        let writesBeforeSend = desktop.clipboardWrites
        try await desktop.publishClipboard(text)
        clipboard.tap()
        let send = app.buttons["发送剪贴板"].firstMatch
        XCTAssertTrue(send.wait(for: \.isEnabled, toEqual: true, timeout: 6))
        send.tap()
        try await waitUntil { desktop.clipboardWrites > writesBeforeSend && desktop.receivedClipboard == Data(text.utf8) }
        XCTAssertEqual(desktop.acceptedConnections, 2)
    }

    func testPinyinCandidateSendsOnlyCommittedCharactersToTheRemoteDesktop() async throws {
        guard ProcessInfo.processInfo.environment["DESKLINK_TEST_PINYIN"] == "1" else {
            throw XCTSkip("Requires an active Simplified Chinese Pinyin onscreen keyboard.")
        }
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.buttons["library.quick"].waitForExistence(timeout: 10))
        app.open(try XCTUnwrap(URL(string: "vnc://127.0.0.1:\(port)")))
        let submit = app.buttons["connection.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 8))
        submit.tap()
        let toggle = app.buttons["toolbar.keyboard"]
        try await waitUntil { desktop.frameCount > 0 && toggle.isHittable }
        try await selectPinyinGreeting(in: app) {
            XCTAssertEqual(desktop.keyDowns, [], "Uncommitted Pinyin reached the peer.")
        }
        let expected: [UInt32] = [0x0100_4F60, 0x0100_597D]
        try await waitUntil { desktop.keyDowns.count >= expected.count }
        XCTAssertEqual(desktop.keyDowns, expected)
        XCTAssertNil(desktop.failure)
        XCTContext.runActivity(named: "Selected 你好 after five system key taps, peer received only U+4F60 U+597D") { _ in }
        try await submitPinyinLine(in: app)
        try await waitUntil { desktop.keyDowns.count > expected.count }
        XCTAssertEqual(desktop.keyDowns, expected + [0xff0d])
    }

    func testRaspberryPiAuthenticationPickerHostFingerprintAndLiveEncryptionReport() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let address = env["DESKLINK_RSA_UI_TERMINAL"], let pin = env["DESKLINK_RSA_PIN"],
              var target = URLComponents(string: address) else { throw XCTSkip("Requires the paired RSA-AES desktop.") }
        target.user = "chartuser"
        target.password = "FixtureAccount71!"
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.buttons["library.quick"].waitForExistence(timeout: 10))
        app.open(try XCTUnwrap(target.url))
        let picker = app.buttons["connection.authentication"]
        XCTAssertTrue(picker.waitForExistence(timeout: 8))
        picker.tap()
        app.buttons["Raspberry Pi · RSA-AES"].firstMatch.tap()
        app.buttons["connection.submit"].tap()
        let identity = app.alerts.firstMatch
        XCTAssertTrue(identity.waitForExistence(timeout: 10))
        let fingerprint = identity.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", pin)).firstMatch
        guard fingerprint.exists else { return XCTFail("The approval dialog omitted the fixture host fingerprint") }
        let prompt = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        prompt.name = "RSA host fingerprint on iPad"
        prompt.lifetime = .keepAlways
        add(prompt)
        identity.buttons["记住主机指纹"].tap()
        let info = app.buttons["session.info"]
        try await waitUntil(timeout: 20) { info.exists && info.isEnabled }
        info.tap()
        let encryption = app.descendants(matching: .any).matching(identifier: "details.encryption").firstMatch
        try await waitUntil { encryption.value as? String == "RSA-AES-256" }
        let report = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        report.name = "Authenticated RSA-AES desktop and connection details"
        report.lifetime = .keepAlways
        add(report)
        app.buttons["details.done"].tap()
        app.buttons["session.close"].tap()
        try await waitUntil { app.buttons["library.quick"].exists }
    }

    func testSelectedPinyinCandidateArrivesInTheLinuxTerminal() async throws {
        guard let address = ProcessInfo.processInfo.environment["DESKLINK_TEST_PINYIN_TERMINAL"],
              var target = URLComponents(string: address) else { throw XCTSkip("Requires the isolated X11 Pinyin terminal.") }
        target.user = "fixture"
        target.password = "Chart42!"
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.buttons["library.quick"].waitForExistence(timeout: 10))
        app.open(try XCTUnwrap(target.url))
        let submit = app.buttons["connection.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 8))
        let form = app.collectionViews["connection.form"].firstMatch
        let display = app.buttons["显示器"].firstMatch
        guard reveal(display, in: form) else { return XCTFail("Could not reveal the display settings.") }
        display.tap()
        let compatibility = app.switches["connection.tigerKeyboard"].firstMatch
        guard reveal(compatibility, in: form) else { return XCTFail("Could not reveal the TigerVNC keyboard setting.") }
        XCTAssertEqual(compatibility.value as? String, "0")
        compatibility.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(compatibility.value as? String, "1")
        let setting = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        setting.name = "TigerVNC first key compatibility enabled"
        setting.lifetime = .keepAlways
        add(setting)
        submit.tap()
        try await waitUntil { app.buttons["toolbar.keyboard"].isHittable &&
            Self.chartFractions(XCUIScreen.main.screenshot().image).first.map { $0 > 0.10 } == true }
        try await selectPinyinGreeting(in: app)
        try await submitPinyinLine(in: app)
        // The terminal turns the X11 root green only on receiving the exact UTF-8 line.
        try await waitUntil {
            let colors = Self.chartFractions(XCUIScreen.main.screenshot().image)
            return colors.count == 4 && colors[2] > 0.04
        }
    }

    private func submitPinyinLine(in app: XCUIApplication) async throws {
        let enter = app.keyboards.firstMatch.descendants(matching: .any).matching(identifier: "Return").firstMatch
        try await waitUntil { enter.isHittable }
        enter.tap()
    }

    private func selectPinyinGreeting(in app: XCUIApplication, opensKeyboard: Bool = true,
                                      whileComposing: () -> Void = {}) async throws {
        if opensKeyboard { app.buttons["toolbar.keyboard"].tap() }
        let keyboard = app.keyboards.firstMatch
        try await waitUntil { keyboard.exists && keyboard.frame.height > 0 }
        for character in "nihao" {
            let key = keyboard.keys.matching(NSPredicate(format: "label ==[c] %@", String(character))).firstMatch
            try await waitUntil { key.exists && key.isHittable &&
                app.frame.contains(CGPoint(x: key.frame.midX, y: key.frame.midY)) }
            key.tap()
            whileComposing()
        }
        let candidate = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@ OR identifier == %@", "你好", "你好")).firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 6), "The system IME did not expose the expected candidate.")
        XCTAssertTrue(candidate.isHittable)
        whileComposing()
        candidate.tap()
    }

    func testUpwardSwipeOnKeyboardShortcutStripReachesRemoteBottomEdge() async throws {
        try await verifyKeyboardToolbarEdgeSwipe(floating: false)
    }

    func testUpwardSwipeOnFloatingKeyboardShortcutStripReachesRemoteBottomEdge() async throws {
        try await verifyKeyboardToolbarEdgeSwipe(floating: true)
    }

    private func verifyKeyboardToolbarEdgeSwipe(floating: Bool) async throws {
        let desktop = LocalTestDisplay(hasTwoMonitors: true)
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.buttons["library.quick"].waitForExistence(timeout: 10))
        if floating { selectToolbar("浮动", in: app) }
        app.open(try XCTUnwrap(URL(string: "vnc://127.0.0.1:\(port)")))
        let host = app.textFields["connection.host"]
        XCTAssertTrue(host.waitForExistence(timeout: 8))
        host.tap()
        let softwareKeyboard = app.keyboards.firstMatch
        XCTAssertTrue(softwareKeyboard.waitForExistence(timeout: 8))
        let letter = softwareKeyboard.keys.matching(NSPredicate(format: "label ==[c] %@ OR identifier ==[c] %@", "a", "a")).firstMatch
        let controlKey = letter.exists ? letter.frame : .zero
        XCTContext.runActivity(named: "Address field keyboard \(softwareKeyboard.frame), A \(controlKey)") { _ in }
        app.buttons["connection.submit"].tap()
        let monitors = app.buttons["session.monitors"]
        try await waitUntil { desktop.frameCount > 0 && monitors.isHittable }
        monitors.tap()
        app.buttons["显示器 2"].firstMatch.tap()
        let keyboard = app.buttons["toolbar.keyboard"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 6))
        keyboard.tap()
        XCTAssertTrue(softwareKeyboard.waitForExistence(timeout: 8))
        let tab = app.buttons["toolbar.tab"]
        func recordKeyboard(_ stage: String) {
            let keyFrame = letter.exists ? letter.frame : .zero
            XCTContext.runActivity(named: "\(stage) window \(app.frame), keyboard \(softwareKeyboard.frame), A \(keyFrame), Tab \(tab.frame)") { activity in
                let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                image.name = stage
                image.lifetime = .keepAlways
                activity.add(image)
            }
        }
        func hasVisibleKeyboard() -> Bool {
            guard letter.exists, letter.isHittable, app.frame.contains(CGPoint(x: letter.frame.midX, y: letter.frame.midY)),
                  tab.isHittable else { return false }
            return tab.frame.maxY <= letter.frame.minY
        }
        do { try await waitUntil { hasVisibleKeyboard() } }
        catch { recordKeyboard("Before swipe"); throw error }
        let start = tab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.03, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -110)),
                    withVelocity: .fast, thenHoldForDuration: 0)
        try await waitUntil { desktop.latestPointer.map { (80...159).contains($0.x) && $0.y == 95 } == true }
        let point = try XCTUnwrap(desktop.latestPointer)
        XCTAssertEqual(desktop.clicks, 0)
        XCTAssertEqual(desktop.keys, 0)
        recordKeyboard("After swipe")
        XCTAssertTrue(hasVisibleKeyboard())
        XCTContext.runActivity(named: "Keyboard strip moved remote pointer to \(Int(point.x)),\(Int(point.y))") { _ in }
        tab.tap()
        try await waitUntil { desktop.keyDowns == [0xff09] }
        let backspace = softwareKeyboard.keys.matching(NSPredicate(
            format: "identifier IN %@ OR label IN %@",
            ["delete", "Delete", "Backspace", "删除", "退格"], ["delete", "Delete", "Backspace", "删除", "退格"])).firstMatch
        XCTAssertTrue(backspace.exists && backspace.isHittable)
        backspace.tap()
        try await waitUntil { desktop.keyDowns == [0xff09, 0xff08] }
    }

    func testInwardEdgeAndCornerSwipesMoveToTheSelectedDisplayWithoutClicking() async throws {
        let desktop = LocalTestDisplay(hasTwoMonitors: true)
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port)
        let menu = app.buttons["session.monitors"]
        try await waitUntil { desktop.frameCount > 0 && menu.exists }
        menu.tap()
        app.buttons["显示器 2"].firstMatch.tap()
        let surface = app.descendants(matching: .any).matching(identifier: "session.input").firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 6))
        let frame = surface.frame
        let origin = app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: frame.minX - app.frame.minX, dy: frame.minY - app.frame.minY))
        let width = frame.width, height = frame.height
        func stroke(_ start: CGPoint, dx: CGFloat, dy: CGFloat) {
            let point = origin.withOffset(CGVector(dx: start.x, dy: start.y))
            point.press(forDuration: 0.03, thenDragTo: point.withOffset(CGVector(dx: dx, dy: dy)),
                        withVelocity: .fast, thenHoldForDuration: 0)
        }
        let left: CGFloat = 16, right = width - 16, top: CGFloat = 16, bottom = height - 16
        // The second display spans x = 80...159 and y = 0...95 in the combined framebuffer.
        let cases: [(CGPoint, CGFloat, CGFloat, ClosedRange<CGFloat>, ClosedRange<CGFloat>)] = [
            (CGPoint(x: right, y: height / 2), -96, 0, 159...159, 20...76),
            (CGPoint(x: left, y: height / 2), 96, 0, 80...80, 20...76),
            (CGPoint(x: width / 2, y: top), 0, 96, 100...140, 0...0),
            (CGPoint(x: width / 2, y: bottom), 0, -96, 100...140, 95...95),
            (CGPoint(x: left, y: bottom), 96, -96, 80...80, 95...95),
            (CGPoint(x: right, y: bottom), -96, -96, 159...159, 95...95),
            (CGPoint(x: left, y: top), 96, 96, 80...80, 0...0),
            (CGPoint(x: right, y: top), -96, 96, 159...159, 0...0)
        ]
        for (start, dx, dy, x, y) in cases {
            stroke(start, dx: dx, dy: dy)
            do {
                try await waitUntil { desktop.latestPointer.map { x.contains($0.x) && y.contains($0.y) } == true }
            } catch {
                XCTFail("Inward swipe from \(start) expected x \(x), y \(y); received \(String(describing: desktop.latestPointer)).")
                return
            }
            let point = try XCTUnwrap(desktop.latestPointer)
            XCTContext.runActivity(named: "Remote edge position \(Int(point.x)),\(Int(point.y))") { _ in }
        }
        XCTAssertEqual(desktop.clicks, 0)
        XCTAssertEqual(desktop.scrollTicks, 0)
        let mode = app.buttons["session.mode"]
        mode.tap()
        try await waitUntil { mode.label == "仅观察" }
        try await waitUntil { !surface.exists }
        let previous = desktop.latestPointer
        stroke(CGPoint(x: left, y: height / 2), dx: 96, dy: 0)
        XCTAssertTrue(mode.exists)
        XCTAssertEqual(desktop.latestPointer, previous)
        XCTAssertEqual(desktop.clicks, 0)
        XCTAssertEqual(desktop.scrollTicks, 0)
    }
    #endif

    #if !targetEnvironment(macCatalyst)
    func testAppleStandardCompressionChangesPixelsAndPreservesNativePointerCoordinates() async throws {
        for capability in [true, false] {
            let desktop = LocalTestDisplay(appleScalingCapability: capability)
            let port = try await desktop.start()
            defer {
                if let error = desktop.failure { XCTFail(error) }
                desktop.stop()
            }
            let app = XCUIApplication()
            app.launchArguments = ["--test-library", UUID().uuidString]
            app.launch()
            app.buttons["library.quick"].tap()
            applyLink("vnc://127.0.0.1:\(port)", in: app)
            let display = app.buttons["显示器"].firstMatch
            for _ in 0..<4 where !display.isHittable { app.swipeUp() }
            display.tap()
            func policy(_ id: String, _ choice: String) {
                let control = app.buttons[id]
                for _ in 0..<4 where !control.isHittable { app.swipeUp() }
                control.tap()
                app.buttons[choice].firstMatch.tap()
            }
            policy("connection.adaptiveQuality", "永不启用")
            policy("connection.tightCompression", "始终启用")
            app.buttons["connection.submit"].tap()
            try await waitUntil { desktop.frameCount > 0 || desktop.failure != nil }
            XCTAssertNil(desktop.failure)
            XCTAssertEqual(desktop.halfResolutionRequested, capability)
            let expected = capability ? CGSize(width: 160, height: 96) : CGSize(width: 320, height: 192)
            XCTAssertEqual(desktop.requestedFramebufferSize, expected)
            try await waitUntil { Self.hasColorChart(app.screenshot().image) }
            guard desktop.failure == nil else { return }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            try await waitUntil { desktop.clicks > 0 || desktop.failure != nil }
            XCTAssertNil(desktop.failure)
            XCTAssertEqual(try XCTUnwrap(desktop.lastClickX), 160, accuracy: 4)
            app.buttons["session.close"].tap()
        }
    }
    #endif

    func testTightJPEGQualityOnWireHonorsAlwaysAndRemoteOnlyOnLoopback() async throws {
        for (choice, compressed) in [("始终启用", true), ("仅远程连接时启用", false)] {
            let desktop = LocalTestDisplay(servesJPEG: true)
            let port = try await desktop.start()
            defer { desktop.stop() }
            let app = XCUIApplication()
            app.launchArguments = ["--test-library", UUID().uuidString]
            app.launch()
            app.buttons["library.quick"].tap()
            applyLink("vnc://127.0.0.1:\(port)", in: app)
            let display = app.buttons["显示器"].firstMatch
            for _ in 0..<4 where !display.isHittable { app.swipeUp() }
            XCTAssertTrue(display.isHittable)
            display.tap()
            let compression = app.buttons["connection.tightCompression"]
            for _ in 0..<4 where !compression.isHittable { app.swipeUp() }
            XCTAssertTrue(compression.isHittable)
            compression.tap()
            app.buttons[choice].firstMatch.tap()
            if compressed {
                let slider = app.sliders["connection.tightJPEGQuality"].firstMatch
                for _ in 0..<3 where !slider.isHittable { app.swipeUp() }
                XCTAssertTrue(slider.isEnabled)
                slider.adjust(toNormalizedSliderPosition: 1)
            }
            app.buttons["connection.submit"].tap()
            try await waitUntil { desktop.frameCount > 0 }
            XCTAssertTrue(desktop.advertisedEncodings.contains(7))
            let qualityEncodings = desktop.advertisedEncodings.filter { (-32 ... -23).contains($0) }
            XCTAssertEqual(qualityEncodings, compressed ? [-23] : [])
            try await waitUntil { Self.hasColorChart(app.screenshot().image) }
            app.buttons["session.close"].tap()
        }
    }

    func testControlAndObservationAgainstLoopbackDesktop() async throws {
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        let quick = app.buttons["library.quick"]
        openChart(app, port: port)
        let mode = app.buttons["session.mode"]
        try await waitUntil { mode.exists && desktop.frameCount > 0 }
        XCTAssertNil(desktop.failure)
        try await waitUntil { Self.hasColorChart(app.screenshot().image) }
        let chart = XCTAttachment(screenshot: app.screenshot())
        chart.name = "Remote chart in control mode"
        chart.lifetime = .keepAlways
        add(chart)
        let point = app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5))
        point.tap()
        try await waitUntil { desktop.clicks > 0 }
        mode.tap()
        try await waitUntil { mode.label == "仅观察" }
        let previous = desktop.clicks
        point.tap()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(desktop.clicks, previous)
        XCTAssertTrue(Self.hasColorChart(app.screenshot().image))
        app.buttons["session.close"].tap()
        XCTAssertTrue(quick.waitForExistence(timeout: 5))
    }

    #if !targetEnvironment(macCatalyst)
    func testHoldDelayChangesWhetherTheSameFingerMotionDragsOrScrolls() async throws {
        for shortDelay in [true, false] {
            let desktop = LocalTestDisplay()
            let port = try await desktop.start()
            defer { desktop.stop() }
            let app = XCUIApplication()
            openChart(app, port: port) {
                app.buttons["library.more"].tap()
                app.buttons["设置"].firstMatch.tap()
                let slider = app.sliders["preferences.dragDelay"]
                for _ in 0..<6 where !slider.isHittable { app.swipeUp() }
                XCTAssertTrue(slider.isHittable)
                slider.adjust(toNormalizedSliderPosition: shortDelay ? 0 : 1)
                app.buttons["关闭"].firstMatch.tap()
            }
            try await waitUntil { desktop.frameCount > 0 && app.buttons["session.mode"].exists }
            let point = app.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.42))
            point.press(forDuration: 0.42, thenDragTo: point.withOffset(CGVector(dx: 100, dy: 165)))
            if shortDelay {
                try await waitUntil { desktop.heldLeftX.count >= 2 }
            } else {
                try await waitUntil { desktop.scrollTicks > 0 }
                XCTAssertTrue(desktop.heldLeftX.isEmpty)
            }
            app.buttons["session.close"].tap()
        }
    }

    func testDraggingToTheNearbyDownloadTargetRequestsOnlyTheChosenFile() async throws {
        continueAfterFailure = false
        let desktop = LocalTestDisplay(appleScalingCapability: false, offersDraggedFile: true)
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port)
        try await waitUntil { desktop.frameCount > 0 && app.buttons["session.mode"].exists }
        let file = app.coordinate(withNormalizedOffset: CGVector(dx: 0.48, dy: 0.57))
        let outside = file.withOffset(CGVector(dx: 24, dy: 160))
        file.press(forDuration: 1.2, thenDragTo: outside, withVelocity: .slow, thenHoldForDuration: 0.4)
        try await waitUntil { desktop.heldLeftX.count > 1 }
        XCTAssertEqual(desktop.downloadRequests, 0)
        let target = file.withOffset(CGVector(dx: 78, dy: -44))
        file.press(forDuration: 1.2, thenDragTo: target, withVelocity: .fast, thenHoldForDuration: 0)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertNil(desktop.failure)
        XCTAssertEqual(desktop.downloadRequests, 0, "Releasing immediately on the target must not start a download")
        file.press(forDuration: 1.2, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 0.4)
        try await waitUntil { desktop.downloadRequests == 1 || desktop.failure != nil }
        XCTAssertNil(desktop.failure)
        XCTAssertEqual(desktop.downloadRequests, 1)
    }

    func testDraggedDownloadContinuesAfterLeavingTheApp() async throws {
        try await verifyBackgroundDownload(requiresAuthentication: false)
    }

    func testStartedDownloadFinishesWhileAppRequiresAuthentication() async throws {
        try await verifyBackgroundDownload(requiresAuthentication: true)
    }

    private func verifyBackgroundDownload(requiresAuthentication: Bool) async throws {
        continueAfterFailure = false
        let desktop = LocalTestDisplay(appleScalingCapability: false, offersDraggedFile: true, completesDraggedFile: true)
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        if requiresAuthentication {
            openProtectedChart(app, port: port)
        } else {
            openChart(app, port: port)
        }
        try await waitUntil { desktop.frameCount > 0 && app.buttons["session.mode"].exists }
        let file = app.coordinate(withNormalizedOffset: CGVector(dx: 0.48, dy: 0.57))
        let target = file.withOffset(CGVector(dx: 78, dy: -44))
        file.press(forDuration: 1.2, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 0.4)
        try await waitUntil { desktop.startedFileStreams == 1 || desktop.failure != nil }
        XCTAssertNil(desktop.failure)
        XCTAssertEqual(desktop.startedFileStreams, 1)

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        try await Task.sleep(for: .seconds(9))
        let remainingBytesReleasedAt = Date().timeIntervalSince1970
        desktop.maySendRemainingFileBytes = true
        try await waitUntil { desktop.finishedFileStreams == 1 || desktop.failure != nil }
        XCTAssertNil(desktop.failure)
        XCTAssertEqual(desktop.finishedFileStreams, 1)
        XCTAssertEqual(app.state, .runningBackground)
        guard requiresAuthentication else { return }
        // Leave a window in which the simulator host can verify the received
        // file before foregrounding the viewer to inspect its privacy gate.
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(app.state, .runningBackground)
        let receipt = XCTAttachment(string: "\(remainingBytesReleasedAt)\n\(Date().timeIntervalSince1970)\n")
        receipt.name = "Background transfer sample window"
        receipt.lifetime = .keepAlways
        add(receipt)
        app.activate()
        let authenticate = app.buttons["身份验证"].firstMatch
        XCTAssertTrue(authenticate.waitForExistence(timeout: 8))
        let screenshot = XCUIScreen.main.screenshot()
        let lockedScreen = XCTAttachment(screenshot: screenshot)
        lockedScreen.name = "Privacy gate after background transfer"
        lockedScreen.lifetime = .keepAlways
        add(lockedScreen)
        XCTAssertFalse(Self.hasColorChart(screenshot.image))
        XCTAssertFalse(app.staticTexts["Gesture.txt"].exists)
        tapCoveredAuthentication(in: app)
        let controls = app.buttons["远程桌面控制"].firstMatch
        XCTAssertTrue(controls.waitForExistence(timeout: 8))
        controls.tap()
        app.buttons["文件传输"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Gesture.txt"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["已取消"].exists, "The app lock cancelled an already-started transfer")
        XCTAssertTrue(app.buttons["存储到“文件”"].waitForExistence(timeout: 5))
        XCTAssertEqual(desktop.acceptedConnections, 1)
        attachToolbarScreenshot(app, name: "Completed transfer after unlocking")
    }

    private func openProtectedChart(_ app: XCUIApplication, port: UInt16) {
        app.launchArguments = ["--test-library", UUID().uuidString, "-AppleLanguages", "(zh-Hans)",
                               "-privacy.deviceAuthentication", "YES"]
        app.launchEnvironment["DESKLINK_TEST_MANUAL_AUTHENTICATION"] = "1"
        app.launch()
        let authenticate = app.buttons["身份验证"].firstMatch
        XCTAssertTrue(authenticate.waitForExistence(timeout: 10))
        authenticate.tap()
        connectChart(app, port: port)
    }

    private func tapCoveredAuthentication(in app: XCUIApplication) {
        // The privacy gate is also hosted in a higher UIWindow. Accessibility
        // can report the underlying button even while that window covers it.
        let frame = app.buttons["身份验证"].firstMatch.frame
        let appFrame = app.frame
        XCTAssertTrue(appFrame.contains(CGPoint(x: frame.midX, y: frame.midY)))
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(.init(dx: frame.midX - appFrame.minX, dy: frame.midY - appFrame.minY)).tap()
    }

    func testConnectionDragDelayOverridesTheApplicationDefault() async throws {
        for shortDelay in [true, false] {
            let desktop = LocalTestDisplay()
            let port = try await desktop.start()
            defer { desktop.stop() }
            let app = XCUIApplication()
            app.launchArguments = ["--test-library", UUID().uuidString]
            app.launch()
            app.buttons["library.quick"].tap()
            applyLink("vnc://127.0.0.1:\(port)", in: app)
            let display = app.buttons["显示器"].firstMatch
            for _ in 0..<4 where !display.isHittable { app.swipeUp() }
            display.tap()
            let toggle = app.switches["connection.customDragDelay"].firstMatch
            for _ in 0..<8 where !toggle.isHittable { app.swipeUp() }
            XCTAssertEqual(toggle.value as? String, "0")
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            XCTAssertEqual(toggle.value as? String, "1")
            let slider = app.sliders["connection.dragDelay"]
            for _ in 0..<3 where !slider.isHittable { app.swipeUp() }
            slider.adjust(toNormalizedSliderPosition: shortDelay ? 0 : 1)
            app.buttons["connection.submit"].tap()
            try await waitUntil { desktop.frameCount > 0 && app.buttons["session.mode"].exists }
            let point = app.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.42))
            point.press(forDuration: 0.42, thenDragTo: point.withOffset(CGVector(dx: 100, dy: 165)))
            if shortDelay {
                try await waitUntil { desktop.heldLeftX.count >= 2 }
            } else {
                try await waitUntil { desktop.scrollTicks > 0 }
                XCTAssertTrue(desktop.heldLeftX.isEmpty)
            }
            app.buttons["session.close"].tap()
        }
    }

    func testConnectionDetailsCountInputWrittenToTheDesktop() async throws {
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port)
        let info = app.buttons["session.info"]
        try await waitUntil { info.exists && desktop.frameCount > 0 }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)).tap()
        try await waitUntil { desktop.clicks > 0 }
        app.buttons["toolbar.tab"].tap()
        try await waitUntil { desktop.keyDowns == [0xFF09] }
        info.tap()
        func detail(_ name: String) -> String? {
            let row = app.descendants(matching: .any).matching(identifier: "details." + name).firstMatch
            return row.exists ? row.value as? String : nil
        }
        try await waitUntil { detail("encoding") == "Raw" }
        XCTAssertEqual(detail("protocol"), "RFB 3.8")
        XCTAssertEqual(detail("dimensions"), "160 × 96")
        XCTAssertEqual(detail("encryption"), "未加密")
        XCTAssertGreaterThanOrEqual(Int(detail("pointer") ?? "") ?? 0, 2)
        XCTAssertEqual(Int(detail("keys") ?? ""), 2)
        XCTAssertGreaterThan(Int(detail("frames") ?? "") ?? 0, 0)
        app.buttons["details.done"].tap()
        app.buttons["session.close"].tap()
        try await waitUntil { app.buttons["library.quick"].exists }
        app.terminate()
        app.launch()
        let recent = app.staticTexts["最近连接"].firstMatch
        if !recent.isHittable {
            let sidebar = app.buttons.matching(NSPredicate(format: "label IN %@", ["显示边栏", "显示侧边栏", "Show Sidebar"])).firstMatch
            if sidebar.isHittable { sidebar.tap() }
        }
        recent.tap()
        let entry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.computer.")).firstMatch
        entry.press(forDuration: 0.8)
        app.buttons["上次连接信息"].tap()
        try await waitUntil { detail("date") != nil }
        XCTAssertEqual(detail("encoding"), "Raw")
        XCTAssertEqual(detail("dimensions"), "160 × 96")
        XCTAssertEqual(detail("keys"), "2")
        XCTAssertGreaterThanOrEqual(Int(detail("pointer") ?? "") ?? 0, 2)
        app.buttons["details.done"].tap()
    }

    func testMonitorKeyboardShortcutsSelectWithoutSendingDigitsToDesktop() async throws {
        let desktop = LocalTestDisplay(hasTwoMonitors: true)
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port)
        let menu = app.buttons["session.monitors"]
        try await waitUntil { desktop.frameCount > 0 && menu.exists }
        let surface = app.descendants(matching: .any).matching(identifier: "session.input").firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 5))
        surface.tap()
        app.typeKey("2", modifierFlags: [.control, .shift])
        try await waitUntil { Self.hasColorChart(app.screenshot().image, minimumFraction: 0.04, visible: [1, 3]) }
        app.typeKey("0", modifierFlags: [.control, .shift])
        try await waitUntil { Self.hasColorChart(app.screenshot().image, minimumFraction: 0.04) }
        XCTAssertTrue(Set(desktop.keyDowns).isDisjoint(with: [0x30, 0x32, 0x29, 0x40]))
        app.buttons["session.close"].tap()
    }

    func testSwitchMonitorCropsThePictureAndMapsInputToTheSameMonitor() async throws {
        let desktop = LocalTestDisplay(hasTwoMonitors: true)
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port)
        let menu = app.buttons["session.monitors"]
        let mode = app.buttons["session.mode"]
        try await waitUntil { desktop.frameCount > 0 && menu.exists }
        try await waitUntil { Self.hasColorChart(app.screenshot().image, minimumFraction: 0.04, visible: [0, 2]) }
        let target = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        target.tap()
        try await waitUntil { desktop.lastClickX.map { (0..<80).contains($0) } == true }
        menu.tap()
        app.buttons["显示器 2"].firstMatch.tap()
        try await waitUntil { Self.hasColorChart(app.screenshot().image, minimumFraction: 0.04, visible: [1, 3]) }
        target.tap()
        try await waitUntil { desktop.lastClickX.map { (80..<160).contains($0) } == true }
        mode.tap()
        try await waitUntil { mode.label == "仅观察" }
        XCTAssertTrue(Self.hasColorChart(app.screenshot().image, minimumFraction: 0.04, visible: [1, 3]))
        let before = desktop.clicks
        menu.tap()
        app.buttons["所有显示器"].firstMatch.tap()
        try await waitUntil { Self.hasColorChart(app.screenshot().image, minimumFraction: 0.04) }
        target.tap()
        XCTAssertEqual(desktop.clicks, before)
        app.buttons["session.close"].tap()
    }

    func testSharedMacAccessLinksOpenWithTheExternalPortOnTheCorrectService() throws {
        let env = ProcessInfo.processInfo.environment
        let json = env["DESKLINK_MAC_ACCESS_LINKS"] ?? #"{"ssh":"desklink://[2001:db8::10]?ssh=42422","direct":"desklink://[2001:db8::10]:42422"}"#
        let links = try JSONDecoder().decode([String: URL].self, from: Data(json.utf8))
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.buttons["library.quick"].waitForExistence(timeout: 10))
        for kind in ["direct", "ssh"] {
            app.open(try XCTUnwrap(links[kind]))
            let host = app.textFields["connection.host"]
            XCTAssertTrue(host.waitForExistence(timeout: 10))
            XCTAssertEqual(host.value as? String, "2001:db8::10")
            XCTAssertEqual(app.textFields["connection.port"].value as? String, kind == "ssh" ? "5900" : "42422")
            if kind == "ssh" {
                let port = app.textFields["connection.sshPort"]
                for _ in 0..<4 where !port.exists { app.swipeUp() }
                XCTAssertEqual(port.value as? String, "42422")
            }
            app.buttons["取消"].firstMatch.tap()
            XCTAssertTrue(app.buttons["library.quick"].waitForExistence(timeout: 8))
        }
    }

    func testSystemVNCAndSSHLinksOpenTheCorrespondingConnectionForms() async throws {
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.buttons["library.quick"].waitForExistence(timeout: 10))

        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let url = try XCTUnwrap(URL(string: "vnc://127.0.0.1:\(port)?observe=1"))
        app.open(url)
        let submit = app.buttons["connection.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["connection.port"].value as? String, String(port))
        XCTAssertEqual(desktop.frameCount, 0)
        submit.tap()
        try await waitUntil { desktop.frameCount > 0 && app.buttons["session.mode"].exists }
        XCTAssertEqual(app.buttons["session.mode"].label, "仅观察")
        app.buttons["session.close"].tap()
        XCTAssertTrue(app.buttons["library.quick"].waitForExistence(timeout: 10))

        for scheme in ["ssh", "screens-ssh"] {
            app.open(try XCTUnwrap(URL(string: scheme + "://reader@studio.fixture.invalid:2203")))
            XCTAssertTrue(submit.waitForExistence(timeout: 10))
            XCTAssertEqual(app.textFields["connection.host"].value as? String, "studio.fixture.invalid")
            XCTAssertEqual(app.textFields["connection.port"].value as? String, "5900")
            let sshPort = app.textFields["connection.sshPort"]
            for _ in 0..<4 where !sshPort.exists { app.swipeUp() }
            XCTAssertEqual(sshPort.value as? String, "2203")
            let sshUser = app.textFields["connection.sshUsername"]
            for _ in 0..<4 where !sshUser.exists { app.swipeUp() }
            XCTAssertEqual(sshUser.value as? String, "reader")
            app.buttons["取消"].firstMatch.tap()
            XCTAssertTrue(app.buttons["library.quick"].waitForExistence(timeout: 8))
        }
    }

    func testSharedLinksOpenTheSelectedAuthenticationFormBeforeConnecting() async throws {
        continueAfterFailure = false
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.buttons["library.quick"].waitForExistence(timeout: 10))
        let submit = app.buttons["connection.submit"].firstMatch
        let username = app.textFields["connection.username"].firstMatch
        let password = app.secureTextFields["connection.password"].firstMatch

        func open(_ authentication: String) throws {
            let url = try XCTUnwrap(URL(string: "desklink://127.0.0.1:\(port)?observe=true&auth=\(authentication)"))
            app.open(url)
            XCTAssertTrue(submit.waitForExistence(timeout: 8))
            XCTAssertEqual(app.textFields["connection.port"].value as? String, String(port))
            XCTAssertEqual(desktop.acceptedConnections, 0)
        }
        func cancel() {
            app.buttons["取消"].firstMatch.tap()
            XCTAssertTrue(app.buttons["library.quick"].waitForExistence(timeout: 8))
        }

        try open("mac-user")
        XCTAssertTrue(username.exists)
        XCTAssertTrue(password.exists)
        XCTAssertFalse(submit.isEnabled)
        cancel()

        try open("vnc-password")
        XCTAssertFalse(username.exists)
        XCTAssertTrue(password.exists)
        cancel()

        try open("raspberry-pi")
        XCTAssertTrue(username.exists)
        XCTAssertTrue(password.exists)
        cancel()

        try open("none")
        XCTAssertFalse(username.exists)
        XCTAssertFalse(password.exists)
        submit.tap()
        let mode = app.buttons["session.mode"].firstMatch
        try await waitUntil {
            desktop.frameCount > 0 && mode.label == "仅观察" && Self.hasColorChart(app.screenshot().image)
        }
        XCTAssertEqual(desktop.acceptedConnections, 1)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Shared no-auth connection in observation mode"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testQuickLinkKeepsObservationModeAndWaitsForExplicitConnection() async throws {
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        app.buttons["library.quick"].tap()
        applyLink("vnc://127.0.0.1:\(port)?observe=1", in: app)
        let host = app.textFields["connection.host"]
        try await waitUntil { host.value as? String == "127.0.0.1" }
        XCTAssertEqual(app.textFields["connection.port"].value as? String, String(port))
        XCTAssertEqual(desktop.frameCount, 0)
        app.buttons["connection.submit"].tap()
        let mode = app.buttons["session.mode"]
        try await waitUntil { desktop.frameCount > 0 && mode.label == "仅观察" }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)).tap()
        XCTAssertEqual(desktop.clicks, 0)
        app.buttons["session.close"].tap()
    }

    func testSavedHostLinkUsesItsNonDefaultPortFromQuickConnect() async throws {
        continueAfterFailure = false
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        XCTAssertNotEqual(port, 5900)
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString, "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let quick = app.buttons["library.quick"].firstMatch
        XCTAssertTrue(quick.waitForExistence(timeout: 10))

        let create = app.buttons["library.new"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 8))
        create.tap()
        let authentication = app.buttons["connection.authentication"].firstMatch
        XCTAssertTrue(authentication.waitForExistence(timeout: 8))
        authentication.tap()
        app.buttons["无认证"].firstMatch.tap()
        let name = "Saved render station"
        let nameField = app.textFields["connection.name"].firstMatch
        nameField.tap()
        nameField.typeText(name)
        let hostField = app.textFields["connection.host"].firstMatch
        hostField.tap()
        hostField.typeText("127.0.0.1:\(port)")
        app.buttons["connection.submit"].firstMatch.tap()
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                      "library.computer.", name)).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 8))

        quick.tap()
        applyLink("screens://127.0.0.1?observe=1", in: app)
        let form = app.navigationBars[name]
        XCTAssertTrue(form.waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["connection.host"].firstMatch.value as? String, "127.0.0.1")
        XCTAssertEqual(app.textFields["connection.port"].firstMatch.value as? String, String(port))
        XCTAssertEqual(desktop.acceptedConnections, 0)

        app.buttons["connection.submit"].firstMatch.tap()
        try await waitUntil { desktop.frameCount > 0 && app.buttons["session.mode"].firstMatch.label == "仅观察" }
        XCTAssertEqual(desktop.acceptedConnections, 1)
        app.buttons["session.close"].firstMatch.tap()
        XCTAssertTrue(quick.waitForExistence(timeout: 8))
    }

    func testChangingTheTargetClearsOnlyThePasswordFromTheLink() async throws {
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.buttons["library.quick"].waitForExistence(timeout: 10))
        app.open(try XCTUnwrap(URL(string: "vnc://reader:fixture@host.invalid:5910")))
        let host = app.textFields["connection.host"]
        try await waitUntil { host.value as? String == "host.invalid" }
        XCTAssertEqual(app.textFields["connection.username"].value as? String, "reader")
        let password = app.secureTextFields["connection.password"]
        let filled = try XCTUnwrap(password.value as? String)
        XCTAssertTrue(filled.contains("•"))
        XCTAssertEqual(app.switches["connection.remember"].value as? String, "0")
        host.tap()
        host.typeText("x")
        try await waitUntil { (password.value as? String)?.contains("•") != true }
        XCTAssertEqual(app.textFields["connection.username"].value as? String, "reader")
    }

    func testHoldingToolbarTabObeysTheRepeatSetting() async throws {
        for enabled in [true, false] {
            let desktop = LocalTestDisplay()
            let port = try await desktop.start()
            defer { desktop.stop() }
            let app = XCUIApplication()
            openChart(app, port: port) {
                if !enabled {
                    app.buttons["library.more"].tap()
                    app.buttons["设置"].firstMatch.tap()
                    let settings = app.buttons["preferences.keyRepeat"]
                    let navbar = app.navigationBars["设置"]
                    XCTAssertTrue(navbar.waitForExistence(timeout: 5))
                    let top = navbar.frame.maxY
                    let center = navbar.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 1))
                        .withOffset(.init(dx: 0, dy: 260))
                    for _ in 0..<8 {
                        if settings.exists, (top + 25...top + 420).contains(settings.frame.midY), settings.isHittable { break }
                        let step = settings.exists && settings.frame.midY < top + 25 ? 130 : -130
                        center.press(forDuration: 0.15, thenDragTo: center.withOffset(.init(dx: 0, dy: CGFloat(step))),
                                     withVelocity: .slow, thenHoldForDuration: 0.15)
                    }
                    settings.tap()
                    let toggle = app.switches["repeat.enabled"]
                    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
                    toggle.coordinate(withNormalizedOffset: .init(dx: 0.94, dy: 0.5)).tap()
                    XCTAssertEqual(toggle.value as? String, "0")
                    app.navigationBars["键盘重复"].buttons.firstMatch.tap()
                    app.buttons["关闭"].firstMatch.tap()
                }
            }
            let key = app.buttons["toolbar.tab"]
            try await waitUntil { desktop.frameCount > 0 && key.isHittable }
            key.press(forDuration: 0.75)
            try await waitUntil { !desktop.keyDowns.isEmpty }
            let repeats = desktop.keyDowns.filter { $0 == 0xff09 }.count
            if enabled { XCTAssertGreaterThanOrEqual(repeats, 3) } else { XCTAssertEqual(repeats, 1) }
            try await Task.sleep(for: .milliseconds(180))
            XCTAssertEqual(desktop.keyDowns.count, repeats)
            app.terminate()
        }
    }

    func testInteractiveToolbarSendsControlTabOnceAndRestoresAfterHiding() async throws {
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port)
        try await waitUntil { desktop.frameCount > 0 && app.buttons["session.mode"].exists }
        let control = app.buttons["toolbar.control"]
        let tab = app.buttons["toolbar.tab"]
        XCTAssertTrue(control.waitForExistence(timeout: 8))
        control.tap()
        tab.tap()
        try await waitUntil { desktop.keyDowns == [0xFFE3, 0xFF09] }
        tab.tap()
        try await waitUntil { desktop.keyDowns == [0xFFE3, 0xFF09, 0xFF09] }
        app.buttons["toolbar.toggle"].tap()
        XCTAssertTrue(tab.waitForNonExistence(timeout: 5))
        app.buttons["toolbar.show"].tap()
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        let result = XCTAttachment(screenshot: app.screenshot())
        result.name = "iPad docked toolbar"
        result.lifetime = .keepAlways
        add(result)
        app.buttons["session.close"].tap()
    }

    func testFnToolbarSendsNavigationWithTheExistingModifierAndKeyboardPaths() async throws {
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString, "-toolbar.iPad.style", "docked",
                               "-toolbar.iPad.buttons", "fn,left,right,up,down,shift"]
        app.launch()
        connectChart(app, port: port)
        let fn = app.buttons["toolbar.fn"]
        try await waitUntil { desktop.frameCount > 0 && fn.isHittable }

        fn.tap()
        app.buttons["toolbar.left"].tap()
        app.buttons["toolbar.left"].tap()
        try await waitUntil { desktop.keyDowns == [0xff50, 0xff51] }

        app.buttons["toolbar.shift"].tap()
        fn.tap()
        app.buttons["toolbar.up"].tap()
        fn.tap()
        app.buttons["toolbar.down"].tap()
        fn.tap()
        app.buttons["toolbar.right"].tap()
        try await waitUntil { desktop.keyDowns == [0xff50, 0xff51, 0xffe1, 0xff55, 0xff56, 0xff57] }

        app.buttons["toolbar.keyboard"].tap()
        let softwareKeyboard = app.keyboards.firstMatch
        let deleteLabels = ["delete", "Delete", "Backspace", "删除", "退格"]
        let backspace = softwareKeyboard.keys.matching(NSPredicate(
            format: "identifier IN %@ OR label IN %@", deleteLabels, deleteLabels)).firstMatch
        try await waitUntil { softwareKeyboard.frame.height > 0 && backspace.isHittable && fn.isHittable }
        fn.tap()
        backspace.tap()
        try await waitUntil { desktop.keyDowns.count >= 7 }
        XCTAssertEqual(desktop.keyDowns, [0xff50, 0xff51, 0xffe1, 0xff55, 0xff56, 0xff57, 0xffff])
        app.buttons["toolbar.keyboard"].tap()
        attachToolbarScreenshot(app, name: "iPad Fn toolbar on a live desktop")
    }

    func testPhoneLandscapeDocksToolbarBesideTheLiveDesktop() async throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "Requires the iPhone toolbar")
        continueAfterFailure = false
        let device = XCUIDevice.shared
        device.orientation = .portrait
        defer { device.orientation = .portrait }

        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port)
        let input = app.descendants(matching: .any)["session.input"].firstMatch
        let rail = app.descendants(matching: .any)["toolbar.leadingDock"].firstMatch
        let tab = app.buttons["toolbar.tab"].firstMatch
        let keyboard = app.buttons["toolbar.keyboard"].firstMatch
        try await waitUntil { desktop.frameCount > 0 && tab.isHittable && input.isHittable }
        XCTAssertFalse(rail.exists)
        XCTAssertEqual(tab.frame.midY, keyboard.frame.midY, accuracy: 4)
        let initialConnections = desktop.acceptedConnections
        var points: [CGPoint] = []
        desktop.onWirePointer = { mask, point in
            if mask & 1 != 0 { points.append(point) }
        }

        func tapDesktopCenter() async throws {
            let before = points.count
            input.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).tap()
            try await waitUntil { points.count > before }
            let point = try XCTUnwrap(points.last)
            XCTAssertEqual(point.x, 80, accuracy: 4)
            XCTAssertEqual(point.y, 48, accuracy: 4)
        }

        func sideLayoutIsReady() -> Bool {
            rail.exists && tab.exists && input.exists
                && abs(tab.frame.midX - keyboard.frame.midX) < 4
                && rail.frame.maxX <= input.frame.minX + 2
        }

        func rotate(to orientation: UIDeviceOrientation) async throws {
            device.orientation = orientation
            // UIKit can still report in-flight accessibility frames immediately
            // after XCTest acknowledges a new device orientation.
            try await Task.sleep(for: .milliseconds(600))
        }

        try await tapDesktopCenter()
        try await rotate(to: .landscapeLeft)
        try await waitUntil { sideLayoutIsReady() }
        XCTAssertGreaterThan(tab.frame.midY, keyboard.frame.midY)
        tab.tap()
        try await waitUntil { desktop.keyDowns == [0xFF09] }
        try await tapDesktopCenter()
        let toolbarShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        toolbarShot.name = "iPhone landscape toolbar and remote desktop"
        toolbarShot.lifetime = .keepAlways
        add(toolbarShot)

        let functions = app.buttons["toolbar.functions"].firstMatch
        let commands = rail.scrollViews.firstMatch
        let previousTaps = points.count
        for _ in 0..<4 where !functions.isHittable { commands.swipeUp() }
        XCTAssertTrue(functions.isHittable)
        functions.tap()
        app.buttons["F5"].firstMatch.tap()
        try await waitUntil { desktop.keyDowns == [0xFF09, 0xFFC2] }
        XCTAssertEqual(points.count, previousTaps)

        let dockedWidth = input.frame.width
        let toggle = app.buttons["toolbar.toggle"]
        toggle.tap()
        try await waitUntil { !rail.exists && input.frame.width > dockedWidth + 35 }
        toggle.tap()
        try await waitUntil { rail.exists && input.frame.width < dockedWidth + 4 }

        try await rotate(to: .landscapeRight)
        try await waitUntil { sideLayoutIsReady() }
        try await tapDesktopCenter()
        try await rotate(to: .portrait)
        try await waitUntil { !rail.exists && tab.isHittable && input.isHittable }
        XCTAssertEqual(tab.frame.midY, keyboard.frame.midY, accuracy: 4)
        try await tapDesktopCenter()
        XCTAssertEqual(desktop.acceptedConnections, initialConnections)
        let receipt = XCTAttachment(string: points.map { "\(Int($0.x)),\(Int($0.y))" }.joined(separator: "\n"))
        receipt.name = "Remote center taps across toolbar layouts"
        receipt.lifetime = .keepAlways
        add(receipt)
        app.buttons["session.close"].tap()
    }

    func testPinnedRemoteActionsSendPlatformShortcuts() async throws {
        let desktop = LocalTestDisplay()
        var wire: [Int] = []
        desktop.onWireKey = { down, key in wire.append(down ? Int(key) : -Int(key)) }
        let port = try await desktop.start()
        defer { desktop.stop() }
        let macDesktop = LocalTestDisplay(appleScalingCapability: false)
        var macWire: [Int] = []
        macDesktop.onWireKey = { down, key in macWire.append(down ? Int(key) : -Int(key)) }
        let macPort = try await macDesktop.start()
        defer { macDesktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port) {
            app.buttons["library.more"].tap()
            app.buttons["设置"].firstMatch.tap()
            let settings = app.navigationBars["设置"]
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            let top = settings.frame.maxY
            let scroll = settings.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 1))
                .withOffset(.init(dx: 0, dy: 260))
            let toolbar = app.buttons["preferences.toolbar"]
            for _ in 0..<8 {
                if toolbar.exists, (top + 25...top + 420).contains(toolbar.frame.midY), toolbar.isHittable { break }
                let step = toolbar.exists && toolbar.frame.midY < top + 25 ? CGFloat(120) : -120
                scroll.press(forDuration: 0.15, thenDragTo: scroll.withOffset(.init(dx: 0, dy: step)),
                             withVelocity: .slow, thenHoldForDuration: 0.15)
            }
            toolbar.coordinate(withNormalizedOffset: .init(dx: 0.35, dy: 0.5)).tap()
            XCTAssertTrue(app.navigationBars["互动工具栏"].waitForExistence(timeout: 5))
            let add = app.buttons["toolbar.addButton"]
            for _ in 0..<4 where !add.isHittable { app.swipeUp() }
            add.tap()
            for (id, title) in [("switchApp", "切换 App"), ("spotlight", "聚焦／开始菜单"), ("missionControl", "调度中心／任务视图")] {
                let option = app.buttons["toolbar.add." + id]
                for _ in 0..<4 where !option.isHittable { app.swipeUp() }
                XCTAssertTrue(option.isHittable)
                XCTAssertEqual(option.label, title)
                option.tap()
            }
            attachToolbarScreenshot(app, name: "Choose pinned toolbar commands")
            app.buttons["添加"].tap()
            app.terminate()
            app.launch()
        }
        let switchApp = app.buttons["toolbar.switchApp"]
        let spotlight = app.buttons["toolbar.spotlight"]
        let missionControl = app.buttons["toolbar.missionControl"]
        try await waitUntil { desktop.frameCount > 0 && switchApp.isHittable && switchApp.isEnabled }
        XCTAssertTrue(spotlight.isHittable)
        XCTAssertTrue(missionControl.isEnabled)
        XCTAssertEqual(spotlight.label, "开始菜单")
        XCTAssertEqual(missionControl.label, "任务视图")
        let control = app.buttons["toolbar.control"]
        control.tap()
        XCTAssertEqual(control.value as? String, "已选中")
        switchApp.tap()
        try await waitUntil { wire.count >= 4 }
        XCTAssertEqual(wire, [0xFFE9, 0xFF09, -0xFF09, -0xFFE9])
        XCTAssertNotEqual(control.value as? String, "已选中")
        spotlight.tap()
        try await waitUntil { wire.count >= 6 }
        XCTAssertEqual(Array(wire.suffix(2)), [0xFFEB, -0xFFEB])
        missionControl.tap()
        try await waitUntil { wire.count >= 10 }
        XCTAssertEqual(Array(wire.suffix(4)), [0xFFEB, 0xFF09, -0xFF09, -0xFFEB])
        attachToolbarScreenshot(app, name: "Pinned commands on a standard desktop")
        app.buttons["session.close"].tap()

        connectChart(app, port: macPort) {
            let display = app.buttons["显示器"].firstMatch
            for _ in 0..<4 where !display.isHittable { app.swipeUp() }
            display.tap()
            let adaptive = app.buttons["connection.adaptiveQuality"]
            for _ in 0..<4 where !adaptive.isHittable { app.swipeUp() }
            adaptive.tap()
            app.buttons["永不启用"].firstMatch.tap()
        }
        try await waitUntil { macDesktop.frameCount > 0 && missionControl.isHittable && missionControl.isEnabled }
        XCTAssertEqual(spotlight.label, "聚焦")
        XCTAssertEqual(missionControl.label, "调度中心")
        attachToolbarScreenshot(app, name: "Pinned commands on a Mac desktop")
        switchApp.tap()
        try await waitUntil { macWire.count >= 4 }
        XCTAssertEqual(macWire, [0xFFEB, 0xFF09, -0xFF09, -0xFFEB])
        spotlight.tap()
        try await waitUntil { macWire.count >= 8 }
        XCTAssertEqual(Array(macWire.suffix(4)), [0xFFEB, 0x20, -0x20, -0xFFEB])
        missionControl.tap()
        try await waitUntil { macWire.count >= 12 }
        XCTAssertEqual(Array(macWire.suffix(4)), [0xFFE3, 0xFF52, -0xFF52, -0xFFE3])
        let receipt = XCTAttachment(string: "Standard RFB: \(wire)\nApple RFB: \(macWire)")
        receipt.name = "Remote key press and release events"
        receipt.lifetime = .keepAlways
        add(receipt)
    }

    func testPortraitSplitSeparatesPicturePointerAndKeyboardAcrossRotation() async throws {
        let device = XCUIDevice.shared
        device.orientation = .portrait
        defer { device.orientation = .portrait }
        let desktop = LocalTestDisplay()
        var wire: [(UInt8, CGPoint)] = []
        desktop.onWirePointer = { wire.append(($0, $1)) }
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port) { self.enablePortraitSplit(in: app) }
        let trackpad = app.descendants(matching: .any)["session.laptopTrackpad"].firstMatch
        let keypad = app.descendants(matching: .any)["session.splitKeypad"].firstMatch
        let tab = app.buttons["toolbar.tab"].firstMatch
        let keyboard = app.buttons["toolbar.keyboard"].firstMatch
        try await waitUntil { trackpad.exists && keypad.exists && desktop.frameCount > 0 }
        XCTAssertLessThan(keypad.frame.maxX, trackpad.frame.minX)
        XCTAssertGreaterThan(trackpad.frame.minY, app.frame.midY - 80)
        XCTAssertGreaterThan(trackpad.frame.height, 70)
        attachToolbarScreenshot(app, name: "Portrait with side-by-side controls")

        let upper = app.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.23))
        upper.tap()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(wire.contains { $0.0 != 0 })
        wire.removeAll()
        let left = trackpad.coordinate(withNormalizedOffset: .init(dx: 0.26, dy: 0.48))
        let right = trackpad.coordinate(withNormalizedOffset: .init(dx: 0.74, dy: 0.48))
        left.press(forDuration: 0.08, thenDragTo: right, withVelocity: .slow, thenHoldForDuration: 0)
        try await waitUntil { Set(wire.map { $0.1.x }).count > 1 }
        XCTAssertFalse(wire.contains { $0.0 != 0 })
        app.buttons["session.trackpad.leftClick"].tap()
        try await waitUntil { wire.contains { $0.0 == 1 } }
        app.buttons["session.trackpad.rightClick"].tap()
        try await waitUntil { wire.contains { $0.0 == 4 } }
        tab.tap()
        try await waitUntil { desktop.keyDowns == [0xFF09] }

        keyboard.tap()
        let software = app.keyboards.firstMatch
        try await waitUntil(timeout: 15) { software.exists && software.frame.height > 120 && !trackpad.exists }
        XCTAssertLessThan(abs(software.frame.minY - keyboard.frame.maxY), 90)
        attachToolbarScreenshot(app, name: "Portrait with the system keyboard")
        let greeting: [UInt32] = [0x01004F60, 0x0100597D]
        try await selectPinyinGreeting(in: app, opensKeyboard: false) {
            XCTAssertEqual(desktop.keyDowns, [0xFF09])
        }
        try await waitUntil { desktop.keyDowns == [0xFF09] + greeting }
        keyboard.tap()
        try await waitUntil { trackpad.exists }

        app.buttons["切换全屏幕"].firstMatch.tap()
        try await waitUntil { !trackpad.exists && !app.buttons["session.close"].exists }
        let surface = app.descendants(matching: .any)["session.input"].firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 4))
        surface.tap(withNumberOfTaps: 2, numberOfTouches: 2)
        try await waitUntil { trackpad.exists }

        device.orientation = .landscapeLeft
        try await waitUntil { app.frame.width > app.frame.height && !trackpad.exists && tab.isHittable }
        tab.tap()
        try await waitUntil { desktop.keyDowns == [0xFF09] + greeting + [0xFF09] }
        let landscape = XCUIScreen.main.screenshot()
        XCTAssertGreaterThan(landscape.image.size.width, landscape.image.size.height)
        let landscapeAttachment = XCTAttachment(screenshot: landscape)
        landscapeAttachment.name = "Landscape with the regular toolbar"
        landscapeAttachment.lifetime = .keepAlways
        add(landscapeAttachment)
        device.orientation = .portrait
        try await waitUntil { app.frame.height > app.frame.width && trackpad.exists }
        XCTAssertEqual(desktop.acceptedConnections, 1)
    }

    func testPortraitKeyboardAndTrackpadSendsKeysAndLeavesObservationReadOnly() async throws {
        let device = XCUIDevice.shared
        device.orientation = .portrait
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port) { self.enablePortraitSplit(in: app, layout: "键盘与触控板") }
        let trackpad = app.descendants(matching: .any)["session.laptopTrackpad"].firstMatch
        let keyboard = app.descendants(matching: .any)["session.laptopKeyboard"].firstMatch
        let letter = app.buttons["a"].firstMatch
        try await waitUntil { trackpad.exists && keyboard.exists && letter.isHittable && desktop.frameCount > 0 }
        XCTAssertLessThan(keyboard.frame.maxY, trackpad.frame.minY)
        attachToolbarScreenshot(app, name: "Portrait with the dedicated keyboard")
        letter.tap()
        try await waitUntil { desktop.keyDowns == [0x61] }
        let mode = app.buttons["session.mode"].firstMatch
        mode.tap()
        try await waitUntil { mode.label == "仅观察" && !trackpad.exists && !keyboard.exists }
        let received = desktop.clicks
        app.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.56)).tap()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(desktop.clicks, received)
        mode.tap()
        try await waitUntil { trackpad.exists && keyboard.exists && letter.isHittable }
        letter.tap()
        try await waitUntil { desktop.keyDowns == [0x61, 0x61] }
        XCTAssertEqual(desktop.acceptedConnections, 1)
    }

    private func enablePortraitSplit(in app: XCUIApplication, layout: String? = nil) {
        app.buttons["library.more"].tap()
        app.buttons["设置"].firstMatch.tap()
        let toolbar = app.buttons["preferences.toolbar"]
        for _ in 0..<4 where !toolbar.isHittable { app.swipeUp() }
        XCTAssertTrue(toolbar.isHittable)
        toolbar.tap()
        let split = app.switches["toolbar.portraitSplit"].firstMatch
        for _ in 0..<4 where !split.isHittable { app.swipeUp() }
        XCTAssertTrue(split.isHittable)
        XCTAssertEqual(split.value as? String, "0")
        split.coordinate(withNormalizedOffset: .init(dx: 0.94, dy: 0.5)).tap()
        XCTAssertEqual(split.value as? String, "1")
        if let layout {
            app.buttons["toolbar.splitControls"].firstMatch.tap()
            app.buttons[layout].firstMatch.tap()
        }
        app.terminate()
        app.launch()
    }

    func testFloatingToolbarMovesFreelyWhenCollapsedAndVerticallyWhenExpanded() async throws {
        continueAfterFailure = false
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port) { self.selectToolbar("浮动", in: app) }
        try await waitUntil { desktop.frameCount > 0 && app.buttons["session.mode"].exists }
        let disclosure = app.buttons["toolbar.expand"]
        let tab = app.buttons["toolbar.tab"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        disclosure.tap()
        XCTAssertTrue(tab.waitForNonExistence(timeout: 5))

        func dragDisclosure(by offset: CGVector) {
            let handle = disclosure.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
            handle.press(forDuration: 0.05, thenDragTo: handle.withOffset(offset))
        }

        let original = disclosure.frame
        dragDisclosure(by: .init(dx: -100, dy: -220))
        try await waitUntil(timeout: 5) {
            abs(disclosure.frame.midX - (original.midX - 100)) < 24
                && abs(disclosure.frame.midY - (original.midY - 220)) < 24
        }
        let collapsed = disclosure.frame
        disclosure.press(forDuration: 1)
        XCTAssertTrue(app.buttons["显示键盘"].firstMatch.waitForExistence(timeout: 4))
        app.buttons["远程快捷命令"].firstMatch.tap()
        let insert = app.buttons["Insert"].firstMatch
        XCTAssertTrue(insert.waitForExistence(timeout: 4))
        insert.tap()
        try await waitUntil { desktop.keyDowns == [0xFF63] }
        disclosure.tap()
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        let expanded = disclosure.frame
        XCTAssertEqual(expanded.midX, collapsed.midX, accuracy: 3)
        XCTAssertEqual(expanded.midY, collapsed.midY, accuracy: 3)
        dragDisclosure(by: .init(dx: -110, dy: -120))
        try await waitUntil(timeout: 5) { disclosure.frame.midY < expanded.midY - 90 }
        XCTAssertEqual(disclosure.frame.midX, expanded.midX, accuracy: 3)
        let moved = disclosure.frame
        tab.tap()
        try await waitUntil { desktop.keyDowns == [0xFF63, 0xFF09] }
        attachToolbarScreenshot(app, name: "iPad floating toolbar")
        disclosure.tap()
        XCTAssertTrue(tab.waitForNonExistence(timeout: 5))
        XCTAssertEqual(disclosure.frame.midX, collapsed.midX, accuracy: 3)
        XCTAssertEqual(disclosure.frame.midY, moved.midY, accuracy: 3)
        XCTAssertEqual(desktop.clicks, 0)
        XCTAssertEqual(desktop.acceptedConnections, 1)
        app.buttons["session.close"].tap()
    }

    func testExpandedFloatingToolbarScrollsWithoutMovingOrSendingPointerEvents() async throws {
        continueAfterFailure = false
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        app.launchArguments = [
            "--test-library", UUID().uuidString, "-toolbar.iPad.style", "floating",
            "-toolbar.iPad.size", "extraLarge", "-toolbar.iPad.keyboardTrailing", "NO",
            "-toolbar.iPad.buttons", "escape,tab,shift,control,option,command,arrows,home,end,pageUp,pageDown,edit,shortcuts,functions,f5"
        ]
        app.launch()
        connectChart(app, port: port)
        let disclosure = app.buttons["toolbar.expand"]
        let tab = app.buttons["toolbar.tab"]
        let f5 = app.buttons["toolbar.f5"]
        try await waitUntil { desktop.frameCount > 0 && disclosure.exists && tab.isHittable }
        XCTAssertFalse(f5.isHittable)
        let position = disclosure.frame
        let scrollStart = tab.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
            .withOffset(.init(dx: 300, dy: 0))
        scrollStart.press(forDuration: 0.05, thenDragTo: scrollStart.withOffset(.init(dx: -370, dy: 0)))
        try await waitUntil(timeout: 5) { f5.isHittable }
        XCTAssertEqual(disclosure.frame.midX, position.midX, accuracy: 3)
        XCTAssertEqual(disclosure.frame.midY, position.midY, accuracy: 3)
        XCTAssertEqual(desktop.clicks, 0)
        XCTAssertTrue(desktop.keyDowns.isEmpty)
        f5.tap()
        try await waitUntil { desktop.keyDowns == [0xFFC2] }
        app.buttons["session.close"].tap()
    }

    func testTwoFingerDoubleTapEntersAndLeavesFullScreenWithoutRemoteClicks() async throws {
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port)
        let close = app.buttons["session.close"]
        try await waitUntil { desktop.frameCount > 0 && close.exists }
        let surface = app.descendants(matching: .any).matching(identifier: "session.input").firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 4))
        surface.tap(withNumberOfTaps: 2, numberOfTouches: 2)
        try await waitUntil { !close.exists && !app.buttons["toolbar.tab"].exists }
        surface.tap(withNumberOfTaps: 2, numberOfTouches: 2)
        try await waitUntil { close.exists && app.buttons["toolbar.tab"].exists }
        XCTAssertEqual(desktop.clicks, 0)
        close.tap()
    }

    func testCarouselPagesCanSendKeysAndMoveAwayFromDesktopContent() async throws {
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port) { self.selectToolbar("轮播", in: app) }
        try await waitUntil { desktop.frameCount > 0 && app.buttons["session.mode"].exists }
        let next = app.buttons["toolbar.next"]
        let tab = app.buttons["toolbar.tab"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        tab.tap()
        try await waitUntil { desktop.keyDowns == [0xFF09] }
        next.tap()
        XCTAssertTrue(tab.waitForNonExistence(timeout: 5))
        app.buttons["toolbar.functions"].tap()
        app.buttons["F5"].tap()
        try await waitUntil { desktop.keyDowns == [0xFF09, 0xFFC2] }
        next.tap()
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        let start = next.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let previous = next.frame.midX
        start.press(forDuration: 0.3, thenDragTo: start.withOffset(CGVector(dx: -140, dy: -60)))
        try await waitUntil { next.frame.midX < previous - 70 }
        attachToolbarScreenshot(app, name: "iPad carousel toolbar")
        app.buttons["session.close"].tap()
    }

    func testIPadToolbarProfileSurvivesEditingThePhoneProfile() async throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Requires the iPad toolbar")
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait

        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()

        func choose(_ title: String, from picker: String) {
            let control = app.buttons[picker].firstMatch
            XCTAssertTrue(control.waitForExistence(timeout: 6))
            control.tap()
            app.buttons[title].firstMatch.tap()
        }

        openChart(app, port: port) {
            app.buttons["library.more"].tap()
            app.buttons["设置"].firstMatch.tap()
            let entry = app.buttons["preferences.toolbar"]
            for _ in 0..<5 where !entry.isHittable { app.swipeUp() }
            XCTAssertTrue(entry.isHittable)
            entry.tap()
            XCTAssertTrue(app.navigationBars["互动工具栏"].waitForExistence(timeout: 5))

            let device = app.segmentedControls["toolbar.profileDevice"].firstMatch
            XCTAssertTrue(device.waitForExistence(timeout: 6))
            XCTAssertTrue(device.buttons["iPad"].isSelected)
            choose("大", from: "toolbar.size.setting")
            choose("末尾位置", from: "toolbar.keyboardPosition.setting")
            XCTAssertTrue(device.buttons["iPhone"].isHittable)
            device.buttons["iPhone"].tap()
            XCTAssertTrue(device.buttons["iPhone"].isSelected)
            choose("轮播", from: "toolbar.style.setting")
            choose("小", from: "toolbar.size.setting")
            choose("起始位置", from: "toolbar.keyboardPosition.setting")
            attachToolbarScreenshot(app, name: "iPhone toolbar settings selected on iPad")

            device.buttons["iPad"].tap()
            XCTAssertTrue(device.buttons["iPad"].isSelected)
            attachToolbarScreenshot(app, name: "Independent iPad toolbar settings")
            let add = app.buttons["toolbar.addButton"]
            for _ in 0..<5 where !add.isHittable { app.swipeUp() }
            XCTAssertTrue(add.isHittable)
            add.tap()
            let option = app.buttons["toolbar.add.f5"]
            for _ in 0..<5 where !option.isHittable { app.swipeUp() }
            XCTAssertTrue(option.isHittable)
            option.tap()
            app.buttons["添加"].tap()
            app.terminate()
            app.launch()
        }

        let f5 = app.buttons["toolbar.f5"].firstMatch
        let tab = app.buttons["toolbar.tab"].firstMatch
        let keyboard = app.buttons["toolbar.keyboard"].firstMatch
        try await waitUntil { desktop.frameCount > 0 && f5.isHittable && tab.isHittable && keyboard.isHittable }
        XCTAssertFalse(app.buttons["toolbar.next"].exists)
        XCTAssertGreaterThan(keyboard.frame.midX, tab.frame.midX)
        XCTAssertEqual(f5.frame.width, 54, accuracy: 2)
        f5.tap()
        try await waitUntil { desktop.keyDowns == [0xFFC2] }
        attachToolbarScreenshot(app, name: "iPad toolbar in a live remote session")
        app.buttons["session.close"].tap()
    }

    private func selectToolbar(_ style: String, in app: XCUIApplication) {
        app.buttons["library.more"].tap()
        app.buttons["设置"].firstMatch.tap()
        let toolbar = app.buttons["preferences.toolbar"]
        for _ in 0..<4 where !toolbar.isHittable { app.swipeUp() }
        XCTAssertTrue(toolbar.isHittable)
        toolbar.tap()
        app.buttons["toolbar.style.setting"].tap()
        app.buttons[style].firstMatch.tap()
        // Reopen from the library and use the style actually persisted by Settings.
        app.terminate()
        app.launch()
    }

    private func attachToolbarScreenshot(_ app: XCUIApplication, name: String) {
        let result = XCTAttachment(screenshot: app.screenshot())
        result.name = name
        result.lifetime = .keepAlways
        add(result)
    }

    @available(iOS 27, *)
    func testExternalDisplayShowsOnlyTheSelectedDesktop() async throws {
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port)
        try await waitUntil { app.buttons["session.mode"].exists && desktop.frameCount > 0 }
        let mirror = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "镜像到外部显示器")).firstMatch
        let offered = mirror.waitForExistence(timeout: 6)
        try XCTSkipIf(!offered && XCUIScreen.screens.count < 2, "Requires an attached noninteractive external display")
        XCTAssertTrue(offered, "The system exposes another screen, but the session does not offer mirroring")
        guard offered else { return }
        mirror.tap()
        try await waitUntil { XCUIScreen.screens.dropFirst().contains { Self.hasColorChart($0.screenshot().image, minimumFraction: 0.18) } }
        let external = try XCTUnwrap(XCUIScreen.screens.dropFirst().first { Self.hasColorChart($0.screenshot().image, minimumFraction: 0.18) })
        let output = XCTAttachment(screenshot: external.screenshot())
        output.name = "External display, remote desktop only"
        output.lifetime = .keepAlways
        add(output)
        XCTAssertTrue(Self.hasColorChart(app.screenshot().image))

        desktop.withholdFramesAfterConnection = 1
        let originalFrames = desktop.frameCount
        desktop.dropCurrentConnection()
        let waiting = app.descendants(matching: .any)["session.waitingForScreen"].firstMatch
        try await waitUntil { desktop.acceptedConnections == 2 && waiting.exists }
        XCTAssertEqual(desktop.frameCount, originalFrames)
        try await waitUntil {
            guard let screen = XCUIScreen.screens.dropFirst().first else { return false }
            return !Self.hasColorChart(screen.screenshot().image, minimumFraction: 0.18)
        }
        let blankScreen = try XCTUnwrap(XCUIScreen.screens.dropFirst().first)
        let blank = XCTAttachment(screenshot: blankScreen.screenshot())
        blank.name = "External display waiting for a fresh desktop"
        blank.lifetime = .keepAlways
        add(blank)

        desktop.withholdFramesAfterConnection = nil
        try await waitUntil { desktop.frameCount > originalFrames && !waiting.exists }
        try await waitUntil {
            XCUIScreen.screens.dropFirst().contains { Self.hasColorChart($0.screenshot().image, minimumFraction: 0.18) }
        }
        let restoredScreen = try XCTUnwrap(XCUIScreen.screens.dropFirst().first)
        let restored = XCTAttachment(screenshot: restoredScreen.screenshot())
        restored.name = "External display restored after reconnect"
        restored.lifetime = .keepAlways
        add(restored)

        app.buttons["session.close"].tap()
        try await waitUntil { app.buttons["library.quick"].exists }
        try await waitUntil { XCUIScreen.screens.dropFirst().allSatisfy { !Self.hasColorChart($0.screenshot().image, minimumFraction: 0.18) } }
    }
    #endif

    private func applyLink(_ text: String, in app: XCUIApplication) {
        app.buttons["connection.openLink"].tap()
        let field = app.alerts.secureTextFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 4))
        field.tap()
        field.typeText(text)
        app.alerts.buttons["使用链接"].tap()
    }

    private func openChart(_ app: XCUIApplication, port: UInt16, prepare: () -> Void = {}) {
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.buttons["library.quick"].waitForExistence(timeout: 12))
        prepare()
        connectChart(app, port: port)
    }

    private func connectChart(_ app: XCUIApplication, port: UInt16, configure: () -> Void = {}) {
        let quick = app.buttons["library.quick"]
        XCTAssertTrue(quick.waitForExistence(timeout: 8))
        quick.tap()
        let field = app.textFields["connection.host"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let submit = app.buttons["connection.submit"]
        XCTAssertFalse(submit.isEnabled)
        field.tap()
        field.typeText("127.0.0.1:\(port)")
        configure()
        submit.tap()
    }

    private func waitUntil(timeout: TimeInterval = 12, _ check: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !check() {
            guard Date() < deadline else { throw TimedOut() }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private struct TimedOut: LocalizedError {
        var errorDescription: String? { "The expected UI or loopback event did not arrive before the deadline." }
    }

    private static func hasColorChart(_ screenshot: UIImage, minimumFraction: Double = 0.005,
                                      visible: Set<Int> = [0, 1, 2, 3]) -> Bool {
        let fractions = chartFractions(screenshot)
        return fractions.count == 4 && fractions.enumerated().allSatisfy { index, fraction in
            visible.contains(index) ? fraction > minimumFraction : fraction < 0.02
        }
    }

    private static func chartFractions(_ screenshot: UIImage) -> [Double] {
        guard let image = screenshot.cgImage else { return [] }
        let dimension = 64
        var bytes = [UInt8](repeating: 0, count: dimension * dimension * 4)
        let colors = [[31,89,165], [241,183,69], [52,174,146], [223,102,88]]
        return bytes.withUnsafeMutableBytes { storage in
            guard let context = CGContext(data: storage.baseAddress, width: dimension, height: dimension,
                bitsPerComponent: 8, bytesPerRow: dimension * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return [] }
            context.draw(image, in: CGRect(x: 0, y: 0, width: dimension, height: dimension))
            let pixels = storage.bindMemory(to: UInt8.self)
            var counts = [Int](repeating: 0, count: 4)
            for index in stride(from: 0, to: pixels.count, by: 4) {
                for (color, components) in colors.enumerated() where
                    (0..<3).allSatisfy({ abs(Int(pixels[index+$0]) - components[$0]) < 28 }) {
                    counts[color] += 1
                }
            }
            return counts.map { Double($0) / Double(dimension * dimension) }
        }
    }
}
