import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import OSLog
import QuartzCore

private let airPlayDiagnosticLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "autocore", category: "AirPlay")

enum ReceiverAspectMode: String, CaseIterable, Identifiable {
    case fit
    case fill

    var id: String { rawValue }
}

enum DirectAirPlayState: Equatable {
    case idle
    case discoverable
    case connecting
    case playing
    case disconnected(String)

    var title: String {
        switch self {
        case .idle: return "Receiver stopped"
        case .discoverable: return "Ready for AirPlay"
        case .connecting: return "iPhone connecting"
        case .playing: return "iPhone connected"
        case .disconnected: return "Disconnected"
        }
    }

    var symbolName: String {
        switch self {
        case .idle: return "pause.circle"
        case .discoverable: return "airplayvideo"
        case .connecting: return "dot.radiowaves.left.and.right"
        case .playing: return "iphone.radiowaves.left.and.right"
        case .disconnected: return "exclamationmark.triangle"
        }
    }
}

/// A file lock keeps AirPlay names distinct across both windows and separate
/// `open -n` processes. Keep the file after closing: removing an in-use lock
/// file could let another process claim the same receiver name.
final class AirPlayReceiverIdentityLease {
    let suffix: String
    private let descriptor: Int32

    private init(suffix: String, descriptor: Int32) {
        self.suffix = suffix
        self.descriptor = descriptor
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        _ = Darwin.close(descriptor)
    }

    /// AirPlay names that are easy to tell apart on the iPhone: the first
    /// window is <App>#1111, then #2222 … #9999, then #1122, #1133 …
    /// #2211, #2233 and so on.
    static let codes: [String] = {
        let digits = Array("123456789")
        let same = digits.map { String(repeating: $0, count: 4) }
        let pairs = digits.flatMap { first in
            digits.filter { $0 != first }.map { "\(first)\(first)\($0)\($0)" }
        }
        return same + pairs
    }()

    static func acquire(codes: [String], in directory: URL) -> AirPlayReceiverIdentityLease? {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        for suffix in codes {
            let path = directory.appendingPathComponent("receiver-\(suffix).lock").path
            let descriptor = path.withCString { Darwin.open($0, O_CREAT | O_RDWR, 0o600) }
            guard descriptor >= 0 else { continue }
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                return AirPlayReceiverIdentityLease(suffix: suffix, descriptor: descriptor)
            }
            _ = Darwin.close(descriptor)
        }
        return nil
    }

    static func acquire(preferredSuffix: String, in directory: URL) -> AirPlayReceiverIdentityLease? {
        guard preferredSuffix.count == 4,
              preferredSuffix.allSatisfy(\.isNumber),
              let preferred = Int(preferredSuffix) else { return nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        for offset in 0..<10_000 {
            let suffix = String(format: "%04d", (preferred + offset) % 10_000)
            let path = directory.appendingPathComponent("receiver-\(suffix).lock").path
            let descriptor = path.withCString { Darwin.open($0, O_CREAT | O_RDWR, 0o600) }
            guard descriptor >= 0 else { continue }
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                return AirPlayReceiverIdentityLease(suffix: suffix, descriptor: descriptor)
            }
            _ = Darwin.close(descriptor)
        }
        return nil
    }
}

final class DirectAirPlayReceiver: NSObject, ObservableObject {
    @Published private(set) var state: DirectAirPlayState = .idle
    @Published private(set) var receiverName: String
    /// The number in the AirPlay name, shown big while waiting for the iPhone.
    var receiverCode: String { receiverName.components(separatedBy: "#").last ?? receiverName }
    @Published private(set) var listeningPort: UInt16?
    @Published private(set) var senderHost: String?
    @Published private(set) var senderScopeID: UInt32 = 0
    @Published private(set) var isRunning = false
    @Published private(set) var hasFrame = false
    @Published private(set) var videoSize = CGSize(width: 9, height: 16)
    @Published private(set) var framesPerSecond: Double = 0

    let renderSurface = MirrorRenderSurface()

    private let frameLock = NSLock()
    private let identityLease: AirPlayReceiverIdentityLease?
    private var latestPixelBuffer: CVPixelBuffer?

    private lazy var decoder = MirrorVideoDecoder { [weak self] decodedFrame in
        self?.consume(decodedFrame)
    }
    private var bridge: AirPlayReceiverCoreBridge?
    private var frameCount = 0
    private var frameIntervalStart = CACurrentMediaTime()
    private var disconnectToken = UUID()

    override init() {
        let suffix = Self.preferredReceiverSuffix()
        let locks = AppData.shared.appendingPathComponent("ReceiverLocks", isDirectory: true)
        identityLease = AirPlayReceiverIdentityLease.acquire(codes: AirPlayReceiverIdentityLease.codes, in: locks)
            ?? AirPlayReceiverIdentityLease.acquire(preferredSuffix: suffix, in: locks)
        receiverName = "\(AppBrand.current.name)#\(identityLease?.suffix ?? String(UUID().uuidString.prefix(8)))"
        super.init()

        DispatchQueue.main.async { [weak self] in
            // Demo and test hosts must never advertise AirPlay next to the real app.
            guard !AppData.isDemoProcess, !AppData.isTestProcess else { return }
            self?.startReceiver()
        }
    }

    deinit {
        bridge?.stop()
        decoder.reset()
    }

    var instruction: String {
        switch state {
        case .idle:
            return "Start the receiver to make this Mac visible to your iPhone."
        case .discoverable:
            return "On iPhone: Control Center › Screen Mirroring › \(receiverName)"
        case .connecting:
            return "The iPhone found this Mac. Waiting for the first video frame…"
        case .playing:
            return String(format: "Live AirPlay · %.0f fps", framesPerSecond)
        case let .disconnected(message):
            return message
        }
    }

    func applyDemoMirror(_ playing: Bool) {
        guard AppData.isDemoProcess else { return }
        state = playing ? .playing : .discoverable
        hasFrame = playing
        videoSize = CGSize(width: 998, height: 2160)
        senderHost = playing ? "192.168.1.42" : nil
    }

    func startReceiver() {
        guard bridge?.isRunning != true else {
            isRunning = true
            return
        }

        let configuration = AirPlayReceiverCoreConfiguration()
        configuration.receiverName = receiverName
        configuration.displaySize = CGSize(width: 3840, height: 2160)
        configuration.scale = 1
        configuration.refreshRate = 60

        let newBridge = AirPlayReceiverCoreBridge(delegate: self)
        do {
            try newBridge.start(with: configuration)
            bridge = newBridge
            listeningPort = newBridge.port
            isRunning = true
            state = .discoverable
        } catch {
            bridge = nil
            listeningPort = nil
            isRunning = false
            state = .disconnected(error.localizedDescription)
        }
    }

    func stopReceiver() {
        bridge?.stop()
        bridge = nil
        listeningPort = nil
        senderHost = nil
        senderScopeID = 0
        isRunning = false
        resetVideo()
        state = .idle
    }

    func restartReceiver() {
        stopReceiver()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.startReceiver()
        }
    }

    private func consume(_ decodedFrame: MirrorDecodedFrame) {
        frameLock.lock()
        latestPixelBuffer = decodedFrame.pixelBuffer
        frameSerial &+= 1
        frameLock.unlock()
        renderSurface.enqueue(decodedFrame.sampleBuffer)

        let width = CVPixelBufferGetWidth(decodedFrame.pixelBuffer)
        let height = CVPixelBufferGetHeight(decodedFrame.pixelBuffer)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.videoSize = CGSize(width: width, height: height)
            self.hasFrame = true
            self.state = .playing
        }
    }

    private func noteIncomingFrame() {
        frameCount += 1
        let now = CACurrentMediaTime()
        let elapsed = now - frameIntervalStart
        guard elapsed >= 1 else { return }

        framesPerSecond = Double(frameCount) / elapsed
        frameCount = 0
        frameIntervalStart = now
    }

    private func resetVideo() {
        frameLock.lock()
        latestPixelBuffer = nil
        frameLock.unlock()
        decoder.reset()
        renderSurface.flush()
        hasFrame = false
        framesPerSecond = 0
        frameCount = 0
        frameIntervalStart = CACurrentMediaTime()
        videoSize = CGSize(width: 9, height: 16)
    }

    /// Vision reads the same decoded AirPlay frame as the visible canvas.
    /// This does not capture the Mac display or use WebDriverAgent screenshots.
    func currentPixelBuffer() -> CVPixelBuffer? {
        frameLock.lock()
        defer { frameLock.unlock() }
        return latestPixelBuffer
    }

    /// Goes up with every decoded frame, so the Remote sends only new ones.
    private var frameSerial: UInt64 = 0

    func currentFrame() -> (buffer: CVPixelBuffer, serial: UInt64)? {
        frameLock.lock()
        defer { frameLock.unlock() }
        return latestPixelBuffer.map { ($0, frameSerial) }
    }

    /// Export only a frame received through AirPlay for local diagnostics.
    /// No macOS display capture or WebDriverAgent screenshot is involved.
    func exportCurrentFrame() throws -> URL {
        guard let pixelBuffer = currentPixelBuffer() else {
            throw NSError(domain: AppBrand.current.name, code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "No AirPlay frame is available yet"])
        }
        let url = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("frame-\(UUID().uuidString).png")
        try CIContext().writePNGRepresentation(
            of: CIImage(cvPixelBuffer: pixelBuffer),
            to: url,
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return url
    }

    private func handleDisconnect(_ reason: String?) {
        resetVideo()
        senderHost = nil
        senderScopeID = 0
        let message = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        state = .disconnected(message?.isEmpty == false ? message! : "The iPhone stopped mirroring.")

        let token = UUID()
        disconnectToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard
                let self,
                self.disconnectToken == token,
                self.bridge?.isRunning == true
            else {
                return
            }
            self.state = .discoverable
        }
    }

    private static func preferredReceiverSuffix() -> String {
        let key = AppBrand.key("receiverSuffix")
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: key), existing.count == 4 { return existing }
        let suffix = String(format: "%04d", Int.random(in: 0...9999))
        defaults.set(suffix, forKey: key)
        return suffix
    }
}

extension DirectAirPlayReceiver: AirPlayReceiverCoreBridgeDelegate {
    func receiverBridge(_ bridge: AirPlayReceiverCoreBridge, didUpdateDiscoverabilityOnPort port: UInt16) {
        listeningPort = port
        isRunning = true
        state = .discoverable
    }

    func receiverBridge(_ bridge: AirPlayReceiverCoreBridge,
                        didStartConnectingFromHost host: String?, scopeID: UInt32) {
        disconnectToken = UUID()
        resetVideo()
        senderHost = host
        senderScopeID = scopeID
        state = .connecting
    }

    func receiverBridgeDidDisconnect(_ bridge: AirPlayReceiverCoreBridge, reason: String?) {
        handleDisconnect(reason)
    }

    func receiverBridgeDidFlushAudio(_ bridge: AirPlayReceiverCoreBridge) {}

    func receiverBridgeDidFlushVideo(_ bridge: AirPlayReceiverCoreBridge) {
        resetVideo()
    }

    func receiverBridge(
        _ bridge: AirPlayReceiverCoreBridge,
        didReceiveAudioPacket packet: Data,
        ptsMicroseconds: UInt64
    ) {}

    func receiverBridge(
        _ bridge: AirPlayReceiverCoreBridge,
        didReceiveParameterSetsWithSPS sps: Data,
        pps: Data
    ) {
        NSLog("AirPlay: received H.264 configuration (SPS=%lu, PPS=%lu, types=%u/%u)",
              sps.count, pps.count, UInt32(sps.first ?? 0) & 0x1f,
              UInt32(pps.first ?? 0) & 0x1f)
        decoder.submitParameterSets(sps: sps, pps: pps)
    }

    func receiverBridge(
        _ bridge: AirPlayReceiverCoreBridge,
        didReceiveFrame frame: Data,
        ptsMicroseconds: UInt64
    ) {
        decoder.submitFrame(frame, ptsMicroseconds: ptsMicroseconds)
        DispatchQueue.main.async { [weak self] in
            self?.noteIncomingFrame()
        }
    }

    func receiverBridge(_ bridge: AirPlayReceiverCoreBridge, didUpdateAudioVolume volume: Float) {}

    func receiverBridge(
        _ bridge: AirPlayReceiverCoreBridge,
        didLogMessage message: String,
        level: AirPlayReceiverCoreLogLevel
    ) {
        if message.hasPrefix("Handling request ") {
            let parts = message.split(separator: " ")
            if parts.count >= 3 {
                let method = String(parts[2])
                let path = parts.last.map(String.init) ?? ""
                let knownPaths: Set<String> = ["/info", "/pair-setup", "/pair-verify", "/fp-setup", "/feedback"]
                NSLog("AirPlay core: RTSP %@ %@", method, knownPaths.contains(path) ? path : "")
                airPlayDiagnosticLog.notice("RTSP \(method, privacy: .public) \(knownPaths.contains(path) ? path : "", privacy: .public)")
            }
            return
        }
        let connectionMilestones = [
            "Accepted IPv4 client", "Accepted IPv6 client", "SETUP 1",
            "type = ", "Mirroring initialized successfully",
            "Mirroring video TCP client connected", "Destroying connection",
            "raop_ntp send_len = ", "raop_ntp receive time type_t packetlen = ",
            "raop_rtp_mirror exiting TCP thread", "Connection closed for socket",
            "Mirroring video TCP client disconnected", "Empty mirror packet"
        ]
        if level.rawValue <= AirPlayReceiverCoreLogLevel.warning.rawValue ||
            message.contains("AVC configuration") ||
            connectionMilestones.contains(where: message.hasPrefix) {
            NSLog("AirPlay core: %@", message)
            airPlayDiagnosticLog.notice("\(message, privacy: .public)")
        }
    }
}
