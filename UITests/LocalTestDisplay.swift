import Foundation
import Network
import UIKit

/// Test-runner-only service. The accepted connection sees generated pixels and
/// never receives access to the host display, input devices or pasteboard.
@MainActor
final class LocalTestDisplay {
    private struct UnexpectedMessage: LocalizedError {
        let type: UInt8
        var errorDescription: String? { "The test display received unsupported client message \(type)." }
    }
    private let queue = DispatchQueue(label: "DeskLink.test-display")
    private var listener: NWListener?
    private var peer: NWConnection?
    private var worker: Task<Void, Never>?
    private let hasTwoMonitors: Bool
    private let servesJPEG: Bool
    private let appleScalingCapability: Bool?
    private let offersDraggedFile: Bool
    private let completesDraggedFile: Bool
    private(set) var downloadRequests = 0
    private(set) var startedFileStreams = 0
    private(set) var finishedFileStreams = 0
    var maySendRemainingFileBytes = false
    private let colors: [(UInt32, UInt32, UInt32)] = [(31,89,165),(241,183,69),(52,174,146),(223,102,88)]
    private(set) var advertisedEncodings: [Int32] = []
    private(set) var halfResolutionRequested = false
    private(set) var requestedFramebufferSize: CGSize?
    var announcesDynamicSize = false
    private(set) var requestedDesktopSizes: [CGSize] = []
    private(set) var frameCount = 0
    private(set) var acceptedConnections = 0
    var connectionsToCloseBeforeHandshake = 0
    var waitsForCancellationBeforeHandshake = false
    var withholdHandshakesAfterConnection: Int?
    var withholdFramesAfterConnection: Int?
    private(set) var overlappingConnections = 0
    private(set) var closedConnections = 0
    private(set) var clicks = 0
    private(set) var lastClickX: Int?
    private(set) var primaryPresses: [Int] = []
    private(set) var latestPointer: CGPoint?
    private(set) var heldLeftX: Set<Int> = []
    private(set) var scrollTicks = 0
    private(set) var keys = 0
    private(set) var keyDowns: [UInt32] = []
    var onWireKey: ((_ down: Bool, _ keysym: UInt32) -> Void)?
    var onWirePointer: ((_ buttons: UInt8, _ point: CGPoint) -> Void)?
    var onWirePreciseScroll: ((CGPoint) -> Void)?
    var expectsClientDisconnect = false
    private(set) var receivedClipboard = Data()
    private(set) var clipboardWrites = 0
    var sendsClipboardWithFrames = true
    private(set) var failure: String?

    init(hasTwoMonitors: Bool = false, servesJPEG: Bool = false,
         appleScalingCapability: Bool? = nil, offersDraggedFile: Bool = false, completesDraggedFile: Bool = false) {
        self.hasTwoMonitors = hasTwoMonitors
        self.servesJPEG = servesJPEG
        self.appleScalingCapability = appleScalingCapability
        self.offersDraggedFile = offersDraggedFile
        self.completesDraggedFile = completesDraggedFile
    }

    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server = try NWListener(using: parameters)
        listener = server
        server.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            server.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    server.stateUpdateHandler = nil
                    if let port = server.port { continuation.resume(returning: port.rawValue) }
                    else { continuation.resume(throwing: URLError(.cannotCreateFile)) }
                case .failed(let error):
                    server.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            server.start(queue: queue)
        }
    }

    private func accept(_ incoming: NWConnection) {
        guard listener != nil else { incoming.cancel(); return }
        guard peer == nil else {
            overlappingConnections += 1
            incoming.cancel()
            return
        }
        acceptedConnections += 1
        if acceptedConnections <= connectionsToCloseBeforeHandshake {
            incoming.start(queue: queue)
            incoming.cancel()
            closedConnections += 1
            return
        }
        let connectionNumber = acceptedConnections
        peer = incoming
        incoming.start(queue: queue)
        worker = Task {
            do { try await serve(incoming, connectionNumber: connectionNumber) }
            catch {
                // A client closing with unread framebuffer bytes can end TCP with RST.
                let expectedReset = expectsClientDisconnect && (error as? NWError) == .posix(.ECONNRESET)
                if listener != nil, failure == nil, !expectedReset, (error as? URLError)?.code != .networkConnectionLost {
                    failure = error.localizedDescription
                }
            }
            incoming.cancel()
            if peer === incoming { peer = nil }
            closedConnections += 1
        }
    }

    func dropCurrentConnection() { peer?.cancel() }

    func stop() {
        listener?.cancel()
        listener = nil
        worker?.cancel()
        peer?.cancel()
        peer = nil
    }

    func publishClipboard(_ text: String) async throws {
        guard let peer else { throw URLError(.notConnectedToInternet) }
        let bytes = Array(text.utf8)
        guard bytes.count < 256 else { throw URLError(.dataLengthExceedsMaximum) }
        try await send([3, 0, 0, 0, 0, 0, 0, UInt8(bytes.count)] + bytes, to: peer)
    }

    func ringBell() async throws {
        guard let peer else { throw URLError(.notConnectedToInternet) }
        try await send([2], to: peer)
    }

    private func serve(_ connection: NWConnection, connectionNumber: Int) async throws {
        while let lastAllowed = withholdHandshakesAfterConnection, connectionNumber > lastAllowed {
            try await Task.sleep(for: .milliseconds(50))
        }
        let version = Array((appleScalingCapability == nil ? "RFB 003.008\n" : "RFB 003.889\n").utf8)
        if waitsForCancellationBeforeHandshake {
            _ = try await read(1, from: connection)
            return
        }
        try await send(version, to: connection)
        guard try await read(12, from: connection) == version else { throw URLError(.badServerResponse) }
        try await send([1, 1], to: connection)
        guard try await read(1, from: connection) == [1] else { throw URLError(.badServerResponse) }
        try await send([0, 0, 0, 0], to: connection)
        _ = try await read(1, from: connection)
        var format: [UInt8] = [32,24,0,1,0,255,0,255,0,255,16,8,0,0,0,0]
        var name = Array("Test Display".utf8)
        if let appleScalingCapability {
            var capabilities = [UInt8](repeating: 0, count: 22)
            if appleScalingCapability { capabilities[7] = 0x80 }
            capabilities[8] = 0x04 // Type 21, automatic pasteboard subscription.
            if offersDraggedFile {
                capabilities[7] |= 0x02 // Request a download (14).
                capabilities[10] = 0xa0 // Announce a drag (32) and transfer files (34).
            }
            name = capabilities + name
        }
        let header: [UInt8] = appleScalingCapability == nil ? [0,160,0,96] : [1,64,0,192]
        try await send(header + format + [0,0,0,UInt8(name.count)] + name, to: connection)
        while !Task.isCancelled {
            let type = try await read(1, from: connection)[0]
            switch type {
            case 0:
                _ = try await read(3, from: connection)
                format = try await read(16, from: connection)
            case 2:
                let header = try await read(3, from: connection)
                let list = try await read(4 * (Int(header[1]) * 256 + Int(header[2])), from: connection)
                advertisedEncodings = stride(from: 0, to: list.count, by: 4).map { offset in
                    Int32(bitPattern: list[offset..<offset + 4].reduce(UInt32.zero) { $0 << 8 | UInt32($1) })
                }
                if announcesDynamicSize, advertisedEncodings.contains(-308) {
                    // ExtendedDesktopSize for the single 160 × 96 test display.
                    try await send([0, 0, 0, 1, 0, 0, 0, 0, 0, 160, 0, 96, 255, 255, 254, 204,
                                    1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 160, 0, 96, 0, 0, 0, 0],
                                   to: connection)
                }
            case 3:
                let request = try await read(9, from: connection)
                if request[0] == 0 {
                    while let lastAllowed = withholdFramesAfterConnection, connectionNumber > lastAllowed {
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    let width = Int(request[5]) * 256 + Int(request[6])
                    let height = Int(request[7]) * 256 + Int(request[8])
                    requestedFramebufferSize = CGSize(width: width, height: height)
                    let fullAppleDesktop = appleScalingCapability != nil && !halfResolutionRequested
                    let requestsJPEG = advertisedEncodings.contains { (-32 ... -23).contains($0) }
                    let frame = servesJPEG && requestsJPEG ? try jpegFrame() :
                        try makeFrame(format, width: fullAppleDesktop ? 320 : 160, height: fullAppleDesktop ? 192 : 96)
                    try await send(frame, to: connection)
                    frameCount += 1
                    if offersDraggedFile {
                        try await serveFileDrag(on: connection, completes: completesDraggedFile)
                        return
                    }
                    if appleScalingCapability == nil, sendsClipboardWithFrames {
                        let sample = Array("DeskLink clipboard fixture".utf8)
                        try await send([3,0,0,0,0,0,0,UInt8(sample.count)] + sample, to: connection)
                    }
                }
            case 4:
                let event = try await read(7, from: connection)
                let keysym = event.suffix(4).reduce(UInt32.zero) { $0 << 8 | UInt32($1) }
                onWireKey?(event[0] != 0, keysym)
                if event[0] != 0 {
                    keys += 1
                    keyDowns.append(keysym)
                }
            case 5:
                let event = try await read(5, from: connection)
                let x = Int(event[1]) * 256 + Int(event[2])
                let y = Int(event[3]) * 256 + Int(event[4])
                let point = CGPoint(x: x, y: y)
                onWirePointer?(event[0], point)
                latestPointer = point
                if event[0] != 0 {
                    clicks += 1
                    lastClickX = x
                    if event[0] & 1 != 0 {
                        heldLeftX.insert(x)
                        primaryPresses.append(x)
                    }
                    if event[0] & 0x78 != 0 { scrollTicks += 1 }
                }
            case 6:
                let header = try await read(7, from: connection)
                let count = header.suffix(4).reduce(0) { $0 * 256 + Int($1) }
                guard count <= 1024 else { throw URLError(.dataLengthExceedsMaximum) }
                receivedClipboard = Data(try await read(count, from: connection))
                clipboardWrites += 1
            case 8 where appleScalingCapability == true:
                let body = try await read(9, from: connection)
                guard body == [0, 0x3f, 0xe0, 0, 0, 0, 0, 0, 0] else { throw URLError(.badServerResponse) }
                halfResolutionRequested = true
            case 21 where appleScalingCapability != nil:
                _ = try await read(7, from: connection)
            case 23 where appleScalingCapability != nil:
                let header = try await read(3, from: connection)
                let count = Int(header[1]) * 256 + Int(header[2])
                guard [12, 32, 54].contains(count) else { throw URLError(.badServerResponse) }
                let event = try await read(count, from: connection)
                // The precise wheel record carries point deltas at 22...33 and coordinates at the end.
                if count == 54, event[22..<34].contains(where: { $0 != 0 }) {
                    let x = Int(event[50]) * 256 + Int(event[51])
                    let y = Int(event[52]) * 256 + Int(event[53])
                    onWirePreciseScroll?(CGPoint(x: x, y: y))
                }
            case 251 where announcesDynamicSize:
                let header = try await read(7, from: connection)
                guard header[5] == 1 else { throw URLError(.badServerResponse) }
                _ = try await read(16, from: connection)
                let width = Int(header[1]) * 256 + Int(header[2])
                let height = Int(header[3]) * 256 + Int(header[4])
                requestedDesktopSizes.append(CGSize(width: width, height: height))
            default: throw UnexpectedMessage(type: type)
            }
        }
    }

    private func makeFrame(_ format: [UInt8], width: Int, height: Int) throws -> [UInt8] {
        let stride = Int(format[0]) / 8
        guard [1, 2, 4].contains(stride), format[3] == 1 else { throw URLError(.cannotDecodeContentData) }
        var palette = [[UInt8]]()
        for (r,g,b) in colors {
            var pixel: UInt32 = 0
            for (index, value) in [r,g,b].enumerated() {
                let offset = 4 + 2 * index
                let max = UInt32(format[offset]) << 8 | UInt32(format[offset + 1])
                pixel |= (value * max / 255) << UInt32(format[10 + index])
            }
            let bytes = (0..<stride).map { UInt8(truncatingIfNeeded: pixel >> UInt32(8 * $0)) }
            palette.append(format[2] == 0 ? bytes : Array(bytes.reversed()))
        }
        var bytes: [UInt8] = [0, 0, 0, hasTwoMonitors ? 2 : 1]
        if hasTwoMonitors {
            // ExtendedDesktopSize (-308), with stable IDs unrelated to list order.
            bytes += [0,0,0,0,0,160,0,96,255,255,254,204,2,0,0,0]
            for (id, x): (UInt8, UInt8) in [(73, 0), (19, 80)] {
                bytes += [0,0,0,id, 0,x,0,0, 0,80,0,96, 0,0,0,0]
            }
        }
        bytes += [0,0,0,0,UInt8(width >> 8),UInt8(truncatingIfNeeded: width),
                  UInt8(height >> 8),UInt8(truncatingIfNeeded: height),0,0,0,0]
        bytes.reserveCapacity(16 + width * height * stride)
        for y in 0..<height {
            for x in 0..<width { bytes.append(contentsOf: palette[(y < height / 2 ? 0 : 2) + (x < width / 2 ? 0 : 1)]) }
        }
        return bytes
    }

    private func jpegFrame() throws -> [UInt8] {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 96), format: format)
        let image = renderer.jpegData(withCompressionQuality: 0.45) { context in
            for (index, rgb) in colors.enumerated() {
                UIColor(red: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255, blue: CGFloat(rgb.2) / 255, alpha: 1).setFill()
                context.fill(CGRect(x: CGFloat(index % 2 * 80), y: CGFloat(index / 2 * 48), width: 80, height: 48))
            }
        }
        guard (128..<16_384).contains(image.count) else { throw URLError(.dataLengthExceedsMaximum) }
        let length = [UInt8(image.count & 127) | 128, UInt8(image.count >> 7)]
        return [0,0,0,1, 0,0,0,0,0,160,0,96, 0,0,0,7, 0x90] + length + Array(image)
    }

    // XCTest's synchronous drag occupies the runner's main actor. The peer
    // must announce the file while the finger is down, before the release.
    nonisolated private func serveFileDrag(on connection: NWConnection, completes: Bool) async throws {
        // An independent zlib-encoded public.file-url for file:///Fixture/Gesture.txt.
        let packet = "IAAAAAAAAAMAAABaAAAAUnicY2BgYGRgYOAvKE3KyUzWS8vMSdUtLcphgACQlEByfq5eYkFBTqpefnFJZUEqUIwlDaJGGqTeSl9f3y2zoqS0KFXfPbUYROuVVJQAAKlKGAI="
        let announcement = Array(Data(base64Encoded: packet)!)
        var announced = false
        while !Task.isCancelled {
            let type = try await read(1, from: connection)[0]
            switch type {
            case 3: _ = try await read(9, from: connection)
            case 4, 21: _ = try await read(7, from: connection)
            case 5:
                let pointer = try await read(5, from: connection)
                if pointer[0] & 1 == 0 {
                    announced = false
                } else {
                    let x = Int(pointer[1]) * 256 + Int(pointer[2])
                    Task { @MainActor in self.heldLeftX.insert(x) }
                    if !announced {
                        try await send(announcement, to: connection)
                        announced = true
                    }
                }
            case 14:
                _ = try await read(7, from: connection)
                Task { @MainActor in self.downloadRequests += 1 }
                if completes { try await send(announcement, to: connection) }
            case 0x22 where completes:
                let length = try await read(5, from: connection).suffix(4).reduce(0) { $0 * 256 + Int($1) }
                guard (8...2048).contains(length) else { throw URLError(.badServerResponse) }
                let request = try await read(length, from: connection)
                if request[2...3].elementsEqual([0, 1]) {
                    try await sendDraggedFile(session: Array(request[4...7]), to: connection)
                }
            default: throw UnexpectedMessage(type: type)
            }
        }
    }

    nonisolated private func sendDraggedFile(session: [UInt8], to connection: NWConnection) async throws {
        func packet(_ command: UInt8, body: [UInt8]) -> [UInt8] {
            let length = body.count + 8
            return [0x22, 0, 0, 0, UInt8(length >> 8), UInt8(truncatingIfNeeded: length), 0, 1, 0, command]
                + session + body
        }
        let name = Array("Gesture.txt".utf8)
        let chunk = Array(repeating: UInt8(ascii: "T"), count: 32_768)
        let chunkCount = 64
        let size = chunk.count * chunkCount
        let sizeBytes = [UInt8(size >> 16), UInt8(truncatingIfNeeded: size >> 8), UInt8(truncatingIfNeeded: size)]
        var summary = [UInt8](repeating: 0, count: 48)
        summary.replaceSubrange(13...15, with: sizeBytes)
        summary[31] = 1
        try await send(packet(0x64, body: summary), to: connection)
        var item = [UInt8](repeating: 0, count: 104)
        item[0] = 1
        item.replaceSubrange(47...49, with: sizeBytes)
        item[94...95] = [0x81, 0xa4]
        item[101] = UInt8(name.count)
        try await send(packet(0x65, body: item + name + [0]), to: connection)
        let data = packet(0x66, body: [0, 0, 0x80, 0] + chunk)
        try await send(data, to: connection)
        await MainActor.run { self.startedFileStreams += 1 }
        let deadline = ContinuousClock.now + .seconds(35)
        while await !maySendRemainingFileBytes {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(50))
        }
        for _ in 1..<chunkCount { try await send(data, to: connection) }
        try await send(packet(0x68, body: []), to: connection)
        await MainActor.run { self.finishedFileStreams += 1 }
    }

    nonisolated private func read(_ count: Int, from connection: NWConnection) async throws -> [UInt8] {
        var result = [UInt8]()
        while result.count < count {
            let length = count - result.count
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: length) { data, _, _, error in
                    if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: error.map { $0 as Error } ?? URLError(.networkConnectionLost)) }
                }
            }
            result.append(contentsOf: chunk)
        }
        return result
    }

    nonisolated private func send(_ bytes: [UInt8], to connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }
}
