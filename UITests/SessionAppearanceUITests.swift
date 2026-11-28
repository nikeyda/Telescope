import UIKit
import XCTest

@MainActor
final class SessionAppearanceUITests: XCTestCase {
    func testRemoteSessionAndDetailsUseDarkAppearance() async throws {
        continueAfterFailure = false
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }

        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        let quick = app.buttons["library.quick"].firstMatch
        XCTAssertTrue(quick.waitForExistence(timeout: 10))
        let library = presentation(in: app, containing: "library.quick").screenshot()
        #if !targetEnvironment(macCatalyst)
        let librarySample = CGRect(x: 0.79, y: 0.17, width: 0.12, height: 0.05)
        let libraryLuminance = try luminance(of: library, in: librarySample)
        #endif
        attach(library, as: "Connection library before connecting")

        app.open(try XCTUnwrap(URL(string: "vnc://127.0.0.1:\(port)")))
        let submit = app.buttons["connection.submit"].firstMatch
        XCTAssertTrue(submit.wait(for: \.isHittable, toEqual: true, timeout: 8))
        press(submit)
        let info = app.buttons["session.info"].firstMatch
        let deadline = ContinuousClock.now + .seconds(15)
        while desktop.frameCount == 0 || !info.isHittable {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(100))
        }

        #if targetEnvironment(macCatalyst)
        let sessionWindow = presentation(in: app, containing: "session.info")
        let surface = sessionWindow.screenshot()
        let viewport = sessionWindow.frame
        let titleRowY = (info.frame.midY - viewport.minY) / viewport.height
        let chrome = CGRect(x: 0.36, y: titleRowY - 0.008, width: 0.12, height: 0.016)
        #else
        let surface = XCUIScreen.main.screenshot()
        let mode = app.buttons["session.mode"].firstMatch
        XCTAssertTrue(mode.isHittable)
        let chrome = displayFraction(CGRect(x: mode.frame.minX - 44, y: mode.frame.midY - 6, width: 28, height: 12))
        #endif
        attach(surface, as: "Dark remote session")
        let chromeLuminance = try luminance(of: surface, in: chrome)
        XCTAssertLessThan(chromeLuminance, 0.25)

        press(info)
        let done = app.buttons["details.done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 8))
        let dimensions = app.descendants(matching: .any)["details.dimensions"].firstMatch
        XCTAssertTrue(dimensions.waitForExistence(timeout: 8))
        #if targetEnvironment(macCatalyst)
        let details = presentation(in: app, containing: "details.done").screenshot()
        let detailsSample = CGRect(x: 0.45, y: 0.45, width: 0.10, height: 0.10)
        #else
        let details = XCUIScreen.main.screenshot()
        let row = dimensions.frame
        let detailsSample = displayFraction(CGRect(x: row.midX, y: row.midY - 6, width: row.width * 0.12, height: 12))
        #endif
        attach(details, as: "Dark connection information")
        let detailsLuminance = try luminance(of: details, in: detailsSample)
        XCTAssertLessThan(detailsLuminance, 0.25)
        press(done)
        press(app.buttons["session.close"].firstMatch)
        XCTAssertTrue(quick.waitForExistence(timeout: 10))

        let restored = presentation(in: app, containing: "library.quick").screenshot()
        attach(restored, as: "Connection library after disconnecting")
        #if !targetEnvironment(macCatalyst)
        let restoredLuminance = try luminance(of: restored, in: librarySample)
        XCTAssertEqual(restoredLuminance, libraryLuminance, accuracy: 0.12)
        let appearance = XCTAttachment(string: """
            Library before connection: \(libraryLuminance)
            Session controls: \(chromeLuminance)
            Connection information: \(detailsLuminance)
            Library after disconnect: \(restoredLuminance)
            """)
        appearance.name = "Connection library appearance is preserved"
        appearance.lifetime = .keepAlways
        add(appearance)
        #endif
    }

    private func attach(_ screenshot: XCUIScreenshot, as name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func presentation(in app: XCUIApplication, containing button: String) -> XCUIElement {
        #if targetEnvironment(macCatalyst)
        app.windows.containing(.button, identifier: button).firstMatch
        #else
        app
        #endif
    }

    private func press(_ element: XCUIElement) {
        #if targetEnvironment(macCatalyst)
        element.click()
        #else
        element.tap()
        #endif
    }

    #if !targetEnvironment(macCatalyst)
    private func displayFraction(_ rect: CGRect) -> CGRect {
        let screen = UIScreen.main.bounds
        return CGRect(x: (rect.minX - screen.minX) / screen.width, y: (rect.minY - screen.minY) / screen.height,
                      width: rect.width / screen.width, height: rect.height / screen.height)
    }
    #endif

    private func luminance(of screenshot: XCUIScreenshot, in fraction: CGRect) throws -> Double {
        let image = try XCTUnwrap(screenshot.image.cgImage)
        let crop = CGRect(x: fraction.minX * CGFloat(image.width), y: fraction.minY * CGFloat(image.height),
                          width: fraction.width * CGFloat(image.width), height: fraction.height * CGFloat(image.height)).integral
        let sample = try XCTUnwrap(image.cropping(to: crop))
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                                   bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.interpolationQuality = .medium
            context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return (0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])) / 255
    }
}
