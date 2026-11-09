import AppKit
import Combine
import CoreImage
import CryptoKit
import Foundation
import Network

/// An iPhone allowed to control the app.
struct PairedRemote: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var model: String
    var key: Data
    var pairedAt: Date
    var lastSeen: Date?
}

/// Paired Remotes, in a file only this user can read.
enum RemotePairingStore {
    static var url: URL { AppData.shared.appendingPathComponent("remotes.json") }

    static func load() -> [PairedRemote] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder.remote.decode([PairedRemote].self, from: data)) ?? []
    }

    static func save(_ remotes: [PairedRemote]) {
        guard let data = try? JSONEncoder.remote.encode(remotes) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// This Mac, as Remotes remember it.
    static var macID: UUID {
        let key = AppBrand.key("remoteMacID")
        if let stored = AppData.preferences.string(forKey: key), let id = UUID(uuidString: stored) { return id }
        let id = UUID()
        AppData.preferences.set(id.uuidString, forKey: key)
        return id
    }
}

struct RemotePairingRequest: Identifiable, Equatable {
    let id: UUID
    let name: String
    let model: String
    let code: String
}

/// One connected Remote.
@MainActor
final class RemoteSession {
    enum Phase {
        case hello
        case pairing(shared: SharedSecret, hello: RemoteHello, serverNonce: Data)
        case active
    }

    let id = UUID()
    let link: RemoteLink
    var phase = Phase.hello
    var remoteID: UUID?
    var name = ""
    var watchWindow: UUID?
    var frames = false
    var framesInFlight = 0
    var lastFrameSerial: UInt64 = 0
    var lastState: Data?
    /// Values this Remote keeps for itself (see `RemotePanelBuilder.local`).
    var local: [String: String] = [:]
    var setters: [String: (RemoteValue) -> Void] = [:]
    var actions: [String: () -> Void] = [:]
    /// The builder of the panels on screen: its buttons refer to it, so it
    /// lives until the next update replaces it.
    var builder: RemotePanelBuilder?
    let openedAt = Date()

    init(link: RemoteLink) { self.link = link }

    var isActive: Bool {
        if case .active = phase { return true }
        return false
    }

    func send(_ event: RemoteEvent) {
        guard let payload = RemotePayload.json(event) else { return }
        link.send(payload)
    }
}

/// Lets the Remote on an iPhone see and steer this Mac's app over the
/// local network. Off in demo and test processes; a Remote needs to be
/// allowed once on the Mac, with matching codes on both screens.
@MainActor
final class RemoteServer: ObservableObject {
    static let shared = RemoteServer()

    @Published private(set) var remotes: [PairedRemote] = RemotePairingStore.load()
    /// Remotes connected right now.
    @Published private(set) var connected: Set<UUID> = []
    @Published var pairingRequest: RemotePairingRequest?
    @Published private(set) var status = NSLocalizedString("Off", comment: "Remote status")
    @Published var isEnabled: Bool = AppData.preferences.object(forKey: AppBrand.key("remoteEnabled")) as? Bool ?? true {
        didSet {
            guard isEnabled != oldValue else { return }
            AppData.preferences.set(isEnabled, forKey: AppBrand.key("remoteEnabled"))
            isEnabled ? start() : stop()
        }
    }

    private var listener: NWListener?
    private var sessions: [UUID: RemoteSession] = [:]
    private var stateTask: Task<Void, Never>?
    private var frameTask: Task<Void, Never>?
    private let frames = RemoteFrameEncoder()
    /// Per window: the last encoded frame.
    private var frameCache: [UUID: (serial: UInt64, jpeg: Data)] = [:]
    private var encoding: Set<UUID> = []
    private var restartTask: Task<Void, Never>?

    static var macName: String {
        // Demo screenshots show no real Mac name.
        AppData.isDemoProcess ? "MacBook Pro" : Host.current().localizedName ?? "Mac"
    }

    /// Never in tests; in a demo only with `--remote-server`, to try the
    /// Remote against sample data.
    private var mayListen: Bool {
        !AppData.isTestProcess
            && (!AppData.isDemoProcess || CommandLine.arguments.contains("--remote-server"))
    }

    func startIfEnabled() {
        guard isEnabled, mayListen else { return }
        start()
    }

    private func start() {
        guard listener == nil, mayListen else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = false
            let listener = try NWListener(using: parameters)
            var txt = NWTXTRecord()
            txt["id"] = RemotePairingStore.macID.uuidString
            txt["v"] = "\(RemoteWire.version)"
            listener.service = NWListener.Service(name: Self.macName, type: RemoteWire.serviceType, domain: nil,
                                                  txtRecord: txt)
            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.listenerChanged(state) }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.accept(connection) }
                }
            }
            self.listener = listener
            status = NSLocalizedString("Starting…", comment: "Remote status")
            listener.start(queue: DispatchQueue(label: "autocore.remote.listener"))
        } catch {
            status = error.localizedDescription
        }
        startLoops()
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        for session in sessions.values { session.link.close("The Remote was turned off on the Mac") }
        sessions.removeAll()
        connected.removeAll()
        pairingRequest = nil
        stateTask?.cancel()
        frameTask?.cancel()
        stateTask = nil
        frameTask = nil
        status = NSLocalizedString("Off", comment: "Remote status")
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            status = NSLocalizedString("Ready on this Wi-Fi", comment: "Remote status")
        case let .failed(error):
            status = error.localizedDescription
            listener?.cancel()
            listener = nil
            // Network changes (sleep, Wi-Fi) end the listener; try again.
            restartTask?.cancel()
            restartTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self, self.isEnabled, self.listener == nil else { return }
                self.start()
            }
        default:
            break
        }
    }

    // MARK: - Pairing

    func approvePairing() {
        guard let request = pairingRequest, let session = sessions[request.id],
              case let .pairing(shared, hello, serverNonce) = session.phase else {
            pairingRequest = nil
            return
        }
        pairingRequest = nil
        let key = RemoteCipher.pairKey(shared: shared, clientNonce: hello.nonce, serverNonce: serverNonce)
        remotes.removeAll { $0.id == hello.remoteID }
        remotes.append(PairedRemote(id: hello.remoteID, name: hello.name, model: hello.model, key: key,
                                    pairedAt: Date(), lastSeen: Date()))
        RemotePairingStore.save(remotes)
        session.send(.paired(macID: RemotePairingStore.macID))
        log("Paired \(hello.name)")
        let link = session.link
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            link.close(nil)
        }
    }

    func declinePairing() {
        guard let request = pairingRequest else { return }
        pairingRequest = nil
        guard let session = sessions[request.id] else { return }
        session.send(.result(ok: false, message: NSLocalizedString("Not allowed on the Mac.", comment: "Remote pairing")))
        let link = session.link
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            link.close(nil)
        }
    }

    func forget(_ remote: PairedRemote) {
        remotes.removeAll { $0.id == remote.id }
        RemotePairingStore.save(remotes)
        for session in sessions.values where session.remoteID == remote.id {
            session.link.close("Removed on the Mac")
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        guard sessions.count < 8 else { connection.cancel(); return }
        let link = RemoteLink(connection: connection, label: "mac")
        let session = RemoteSession(link: link)
        let id = session.id
        sessions[id] = session
        link.onMessage = { [weak self] data in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(data, session: id) }
            }
        }
        link.onClose = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.closed(id) }
            }
        }
        link.start()
        // Whoever does not finish the handshake soon is dropped.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, let session = self.sessions[id], case .hello = session.phase else { return }
            session.link.close("No hello")
        }
    }

    private func closed(_ id: UUID) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        if pairingRequest?.id == id { pairingRequest = nil }
        if let remote = session.remoteID, session.isActive,
           !sessions.values.contains(where: { $0.remoteID == remote && $0.isActive }) {
            connected.remove(remote)
        }
    }

    private func receive(_ data: Data, session id: UUID) {
        guard let session = sessions[id] else { return }
        switch session.phase {
        case .hello:
            hello(data, session: session)
        case .pairing:
            // Only pings until the Mac answers.
            break
        case .active:
            guard case let .json(body)? = RemotePayload.decode(data),
                  let command = try? JSONDecoder.remote.decode(RemoteCommand.self, from: body) else { return }
            handle(command, session: session)
        }
    }

    private func hello(_ data: Data, session: RemoteSession) {
        guard let hello = try? JSONDecoder.remote.decode(RemoteHello.self, from: data),
              let clientKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: hello.publicKey),
              hello.nonce.count == 16, hello.name.count <= 80 else {
            session.link.close("Unreadable hello")
            return
        }
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let serverNonce = RemoteCipher.randomNonce()
        guard hello.version == RemoteWire.version,
              let shared = try? privateKey.sharedSecretFromKeyAgreement(with: clientKey) else {
            session.link.sendJSON(RemoteWelcome(version: RemoteWire.version, macID: RemotePairingStore.macID, macName: Self.macName,
                                                mode: .rejected, publicKey: privateKey.publicKey.rawRepresentation,
                                                nonce: serverNonce,
                                                message: String(format: NSLocalizedString("Update %@ and its Remote to the same version.", comment: "Remote"), AppBrand.current.name)))
            session.link.close(nil)
            return
        }
        session.remoteID = hello.remoteID
        session.name = hello.name
        let known = remotes.first { $0.id == hello.remoteID }
        if let known, hello.hasKey {
            session.link.sendJSONThenEncrypt(
                RemoteWelcome(version: RemoteWire.version, macID: RemotePairingStore.macID, macName: Self.macName,
                              mode: .session, publicKey: privateKey.publicKey.rawRepresentation, nonce: serverNonce, message: nil),
                with: RemoteCipher(shared: shared, pairKey: known.key, clientNonce: hello.nonce,
                                   serverNonce: serverNonce, isServer: true))
            // Counted as connected with its first readable command.
            session.phase = .active
            return
        }
        guard pairingRequest == nil else {
            session.link.sendJSON(RemoteWelcome(version: RemoteWire.version, macID: RemotePairingStore.macID, macName: Self.macName,
                                                mode: .rejected, publicKey: privateKey.publicKey.rawRepresentation,
                                                nonce: serverNonce,
                                                message: NSLocalizedString("Another iPhone is pairing. Try again in a moment.", comment: "Remote")))
            session.link.close(nil)
            return
        }
        session.link.sendJSONThenEncrypt(
            RemoteWelcome(version: RemoteWire.version, macID: RemotePairingStore.macID, macName: Self.macName,
                          mode: .pairing, publicKey: privateKey.publicKey.rawRepresentation, nonce: serverNonce, message: nil),
            with: RemoteCipher(shared: shared, pairKey: nil, clientNonce: hello.nonce, serverNonce: serverNonce, isServer: true))
        session.phase = .pairing(shared: shared, hello: hello, serverNonce: serverNonce)
        pairingRequest = RemotePairingRequest(id: session.id, name: hello.name, model: hello.model,
                                              code: RemoteCipher.pairingCode(shared: shared, clientNonce: hello.nonce,
                                                                             serverNonce: serverNonce))
        log("Pairing request from \(hello.name)")
        // Screenshots and tests of the Remote against sample data only.
        if AppData.isDemoProcess, CommandLine.arguments.contains("--remote-auto-allow") {
            approvePairing()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.requestUserAttention(.criticalRequest)
    }

    // MARK: - Commands

    private func handle(_ command: RemoteCommand, session: RemoteSession) {
        if let remote = session.remoteID, !connected.contains(remote) {
            connected.insert(remote)
            if let index = remotes.firstIndex(where: { $0.id == remote }) {
                remotes[index].lastSeen = Date()
                RemotePairingStore.save(remotes)
            }
            log("\(session.name) connected")
        }
        switch command {
        case let .watch(window, mode, frames):
            if session.watchWindow != window || session.frames != frames {
                session.framesInFlight = 0
                session.lastFrameSerial = 0
            }
            session.watchWindow = window
            session.frames = frames
            if let mode, let model = model(window), model.lockedMode == nil, model.selectedMode != mode,
               model.tools.modes.contains(where: { $0.id == mode }) {
                // Both show the same tab.
                AppData.preferences.set(mode, forKey: model.selectedModeKey)
            }
            push(session, force: true)
        case .frameReceived:
            session.framesInFlight = max(0, session.framesInFlight - 1)
        case let .tap(window, x, y):
            manual(window, session: session) { model in
                try await model.manual(.tap(NormalizedPoint(x: x, y: y)))
            }
        case let .drag(window, fromX, fromY, toX, toY, duration):
            manual(window, session: session) { model in
                try await model.manual(.drag(from: NormalizedPoint(x: fromX, y: fromY), to: NormalizedPoint(x: toX, y: toY),
                                             duration: min(max(duration, 0.1), 2)))
            }
        case let .type(window, text):
            manual(window, session: session) { model in try await model.manual(.type(String(text.prefix(200)))) }
        case let .set(window, key, value):
            guard window == session.watchWindow, let setter = session.setters[key] else {
                session.send(.result(ok: false, message: NSLocalizedString("This setting changed on the Mac. Try again.", comment: "Remote")))
                return
            }
            setter(value)
            push(session, force: true)
        case let .action(window, id):
            guard window == session.watchWindow, let action = session.actions[id] else {
                session.send(.result(ok: false, message: NSLocalizedString("This button changed on the Mac. Try again.", comment: "Remote")))
                return
            }
            action()
            log("\(session.name): \(id)")
            // Some actions take a moment to show.
            push(session, force: true)
            Task { [weak self, weak session] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let self, let session else { return }
                self.push(session, force: true)
            }
        case .ping:
            session.send(.pong)
        }
    }

    private func manual(_ window: UUID, session: RemoteSession, _ gesture: @escaping (AppModel) async throws -> Void) {
        guard let model = model(window) else { return }
        guard !model.isBusy else {
            session.send(.result(ok: false, message: NSLocalizedString("Stop automation before manual control", comment: "Manual touch status")))
            return
        }
        guard model.controlPhase == .ready else {
            session.send(.result(ok: false, message: NSLocalizedString("Touch control is not ready yet.", comment: "Remote")))
            return
        }
        Task { [weak session] in
            do {
                try await gesture(model)
            } catch {
                session?.send(.result(ok: false, message: error.localizedDescription))
            }
        }
    }

    private func model(_ id: UUID?) -> AppModel? {
        let models = WindowRegistry.shared.models
        guard let id else { return models.first }
        return models.first { $0.windowID == id }
    }

    // MARK: - State

    private func startLoops() {
        if stateTask == nil {
            stateTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard let self else { return }
                    for session in self.sessions.values where session.isActive { self.push(session, force: false) }
                }
            }
        }
        if frameTask == nil {
            frameTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    self?.pumpFrames()
                }
            }
        }
    }

    private func push(_ session: RemoteSession, force: Bool) {
        guard session.isActive, !(session.link.pendingCount > 4 && !force) else { return }
        let models = WindowRegistry.shared.models
        // A closed window: show the first one instead.
        if let id = session.watchWindow, !models.contains(where: { $0.windowID == id }) {
            session.watchWindow = nil
            session.framesInFlight = 0
            session.lastFrameSerial = 0
        }
        let watched = model(session.watchWindow)
        var state = RemoteState(macName: Self.macName,
                                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                                windows: models.map(RemotePanelBuilder.summary))
        if let watched {
            let builder = RemotePanelBuilder(model: watched, local: session.local)
            let mode = watched.selectedMode
            state.window = watched.windowID
            state.mode = mode
            state.panel = builder.panel(for: mode)
            state.setup = builder.setup()
            var setters = builder.setters
            // Values the Remote keeps for itself, not Mac settings.
            for key in builder.localKeys {
                setters[key] = { [weak session] value in
                    if case let .string(text) = value { session?.local[key] = String(text.prefix(30)) }
                }
            }
            session.setters = setters
            session.actions = builder.actions
            session.builder = builder
            if session.watchWindow == nil { session.watchWindow = watched.windowID }
        }
        guard let data = RemotePayload.json(RemoteEvent.state(state)) else { return }
        guard force || data != session.lastState else { return }
        session.lastState = data
        session.link.send(data)
    }

    // MARK: - Mirror frames

    /// The `--ui-demo-image` picture as the demo's mirror.
    private lazy var demoJPEG: Data? = {
        guard AppData.isDemoProcess,
              let index = CommandLine.arguments.firstIndex(of: "--ui-demo-image"),
              CommandLine.arguments.indices.contains(index + 1),
              let image = NSImage(contentsOfFile: CommandLine.arguments[index + 1]),
              let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.6])
    }()

    private func pumpFrames() {
        if AppData.isDemoProcess {
            for session in sessions.values where session.isActive && session.frames && session.lastFrameSerial != 1 {
                guard let jpeg = demoJPEG, let model = model(session.watchWindow) else { continue }
                session.lastFrameSerial = 1
                session.link.send(RemotePayload.frame(window: model.windowID, jpeg: jpeg))
            }
            return
        }
        for session in sessions.values where session.isActive && session.frames {
            guard session.framesInFlight < 2, session.link.pendingCount < 3,
                  let model = model(session.watchWindow), model.receiver.state == .playing else { continue }
            let windowID = model.windowID
            guard let current = model.receiver.currentFrame() else { continue }
            if let cached = frameCache[windowID], cached.serial == current.serial {
                guard cached.serial != session.lastFrameSerial else { continue }
                session.lastFrameSerial = cached.serial
                session.framesInFlight += 1
                session.link.send(RemotePayload.frame(window: windowID, jpeg: cached.jpeg))
                continue
            }
            guard !encoding.contains(windowID) else { continue }
            encoding.insert(windowID)
            let box = PixelBufferBox(buffer: current.buffer)
            let serial = current.serial
            Task { [weak self] in
                let jpeg = await self?.frames.jpeg(box)
                guard let self else { return }
                self.encoding.remove(windowID)
                if let jpeg { self.frameCache[windowID] = (serial, jpeg) }
            }
        }
    }

    private func log(_ message: String) {
        RemoteLog.write(message)
    }
}

struct PixelBufferBox: @unchecked Sendable {
    let buffer: CVPixelBuffer
}

/// Turns mirror frames into small JPEGs off the main thread.
final class RemoteFrameEncoder: @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let queue = DispatchQueue(label: "autocore.remote.jpeg", qos: .userInitiated)
    /// Wide enough for a sharp picture on an iPhone, small enough for ten a second.
    private let width: CGFloat = 640

    func jpeg(_ box: PixelBufferBox) async -> Data? {
        await withCheckedContinuation { continuation in
            queue.async { [context, width] in
                let image = CIImage(cvPixelBuffer: box.buffer)
                let scale = min(1, width / max(1, image.extent.width))
                let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let data = context.jpegRepresentation(
                    of: scaled, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                    options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.55])
                continuation.resume(returning: data)
            }
        }
    }
}

/// `remote.log` in the app's folder: who connected and what they pressed.
@MainActor
enum RemoteLog {
    static func write(_ message: String) {
        _ = RunLogFile.named("remote.log", limit: 300).append(message, from: nil)
    }
}
