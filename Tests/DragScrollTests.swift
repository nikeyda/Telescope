import Network
import RFBProtocol
import UIKit
import XCTest
@testable import rootshellVNC

@MainActor final class DragScrollTests: XCTestCase {
    func testRfbWheelScrollKeepsTheDragButtonHeldAndTracksItsPosition() async throws {
        let events = try await playGestures(apple: false)
        XCTAssertEqual(events, ["1 (20, 20)", "9 (20, 20)", "1 (20, 20)",
                                "1 (32, 26)", "9 (32, 26)", "1 (32, 26)", "0 (32, 26)",
                                "0 (105, 61)", "8 (105, 61)", "0 (105, 61)"])
    }

    func testApplePreciseScrollKeepsTheDragButtonHeldAndTracksItsPosition() async throws {
        let events = try await playGestures(apple: true)
        XCTAssertEqual(events, ["1 (20, 20)", "scroll (20, 20)", "1 (32, 26)",
                                "scroll (32, 26)", "0 (32, 26)", "0 (105, 61)", "scroll (105, 61)"])
    }

    func testAppDeactivationCancelsTheDirectScrollAndAcceptsANewGesture() {
        var events: [AppleScrollEvent] = []
        let view = makeInputView(size: CGSize(width: 160, height: 96), touchHandler: TouchInputHandler(
            sendPointerEvent: { _, _, _ in }, sendScrollEvent: { events.append($0) }))
        let scroll = ScrollSample()
        scroll.point = CGPoint(x: 50, y: 38)
        scroll.deliver(.began, displacement: 15, to: view)
        XCTAssertEqual(events.last?.scrollPhase, .began)

        _ = view.perform(NSSelectorFromString("applicationWillResignActive"))
        XCTAssertEqual(events.last?.scrollPhase, .cancelled)
        let countAtDeactivation = events.count
        scroll.deliver(.changed, displacement: 80, to: view)
        XCTAssertEqual(events.count, countAtDeactivation, "Deltas from the retired scroll must stay local")

        scroll.point = CGPoint(x: 100, y: 58)
        scroll.deliver(.began, displacement: 18, to: view)
        XCTAssertEqual(events.last?.scrollPhase, .began)
        XCTAssertEqual(events.last?.x, 100)
        XCTAssertEqual(events.last?.y, 58)
        scroll.deliver(.cancelled, displacement: 18, to: view)
    }

    func testAppDeactivationEndsMomentumAndStopsProducingScrollEvents() async throws {
        var events: [AppleScrollEvent] = []
        let view = makeInputView(size: CGSize(width: 160, height: 96), touchHandler: TouchInputHandler(
            sendPointerEvent: { _, _, _ in }, sendScrollEvent: { events.append($0) }))
        let scroll = ScrollSample()
        scroll.point = CGPoint(x: 80, y: 40)
        defer {
            // Ensure the display link also stops when an older app fails the assertion below.
            scroll.deliver(.began, displacement: 0, to: view)
            scroll.deliver(.cancelled, displacement: 0, to: view)
        }
        scroll.deliver(.began, displacement: 0, to: view)
        scroll.deliver(.changed, displacement: 120, to: view)
        scroll.deliver(.ended, displacement: 120, to: view)
        XCTAssertEqual(events.last?.momentumPhase, .began)

        _ = view.perform(NSSelectorFromString("applicationWillResignActive"))
        XCTAssertEqual(events.last?.momentumPhase, .ended)
        let countAtDeactivation = events.count
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(events.count, countAtDeactivation)
    }

    private func playGestures(apple: Bool) async throws -> [String] {
        let peer = LocalTestDisplay(appleScalingCapability: apple ? false : nil)
        let port: UInt16
        do { port = try await peer.start() }
        catch let error as NWError where error == .posix(.EPERM) || error == .posix(.EACCES) {
            throw XCTSkip("The loopback desktop requires inbound networking in the test host")
        }
        defer { peer.stop() }
        let session = VNCSession(configuration: .init(enableHighPerformanceMode: false, videoQualityMode: .standard))
        defer { session.disconnect() }
        try await session.connect(credentials: .init(host: "127.0.0.1", port: port, password: ""))
        let connectionDeadline = ContinuousClock.now + .seconds(5)
        while !session.connectionState.isConnected, peer.failure == nil, ContinuousClock.now < connectionDeadline {
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertTrue(session.connectionState.isConnected, peer.failure ?? "The test desktop did not finish connecting")

        var events: [String] = []
        peer.onWirePointer = { mask, point in events.append("\(mask) (\(Int(point.x)), \(Int(point.y)))") }
        peer.onWirePreciseScroll = { point in events.append("scroll (\(Int(point.x)), \(Int(point.y)))") }
        let size = apple ? CGSize(width: 320, height: 192) : CGSize(width: 160, height: 96)
        let view = makeInputView(size: size, touchHandler: TouchInputHandler(sendPointerEvent: { mask, x, y in
            session.sendPointerEvent(buttonMask: mask, x: x, y: y)
        }, sendScrollEvent: session.sendScrollEvent, sendGestureEvent: session.sendGestureEvent))

        #if targetEnvironment(macCatalyst)
        let recognizers = try XCTUnwrap(view.gestureRecognizers)
        let nativeScroll = try XCTUnwrap(recognizers.compactMap { $0 as? UIPanGestureRecognizer }
            .first { $0.allowedScrollTypesMask == .all })
        let mouseDrag = try XCTUnwrap(recognizers.compactMap { $0 as? UILongPressGestureRecognizer }
            .first { $0.minimumPressDuration == 0 && $0.allowedTouchTypes.contains(NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)) })
        XCTAssertTrue(view.gestureRecognizer(nativeScroll, shouldRecognizeSimultaneouslyWith: mouseDrag))
        XCTAssertTrue(view.gestureRecognizer(mouseDrag, shouldRecognizeSimultaneouslyWith: nativeScroll))
        #endif

        // Drive the view's gesture actions with deterministic states while the real transport sends to the test desktop.
        let drag = DragSample()
        let scroll = ScrollSample()
        let dragAction = NSSelectorFromString("handlePointerDrag:")
        let scrollAction = NSSelectorFromString("handleNativeScrollState:")
        drag.sampleState = .began
        drag.point = CGPoint(x: 20, y: 20)
        _ = view.perform(dragAction, with: drag)
        scroll.sampleState = .began
        scroll.point = CGPoint(x: 120, y: 70)
        scroll.displacement = CGPoint(x: 0, y: 10)
        _ = view.perform(scrollAction, with: scroll)
        drag.sampleState = .changed
        drag.point = CGPoint(x: 32, y: 26)
        _ = view.perform(dragAction, with: drag)
        scroll.sampleState = .changed
        scroll.displacement = CGPoint(x: 0, y: 20)
        _ = view.perform(scrollAction, with: scroll)
        scroll.sampleState = .cancelled
        _ = view.perform(scrollAction, with: scroll)
        drag.sampleState = .ended
        _ = view.perform(dragAction, with: drag)
        scroll.sampleState = .began
        scroll.point = CGPoint(x: 105, y: 61)
        scroll.displacement = CGPoint(x: 0, y: 10)
        _ = view.perform(scrollAction, with: scroll)
        scroll.sampleState = .cancelled
        _ = view.perform(scrollAction, with: scroll)
        await session.flushPendingInput()
        let deadline = ContinuousClock.now + .seconds(2)
        while events.count < (apple ? 7 : 10), peer.failure == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertNil(peer.failure)
        let attachment = XCTAttachment(string: events.joined(separator: "\n"))
        attachment.name = apple ? "Apple precise drag and scroll" : "RFB drag and scroll"
        attachment.lifetime = .keepAlways
        add(attachment)
        return events
    }

    private func makeInputView(size: CGSize, touchHandler: TouchInputHandler) -> RemoteInputUIView {
        let view = RemoteInputUIView(touchHandler: touchHandler, keyboardHandler: KeyboardInputHandler(sendKeyEvent: { _, _ in }),
                                    keyboardCapture: VNCKeyboardCapture(), requestPasswordSend: {}, requestDictation: {},
                                    toggleFullScreen: nil, disconnect: {})
        view.frame = CGRect(origin: .zero, size: size)
        view.update(framebufferSize: size, viewport: RemoteViewportState(), viewportPanningMode: .edge,
                    pointerMode: .direct, pointerSpeed: 1, cursorHeight: 20, serverRendersCursor: false,
                    showsLocalCursorDot: false, touchGestures: .standard, keyboardActive: false,
                    keyboardCaptured: false, inputViewsGeneration: 0, controlOptionAsCommand: false,
                    localOptionKey: .off, swapsHardwareCommandAndControl: false, keyRepeat: .init(),
                    framebufferOrigin: .zero, requestPasswordSend: {}, requestDictation: {},
                    toggleFullScreen: nil, disconnect: {}, remoteCursor: nil, remoteCursorPresence: .undescribed,
                    usesFallbackCursor: false)
        return view
    }
}

private final class DragSample: UILongPressGestureRecognizer {
    var sampleState: State = .possible
    var point = CGPoint.zero
    override var state: State { get { sampleState } set { sampleState = newValue } }
    override func location(in view: UIView?) -> CGPoint { point }
}

private final class ScrollSample: UIPanGestureRecognizer {
    var sampleState: State = .possible
    var point = CGPoint.zero
    var displacement = CGPoint.zero
    override var state: State { get { sampleState } set { sampleState = newValue } }
    override func location(in view: UIView?) -> CGPoint { point }
    override func translation(in view: UIView?) -> CGPoint { displacement }

    func deliver(_ state: State, displacement: CGFloat, to view: RemoteInputUIView) {
        sampleState = state
        self.displacement = CGPoint(x: 0, y: displacement)
        _ = view.perform(NSSelectorFromString("handleNativeScrollState:"), with: self)
    }
}
