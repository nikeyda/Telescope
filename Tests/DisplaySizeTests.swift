import XCTest
import Network
import UIKit
@testable import DeskLink
@testable import rootshellVNC
import RFBProtocol
@testable import RFBTransport

@MainActor final class DisplaySizeTests: XCTestCase {
    func testChangingFramingResetsOnlyThatViewportAndKeepsRetinaGeometry() throws {
        let geometry = RemoteViewportGeometry(viewSize: CGSize(width: 600, height: 500),
                                              framebufferSize: CGSize(width: 1800, height: 1200), displayScale: 2)
        var primary = RemoteViewportState()
        var secondary = RemoteViewportState(sizing: .fill)
        primary.updateGeometry(geometry)
        secondary.updateGeometry(geometry)
        primary.zoom(by: 2, around: CGPoint(x: 180, y: 240),
                     viewSize: geometry.viewSize, framebufferSize: geometry.framebufferSize)
        let untouched = secondary

        func picture(in viewport: RemoteViewportState) throws -> CGRect {
            try XCTUnwrap(viewport.displayedFrame(viewSize: geometry.viewSize, framebufferSize: geometry.framebufferSize))
        }
        let expected: [(RemoteViewportSizing, CGFloat)] = [(.fit, 600), (.fill, 750), (.actualSize, 900)]
        for (mode, width) in expected {
            primary.reset(sizing: mode)
            let frame = try picture(in: primary)
            XCTAssertEqual(frame.width, width, accuracy: 0.001)
            XCTAssertEqual(frame.midX, 300, accuracy: 0.001)
            XCTAssertEqual(frame.midY, 250, accuracy: 0.001)
            XCTAssertEqual(primary.scale, 1)
            XCTAssertEqual(primary.offset, .zero)
            XCTAssertEqual(primary.displayScale, 2)
            XCTAssertEqual(secondary, untouched)
        }
    }

    func testResizingKeepsTheMagnifiedPointAtTheCenterOfTheViewport() throws {
        let portrait = RemoteViewportGeometry(viewSize: CGSize(width: 390, height: 700),
                                              framebufferSize: CGSize(width: 1600, height: 900))
        let landscape = RemoteViewportGeometry(viewSize: CGSize(width: 850, height: 350),
                                               framebufferSize: portrait.framebufferSize)
        var viewport = RemoteViewportState()
        viewport.updateGeometry(portrait)
        viewport.zoom(by: 2.5, around: CGPoint(x: 90, y: 300),
                      viewSize: portrait.viewSize, framebufferSize: portrait.framebufferSize)
        XCTAssertNotEqual(viewport.offset, .zero)

        func center(in geometry: RemoteViewportGeometry) throws -> CGPoint {
            let viewCenter = CGPoint(x: geometry.viewSize.width / 2, y: geometry.viewSize.height / 2)
            return try XCTUnwrap(viewport.framebufferPoint(for: viewCenter, viewSize: geometry.viewSize,
                                                          framebufferSize: geometry.framebufferSize))
        }

        let original = try center(in: portrait)
        viewport.updateGeometry(landscape)
        let rotated = try center(in: landscape)
        XCTAssertEqual(rotated.x, original.x, accuracy: 0.001)
        XCTAssertEqual(rotated.y, original.y, accuracy: 0.001)
        XCTAssertEqual(viewport.scale, 2.5)
        viewport.updateGeometry(portrait)
        let restored = try center(in: portrait)
        XCTAssertEqual(restored.x, original.x, accuracy: 0.001)
        XCTAssertEqual(restored.y, original.y, accuracy: 0.001)
    }

    func testActualSizeKeepsItsRelativeCenterThroughAFrameGapAndRetinaResize() throws {
        let view = CGSize(width: 820, height: 640)
        let original = RemoteViewportGeometry(viewSize: view, framebufferSize: CGSize(width: 1600, height: 1200),
                                              displayScale: 2)
        let resized = RemoteViewportGeometry(viewSize: CGSize(width: 930, height: 510),
                                             framebufferSize: CGSize(width: 1920, height: 1080), displayScale: 3)
        var viewport = RemoteViewportState(sizing: .actualSize)
        viewport.updateGeometry(original)
        viewport.pan(by: CGSize(width: 175, height: -85), viewSize: view, framebufferSize: original.framebufferSize)
        let before = viewport
        viewport.updateGeometry(RemoteViewportGeometry(viewSize: resized.viewSize, framebufferSize: .zero,
                                                       displayScale: resized.displayScale))
        XCTAssertEqual(viewport, before)

        func relativeCenter(_ geometry: RemoteViewportGeometry) throws -> CGPoint {
            let center = CGPoint(x: geometry.viewSize.width / 2, y: geometry.viewSize.height / 2)
            let point = try XCTUnwrap(viewport.framebufferPoint(for: center, viewSize: geometry.viewSize,
                                                               framebufferSize: geometry.framebufferSize))
            return CGPoint(x: point.x / geometry.framebufferSize.width, y: point.y / geometry.framebufferSize.height)
        }

        let first = try relativeCenter(original)
        viewport.updateGeometry(resized)
        let second = try relativeCenter(resized)
        XCTAssertEqual(second.x, first.x, accuracy: 0.001)
        XCTAssertEqual(second.y, first.y, accuracy: 0.001)
        XCTAssertEqual(viewport.sizing, .actualSize)
        XCTAssertEqual(viewport.displayScale, 3)
        let physicalSize = try XCTUnwrap(viewport.displayedFrame(viewSize: resized.viewSize,
                                                                framebufferSize: resized.framebufferSize)?.size)
        XCTAssertEqual(physicalSize.width, 640, accuracy: 0.001)
        XCTAssertEqual(physicalSize.height, 360, accuracy: 0.001)
    }

    func testInitialFramingUsesOneTransformForPictureAndPointer() throws {
        let view = CGSize(width: 400, height: 300)
        let remote = CGSize(width: 800, height: 400)
        let point = CGPoint(x: 125, y: 100)
        let fit = RemoteViewportState()
        XCTAssertEqual(fit.displayedFrame(viewSize: view, framebufferSize: remote),
                       CGRect(x: 0, y: 50, width: 400, height: 200))

        var fill = RemoteViewportState(sizing: .fill)
        XCTAssertEqual(fill.displayedFrame(viewSize: view, framebufferSize: remote),
                       CGRect(x: -100, y: 0, width: 600, height: 300))
        let mapped = try XCTUnwrap(fill.framebufferPoint(for: point, viewSize: view, framebufferSize: remote))
        let roundTrip = try XCTUnwrap(fill.viewPoint(forFramebufferPoint: mapped, viewSize: view, framebufferSize: remote))
        XCTAssertEqual(roundTrip.x, point.x, accuracy: 0.001)
        XCTAssertEqual(roundTrip.y, point.y, accuracy: 0.001)
        XCTAssertNotEqual(fill.edgeScrollTranslation(
            for: .zero, viewSize: view, framebufferSize: remote, elapsedTime: 0.01), .zero)
        fill.zoom(by: 0.9, around: point, viewSize: view, framebufferSize: remote)
        XCTAssertEqual(fill.sizing, .fill)
        fill.zoom(by: 0.5, around: point, viewSize: view, framebufferSize: remote)
        XCTAssertTrue(fill.isIdentity)

        var actual = RemoteViewportState(sizing: .actualSize)
        actual.displayScale = 2
        let small = CGSize(width: 200, height: 100)
        XCTAssertEqual(actual.displayedFrame(viewSize: view, framebufferSize: small),
                       CGRect(x: 150, y: 125, width: 100, height: 50))
        XCTAssertNil(actual.framebufferPoint(for: point, viewSize: view, framebufferSize: small))
        XCTAssertEqual(actual.framebufferPoint(
            for: CGPoint(x: 170, y: 140), viewSize: view, framebufferSize: small),
            CGPoint(x: 40, y: 30))
        let almostSquare = CGSize(width: 200, height: 202)
        XCTAssertEqual(actual.displayedFrame(viewSize: CGSize(width: 400, height: 400),
                                            framebufferSize: almostSquare)?.size,
                       CGSize(width: 100, height: 101))
        actual.reset()
        XCTAssertTrue(actual.isIdentity)
    }

    func testFallbackCursorOnlySubstitutesClientDrawnPointers() {
        func style(_ presence: RemoteCursorPresence, trackpad: Bool, fallback: Bool,
                   serverDrawn: Bool = false, dot: Bool = false) -> TrackpadCursorStyle {
            TrackpadCursorStyle.resolve(hasServerCursor: presence == .described, presence: presence,
                                       allowingFallback: trackpad, serverRendersCursor: serverDrawn,
                                       showsLocalDot: dot, usesFallbackCursor: fallback)
        }
        for trackpad in [false, true] {
            XCTAssertEqual(style(.hidden, trackpad: trackpad, fallback: false), .hidden)
            XCTAssertEqual(style(.hidden, trackpad: trackpad, fallback: true), .fallbackArrow)
            XCTAssertEqual(style(.described, trackpad: trackpad, fallback: true), .serverBitmap)
            XCTAssertEqual(style(.hidden, trackpad: trackpad, fallback: true, serverDrawn: true), .hidden)
        }
        XCTAssertEqual(style(.undescribed, trackpad: true, fallback: false), .fallbackArrow)
        XCTAssertEqual(style(.undescribed, trackpad: false, fallback: true), .hidden)
        XCTAssertEqual(style(.hidden, trackpad: true, fallback: true, serverDrawn: true, dot: true), .localDot)
    }

    func testPCScrollSpeedPersistsAndPreservesFractionalMovement() throws {
        var computer = Computer(endpoint: try Endpoint(address: "scroll.fixture.invalid"))
        let legacy = try JSONEncoder().encode(computer)
        XCTAssertNil((try JSONSerialization.jsonObject(with: legacy) as? [String: Any])?["pcScrollSpeed"])
        XCTAssertEqual(try JSONDecoder().decode(Computer.self, from: legacy).scrollSpeed(forMac: false), .standard)
        for speed in RemoteScrollSpeed.allCases {
            computer.pcScrollSpeed = speed
            let entry = try JSONDecoder().decode(Computer.self, from: JSONEncoder().encode(computer))
            XCTAssertEqual(entry.scrollSpeed(forMac: true), .standard)
            var points = ScrollPointAccumulator()
            var wheel = ScrollWheelUnitAccumulator()
            var ticksX = 0, ticksY = 0
            for _ in 0..<40 {
                let step = points.consume(CGPoint(x: -1, y: 1), speed: entry.scrollSpeed(forMac: false))
                let ticks = wheel.consume(pointDeltaX: step.x, pointDeltaY: step.y)
                ticksX += Int(ticks.x)
                ticksY += Int(ticks.y)
            }
            XCTAssertEqual(ticksX, -speed.rawValue / 25)
            XCTAssertEqual(ticksY, speed.rawValue / 25)
        }
    }

    func testHalfResolutionKeepsAdjacentMonitorEdgesAndMapsInputToNativePixels() {
        let scale = AppleFramebufferScale.half
        let nativeLeft = AppleDisplayInfo(displayIndex: 4, originX: -159, originY: -20, width: 160, height: 100, flags: 1)
        let nativeRight = AppleDisplayInfo(displayIndex: 6, originX: 1, originY: -20, width: 321, height: 100, flags: 3)
        let left = scale.framebufferDisplay(nativeLeft), right = scale.framebufferDisplay(nativeRight)
        XCTAssertEqual(left.originX, -80)
        XCTAssertEqual(Int(left.originX) + Int(left.width), Int(right.originX))
        XCTAssertEqual(right.width, 161)
        XCTAssertEqual(left.originY, -10)
        XCTAssertEqual(right.height, 50)
        XCTAssertEqual(right.displayIndex, nativeRight.displayIndex)
        XCTAssertEqual(right.flags, nativeRight.flags)
        XCTAssertEqual(scale.framebufferLength(0), 0)
        XCTAssertEqual(scale.nativeCoordinate(80), 160)
        XCTAssertEqual(scale.nativeCoordinate(UInt16.max), UInt16.max)
        XCTAssertEqual(AppleFramebufferScale.native.framebufferDisplay(nativeLeft), nativeLeft)
    }

    func testFramebufferQualityRetainsLegacyDefaultsAndPerComputerChoices() throws {
        let baseline = Computer(endpoint: try Endpoint(address: "desktop.invalid"))
        let oldData = try JSONEncoder().encode(baseline)
        XCTAssertFalse(String(decoding: oldData, as: UTF8.self).contains("framebufferQuality"))
        let old = try JSONDecoder().decode(Computer.self, from: oldData)
        XCTAssertEqual(old.configuration.framebufferQuality, FramebufferQuality())
        XCTAssertTrue(old.configuration.effectiveEncodings.contains(.appleMultiVariantScreenshare))
        XCTAssertNil(old.configuration.losslessFallbackEncodings)

        var configured = baseline
        configured.id = UUID()
        configured.framebufferQuality = FramebufferQuality(adaptive: .remoteOnly, compression: .always)
        let archive = LibraryArchive(computers: [baseline, configured])
        let restored = try LibraryArchive.read(archive.encoded())
        XCTAssertNil(restored.computers[0].framebufferQuality)
        XCTAssertEqual(restored.computers[1].framebufferQuality, configured.framebufferQuality)
        let fallback = try XCTUnwrap(configured.configuration.losslessFallbackEncodings)
        XCTAssertFalse(fallback.contains(.appleMultiVariantScreenshare))
        XCTAssertTrue(fallback.contains(.zrle))
        XCTAssertTrue(fallback.contains(.serverDisplayInfo) || fallback.contains(.extendedDesktopSize))
        XCTAssertFalse(FramebufferQuality.Scope.remoteOnly.applies(onLocalNetwork: true))
        XCTAssertTrue(FramebufferQuality.Scope.remoteOnly.applies(onLocalNetwork: false))
        configured.quality = .lossless
        XCTAssertFalse(configured.configuration.effectiveEncodings.contains(.tight))
        configured.quality = .standard
        configured.colorDepth = .low
        XCTAssertNil(configured.configuration.losslessFallbackEncodings)
    }

    func testAppleLayoutRetainsAMonitorAboveAndLeftOfThePrimary() throws {
        var payload = Data(repeating: 0, count: 22 + 2 * 56)
        payload[1] = UInt8(payload.count - 2)
        payload[21] = 2
        func display(_ index: Int, id: UInt8, top: Int16, left: Int16, bottom: Int16, right: Int16) {
            let offset = 22 + index * 56
            payload[offset + 19] = id
            for (i, coordinate) in [top, left, bottom, right].enumerated() {
                let bits = UInt16(bitPattern: coordinate)
                payload[offset + 28 + 2 * i] = UInt8(bits >> 8)
                payload[offset + 29 + 2 * i] = UInt8(truncatingIfNeeded: bits)
            }
        }
        display(0, id: 32, top: 0, left: 0, bottom: 1200, right: 1920)
        display(1, id: 87, top: -240, left: -1280, bottom: 480, right: 0)
        let monitors = appleDisplayInfo2Records(payload)
        XCTAssertEqual(monitors.map(\.displayIndex), [32, 87])
        let outside = try XCTUnwrap(monitors.last)
        XCTAssertEqual(outside.originX, -1280)
        XCTAssertEqual(outside.originY, -240)
        XCTAssertEqual(outside.width, 1280)
        let extent = try XCTUnwrap(appleFramebufferExtent(monitors))
        XCTAssertEqual(extent.width, 3200)
        XCTAssertEqual(extent.height, 1440)
    }

    func testMonitorSelectionUsesServerIDsAndSurvivesLayoutReordering() async throws {
        let computer = Computer(endpoint: try Endpoint(address: "fixture.invalid"))
        let session = VNCSession(configuration: computer.configuration)
        session.framebufferWidth = 300
        session.framebufferHeight = 100
        let left = RFBScreenLayout(id: 84, x: 0, y: 0, width: 100, height: 100, flags: 0)
        let center = RFBScreenLayout(id: 10, x: 100, y: 0, width: 100, height: 100, flags: 0)
        let right = RFBScreenLayout(id: 73, x: 200, y: 0, width: 100, height: 100, flags: 0)
        await session.updateRemoteDisplayRegions([left, center, right])
        XCTAssertEqual(session.selectableMonitorIDs, [84, 10, 73])
        let switched = try await session.selectMonitor(.display(73))
        XCTAssertTrue(switched)
        XCTAssertEqual(session.presentedFramebufferRegion, CGRect(x: 200, y: 0, width: 100, height: 100))
        await session.updateRemoteDisplayRegions([center, right, left])
        XCTAssertEqual(session.selectedMonitor, .display(73))
        await session.updateRemoteDisplayRegions([left, center])
        XCTAssertEqual(session.selectedMonitor, .display(84))
        let missing = try await session.selectMonitor(.display(73))
        XCTAssertFalse(missing)
        await session.updateRemoteDisplayRegions([left, center, right])
        let combined = try await session.selectMonitor(.all)
        XCTAssertTrue(combined)
        XCTAssertEqual(session.presentedFramebufferRegion, CGRect(x: 0, y: 0, width: 300, height: 100))
    }

    func testPhysicalMediaCanvasIncludesThreeDisplaysAndUsesTheSelectedAspect() async throws {
        var computer = Computer(endpoint: try Endpoint(address: "fixture.invalid"))
        computer.quality = .adaptive
        computer.layout = .combined
        let session = VNCSession(configuration: computer.configuration)
        let screens = [
            RFBScreenLayout(id: 4, x: 0, y: 0, width: 100, height: 100, flags: 0),
            RFBScreenLayout(id: 9, x: 100, y: 0, width: 160, height: 120, flags: 0),
            RFBScreenLayout(id: 2, x: 260, y: 0, width: 50, height: 90, flags: 0),
        ]
        let layout = screens.map {
            AppleDisplayInfo(displayIndex: $0.id, originX: Int32($0.x) - 100, originY: Int32($0.y),
                             width: UInt32($0.width), height: UInt32($0.height), flags: 0)
        }
        await session.updateRemoteDisplayRegions(layout)
        session.isHighPerformanceMode = true
        XCTAssertEqual(session.presentedVideoDisplayRegions, [CGRect(x: 0, y: 0, width: 310, height: 120)])
        XCTAssertEqual(session.selectableMonitorIDs, [4, 9, 2])
        session.isHighPerformanceMode = false
        await session.updateRemoteDisplayRegions(screens)
        let changed = try await session.selectMonitor(.display(9))
        XCTAssertTrue(changed)
        await session.updateRemoteDisplayRegions(layout)
        session.isHighPerformanceMode = true
        XCTAssertEqual(session.presentedVideoDisplayRegions, [CGRect(x: 0, y: 0, width: 160, height: 120)])
        XCTAssertEqual(session.presentedFramebufferRegion, CGRect(x: 0, y: 0, width: 160, height: 120))
    }

    func testRememberMonitorForMatchingRecentComputerRespectsOptOut() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "library.json")
        let library = ConnectionLibrary(file: file)
        let saved = Computer(name: "Fixture", endpoint: try Endpoint(address: "monitor.invalid"))
        XCTAssertTrue(library.save(saved))
        var quick = Computer(endpoint: saved.endpoint)
        quick.saved = false
        library.recordSuccess(quick)
        library.rememberMonitor(.display(73), for: quick)
        let reopened = ConnectionLibrary(file: file)
        var entry = try XCTUnwrap(reopened.existingComputer(matching: quick))
        XCTAssertEqual(entry.name, "Fixture")
        XCTAssertEqual(entry.display(for: .current).lastMonitor, .display(73))
        var display = entry.display(for: .current)
        display.rememberMonitor = false
        display.lastMonitor = nil
        entry.setDisplay(display, for: .current)
        XCTAssertTrue(reopened.save(entry))
        reopened.rememberMonitor(.all, for: quick)
        XCTAssertNil(reopened.existingComputer(matching: quick)?.display(for: .current).lastMonitor)
    }

    func testImportedDisplayLayoutUsesTheReceivingClientAndPreservesItsSource() throws {
        var old = Computer(endpoint: try Endpoint(address: "migrated-display.invalid"))
        old.quality = .adaptive
        old.layout = .virtualPair
        old.matchWindow = true
        let data = try LibraryArchive(computers: [old]).encoded()
        let restored = try XCTUnwrap(LibraryArchive.read(data).computers.first)
        let mac = restored.display(for: .mac).resolved(for: .mac)
        XCTAssertEqual(mac.layout, .virtualPair)
        XCTAssertEqual(mac.fixedDesktop, .standard)
        let tablet = restored.display(for: .iPad).resolved(for: .iPad)
        XCTAssertEqual(tablet.layout, .single)
        XCTAssertTrue(tablet.matchWindow)
        XCTAssertNil(tablet.fixedDesktop)
        let active = restored.configuration
        XCTAssertEqual(active.displayMode, DisplayClient.current == .mac ? .twoVirtualDisplays : .oneDisplay)
        XCTAssertEqual(active.fixedDesktopSize, DisplayClient.current == .mac ? CGSize(width: 1440, height: 900) : nil)
        XCTAssertEqual(restored, old)
        var physical = mac
        physical.layout = .combined
        XCTAssertFalse(physical.resolved(for: .mac).matchWindow)
        XCTAssertNil(physical.resolved(for: .mac).fixedDesktop)
        var standard = mac
        standard.quality = .standard
        XCTAssertEqual(standard.resolved(for: .mac).layout, .single)
        XCTAssertNil(standard.resolved(for: .mac).fixedDesktop)
    }

    func testDisablingMediaOrUsingSSHRetainsTheVirtualDesktop() throws {
        var computer = Computer(endpoint: try Endpoint(address: "fixture.invalid"))
        var display = DesktopDisplayPreferences(quality: .adaptive, layout: .virtualPair, matchWindow: true,
                                               fixedDesktop: DesktopDimensions(width: 1024, height: 768))
        computer.setDisplay(display, for: .current)
        XCTAssertTrue(computer.configuration.effectiveEncodings.contains(.appleH264))
        XCTAssertTrue(computer.configuration.effectiveRemoteAudioPlaybackEnabled)
        display.smoothVideo = false
        computer.setDisplay(display, for: .current)
        let fixed = computer.configuration
        let expectedMode: VNCConfiguration.DisplayMode = DisplayClient.current == .mac ? .twoVirtualDisplays : .oneDisplay
        XCTAssertEqual(fixed.displayMode, expectedMode)
        XCTAssertEqual(fixed.fixedDesktopSize, CGSize(width: 1024, height: 768))
        XCTAssertEqual(fixed.videoQualityMode, .adaptive)
        XCTAssertTrue(fixed.effectiveEncodings.contains(.tight))
        XCTAssertFalse(fixed.effectiveEncodings.contains(.appleH264))
        XCTAssertFalse(fixed.effectiveRemoteAudioPlaybackEnabled)
        display.smoothVideo = true
        computer.setDisplay(display, for: .current)
        computer.ssh = SSHSettings(username: "test")
        var tunnel = computer.configuration
        tunnel.transportProvider = { _, _ in throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(tunnel.videoQualityMode, .adaptive)
        XCTAssertEqual(tunnel.displayMode, expectedMode)
        XCTAssertFalse(tunnel.effectiveEncodings.contains(.appleH264))
        XCTAssertFalse(tunnel.effectiveRemoteAudioPlaybackEnabled)
        let size = try XCTUnwrap(VNCSession(configuration: tunnel).matchingClientDisplaySize(viewSize: .zero, displayScale: 2))
        XCTAssertEqual(size.pixelWidth, 2048)
        XCTAssertEqual(size.pointHeight, 768)
    }

    func testPairAnnouncesBothDisplaysAndAdoptsTheConfirmedFramebufferExtent() throws {
        let size = PendingRemoteDisplaySize(pixelWidth: 2880, pixelHeight: 1800, pointWidth: 1440, pointHeight: 900)
        let pair = size.appleConfiguration(displayCount: 2)
        XCTAssertEqual(pair.displays.map(\.originX), [0, 2880])
        XCTAssertEqual(Set(pair.displays.map(\.identifier)).count, 2)
        XCTAssertTrue(pair.displays.allSatisfy { $0.modes.first?.pixelWidth == 2880 && $0.modes.first?.pointWidth == 1440 })
        let left = AppleDisplayInfo(displayIndex: 7, originX: -2880, originY: 0, width: 2880, height: 1800, flags: 0)
        let right = AppleDisplayInfo(displayIndex: 8, originX: 0, originY: 0, width: 2880, height: 1800, flags: 0)
        let frame = try XCTUnwrap(appleFramebufferExtent([left, right]))
        XCTAssertEqual(frame.width, 5760)
        XCTAssertEqual(frame.height, 1800)
        XCTAssertEqual(appleFramebufferExtent([right])?.width, 2880)
        XCTAssertNil(appleFramebufferExtent([]))
        let oversized = AppleDisplayInfo(displayIndex: 9, originX: 0, originY: 0, width: 80_000, height: 1800, flags: 0)
        XCTAssertNil(appleFramebufferExtent([oversized]))
    }

    func testFixedSizeSurvivesWindowRotationAndRetinaChangesWorkspace() throws {
        var computer = Computer(endpoint: try Endpoint(address: "desktop.invalid"))
        computer.quality = .adaptive
        computer.matchWindow = true
        computer.fixedDesktop = DesktopDimensions(width: 1920, height: 1080)
        let portrait = CGSize(width: 820, height: 1180)
        let landscape = CGSize(width: 1180, height: 820)
        let retina = VNCSession(configuration: computer.configuration)
        let first = try XCTUnwrap(retina.matchingClientDisplaySize(viewSize: portrait, displayScale: 2))
        XCTAssertEqual(first, retina.matchingClientDisplaySize(viewSize: landscape, displayScale: 2))
        XCTAssertEqual(first.pixelWidth, 3840)
        XCTAssertEqual(first.pointWidth, 1920)
        XCTAssertEqual(first.pointHeight, 1080)
        computer.retinaResolution = false
        let expanded = VNCSession(configuration: computer.configuration)
        let nonRetina = try XCTUnwrap(expanded.matchingClientDisplaySize(viewSize: portrait, displayScale: 2))
        XCTAssertEqual(nonRetina.pixelWidth, first.pixelWidth)
        XCTAssertEqual(nonRetina.pointWidth, nonRetina.pixelWidth)
        XCTAssertEqual(nonRetina.pointHeight, 2160)
    }

    func testDynamicResizeAndImportedFixedDimensions() throws {
        var computer = Computer(endpoint: try Endpoint(address: "desktop.invalid"))
        computer.quality = .adaptive
        computer.matchWindow = true
        let session = VNCSession(configuration: computer.configuration)
        let portrait = try XCTUnwrap(session.matchingClientDisplaySize(viewSize: CGSize(width: 820, height: 1180), displayScale: 2))
        let landscape = try XCTUnwrap(session.matchingClientDisplaySize(viewSize: CGSize(width: 1180, height: 820), displayScale: 2))
        XCTAssertGreaterThan(portrait.pixelHeight, portrait.pixelWidth)
        XCTAssertGreaterThan(landscape.pixelWidth, landscape.pixelHeight)
        let legacy = try LibraryArchive.read(LibraryArchive(computers: [computer]).encoded())
        XCTAssertNil(legacy.computers.first?.fixedDesktop)
        computer.fixedDesktop = DesktopDimensions(width: 2000, height: 1080)
        XCTAssertThrowsError(try LibraryArchive.read(LibraryArchive(computers: [computer]).encoded()))
        computer.fixedDesktop = DesktopDimensions(width: 800, height: 600)
        let fixed = VNCSession(configuration: computer.configuration)
        XCTAssertEqual(fixed.matchingClientDisplaySize(viewSize: .zero, displayScale: 1)?.pointWidth, 800)
    }

    func testPendingDynamicResizeWaitsForExplicitResumeWithoutAnotherLayout() async throws {
        try await withDynamicResizeDesktop { session, peer in
            session.updateRemoteDisplaySize(viewSize: CGSize(width: 1024, height: 640), displayScale: 2)
            session.suspendsRemoteDisplaySizeUpdates = true
            try await Task.sleep(for: .milliseconds(260))
            XCTAssertEqual(peer.requestedDesktopSizes, [])
            session.suspendsRemoteDisplaySizeUpdates = false
            try await waitForDisplayCondition { !peer.requestedDesktopSizes.isEmpty }
            XCTAssertEqual(peer.requestedDesktopSizes, [CGSize(width: 2048, height: 1280)])
        }
    }

    #if !targetEnvironment(macCatalyst)
    func testDynamicResizeSendsOnlyTheSettledSizeAfterOwningSceneActivates() async throws {
        try await withDynamicResizeDesktop { session, peer in
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            session.setHostScene(scene)
            session.updateRemoteDisplaySize(viewSize: CGSize(width: 1024, height: 640), displayScale: 2)
            NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
            session.updateRemoteDisplaySize(viewSize: CGSize(width: 1152, height: 672), displayScale: 2)
            try await Task.sleep(for: .milliseconds(260))
            XCTAssertEqual(peer.requestedDesktopSizes, [])
            NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
            session.updateRemoteDisplaySize(viewSize: CGSize(width: 1280, height: 800), displayScale: 2)
            try await waitForDisplayCondition { peer.requestedDesktopSizes.contains(CGSize(width: 2560, height: 1600)) }
            XCTAssertEqual(peer.requestedDesktopSizes, [CGSize(width: 2560, height: 1600)])
        }
    }
    #endif

    private func withDynamicResizeDesktop(
        _ check: (VNCSession, LocalTestDisplay) async throws -> Void
    ) async throws {
        let peer = LocalTestDisplay()
        peer.announcesDynamicSize = true
        let port: UInt16
        do { port = try await peer.start() }
        catch let error as NWError where error == .posix(.EPERM) || error == .posix(.EACCES) {
            throw XCTSkip("The loopback desktop requires inbound networking in the test host")
        }
        defer { peer.stop() }
        let session = VNCSession(configuration: .init(enableHighPerformanceMode: false,
                                                       videoQualityMode: .standard, displaySizingMode: .matchClient))
        defer { session.disconnect() }
        try await session.connect(credentials: .init(host: "127.0.0.1", port: port, password: ""))
        try await waitForDisplayCondition { session.hasPresentedCurrentPicture || peer.failure != nil }
        XCTAssertTrue(session.hasPresentedCurrentPicture, peer.failure ?? "The test desktop did not present a frame")
        XCTAssertTrue(peer.advertisedEncodings.contains(Encoding.extendedDesktopSize.rawValue))
        try await check(session, peer)
        XCTAssertNil(peer.failure)
    }

    private func waitForDisplayCondition(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "Timed out waiting for the test desktop")
    }
}
