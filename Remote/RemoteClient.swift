import CryptoKit
import Foundation
import Network
import Security
import UIKit

/// A Mac running the app, found on the Wi-Fi.
struct FoundMac: Identifiable, Equatable {
    let id: String
    let name: String
    let macID: UUID?
    let endpoint: NWEndpoint
}

/// The Mac this iPhone is allowed to control, kept in the Keychain.
struct SavedMac: Codable, Equatable {
    var macID: UUID
    var name: String
    var key: Data
}

/// Talks to the app on the Mac: finds it, pairs once, then keeps the
/// connection while the app is open and shows what the Mac sends.
@MainActor
final class RemoteClient: ObservableObject {
    enum Phase: Equatable {
        case searching
        case connecting(String)
        case pairing(code: String, mac: String)
        case connected
        case failed(String)
    }

    @Published private(set) var phase = Phase.searching
    @Published private(set) var macs: [FoundMac] = []
    @Published private(set) var saved: SavedMac? = Keychain.loadMac()
    @Published private(set) var state: RemoteState?
    @Published private(set) var frame: UIImage?
    @Published private(set) var frameWindow: UUID?
    @Published var toast: Toast?
    /// The window the Remote looks at.
    @Published private(set) var selectedWindow: UUID?
    /// Whether the live picture is on screen.
    @Published var wantsFrames = false { didSet { if wantsFrames != oldValue { sendWatch() } } }
    /// The demo for screenshots: sample data, no network.
    let isDemo = ProcessInfo.processInfo.arguments.contains("--remote-demo")

    struct Toast: Equatable, Identifiable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    private var browser: NWBrowser?
    private var link: RemoteLink?
    private var reconnectTask: Task<Void, Never>?
    private var isActive = true
    private var pingTask: Task<Void, Never>?
    private var lastFrameAt = Date.distantPast
    private let remoteID: UUID = {
        let key = "remoteID"
        if let stored = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: stored) { return id }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }()

    var selectedSummary: RemoteWindow? {
        state?.windows.first { $0.id == selectedWindow } ?? state?.windows.first
    }

    init() {
        if isDemo { loadDemo() }
    }

    // MARK: - Lifecycle

    func becameActive() {
        guard !isDemo else { return }
        isActive = true
        startBrowsing()
        if link == nil { connectToSavedIfFound() }
    }

    func becameInactive() {
        guard !isDemo else { return }
        isActive = false
        reconnectTask?.cancel()
        pingTask?.cancel()
        link?.close(nil)
        link = nil
        browser?.cancel()
        browser = nil
        frame = nil
        if case .connected = phase { phase = .connecting(NSLocalizedString("Reconnecting…", comment: "")) }
    }

    private func startBrowsing() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: RemoteWire.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> FoundMac? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                var macID: UUID?
                if case let .bonjour(txt) = result.metadata, let id = txt["id"] { macID = UUID(uuidString: id) }
                return FoundMac(id: name + (macID?.uuidString ?? ""), name: name, macID: macID, endpoint: result.endpoint)
            }.sorted { $0.name < $1.name }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.macs = found
                    self?.connectToSavedIfFound()
                }
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case let .failed(error) = state {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.phase = .failed(error.localizedDescription) }
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func connectToSavedIfFound() {
        guard isActive, link == nil, let saved,
              let mac = macs.first(where: { $0.macID == saved.macID }) else { return }
        connect(to: mac)
    }

    // MARK: - Connecting

    func connect(to mac: FoundMac) {
        guard !isDemo else { return }
        reconnectTask?.cancel()
        link?.close(nil)
        phase = .connecting(String(format: NSLocalizedString("Connecting to %@…", comment: ""), mac.name))
        let parameters = NWParameters.tcp
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 5
            tcp.keepaliveInterval = 2
            tcp.keepaliveCount = 3
            tcp.noDelay = true
        }
        let connection = NWConnection(to: mac.endpoint, using: parameters)
        let link = RemoteLink(connection: connection, label: "remote")
        self.link = link
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let nonce = RemoteCipher.randomNonce()
        let hasKey = saved?.macID == mac.macID && saved != nil
        var welcomed = false
        let hello = RemoteHello(version: RemoteWire.version, remoteID: remoteID, name: Self.displayName,
                                model: Self.modelName, hasKey: hasKey,
                                publicKey: privateKey.publicKey.rawRepresentation, nonce: nonce)
        link.onReady = { link.sendJSON(hello) }
        link.onMessage = { [weak self] data in
            if !welcomed {
                welcomed = true
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.welcome(data, link: link, mac: mac, privateKey: privateKey, nonce: nonce)
                    }
                }
                return
            }
            self?.received(data, link: link)
        }
        link.onClose = { [weak self] reason in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.closed(link: link, mac: mac, reason: reason) }
            }
        }
        link.start()
    }

    private func welcome(_ data: Data, link: RemoteLink, mac: FoundMac,
                         privateKey: Curve25519.KeyAgreement.PrivateKey, nonce: Data) {
        guard self.link === link else { return }
        guard let welcome = try? JSONDecoder.remote.decode(RemoteWelcome.self, from: data),
              let serverKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: welcome.publicKey),
              let shared = try? privateKey.sharedSecretFromKeyAgreement(with: serverKey) else {
            link.close(NSLocalizedString("The Mac answered something unreadable.", comment: ""))
            return
        }
        switch welcome.mode {
        case .rejected:
            phase = .failed(welcome.message ?? NSLocalizedString("The Mac refused the connection.", comment: ""))
            self.link = nil
            link.close(nil)
        case .session:
            guard let saved, saved.macID == welcome.macID else {
                link.close(nil)
                return
            }
            link.encrypt(with: RemoteCipher(shared: shared, pairKey: saved.key, clientNonce: nonce,
                                            serverNonce: welcome.nonce, isServer: false))
            if saved.name != welcome.macName {
                self.saved?.name = welcome.macName
                Keychain.saveMac(self.saved)
            }
            phase = .connected
            sendWatch()
            startPing()
        case .pairing:
            link.encrypt(with: RemoteCipher(shared: shared, pairKey: nil, clientNonce: nonce,
                                            serverNonce: welcome.nonce, isServer: false))
            pendingPair = SavedMac(macID: welcome.macID, name: welcome.macName,
                                   key: RemoteCipher.pairKey(shared: shared, clientNonce: nonce, serverNonce: welcome.nonce))
            phase = .pairing(code: RemoteCipher.pairingCode(shared: shared, clientNonce: nonce, serverNonce: welcome.nonce),
                             mac: welcome.macName)
        }
    }

    private var pendingPair: SavedMac?

    /// On the link's queue.
    nonisolated private func received(_ data: Data, link: RemoteLink) {
        switch RemotePayload.decode(data) {
        case let .frame(window, jpeg)?:
            if let ack = RemotePayload.json(RemoteCommand.frameReceived) { link.send(ack) }
            guard let image = UIImage(data: jpeg)?.preparingForDisplay() else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.link === link else { return }
                    self.frame = image
                    self.frameWindow = window
                    self.lastFrameAt = Date()
                }
            }
        case let .json(body)?:
            guard let event = try? JSONDecoder.remote.decode(RemoteEvent.self, from: body) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.handle(event, link: link) }
            }
        case nil:
            break
        }
    }

    private func handle(_ event: RemoteEvent, link: RemoteLink) {
        guard self.link === link else { return }
        switch event {
        case let .state(state):
            if selectedWindow == nil || !state.windows.contains(where: { $0.id == selectedWindow }) {
                let remembered = UserDefaults.standard.string(forKey: "windowName")
                selectedWindow = state.windows.first { $0.name == remembered }?.id ?? state.window ?? state.windows.first?.id
                if selectedWindow != state.window { sendWatch() }
            }
            self.state = state
        case let .result(ok, message):
            if case .pairing = phase {
                phase = .failed(message)
                return
            }
            toast = Toast(text: message, isError: !ok)
        case .paired:
            guard let pendingPair else { return }
            saved = pendingPair
            Keychain.saveMac(pendingPair)
            self.pendingPair = nil
            phase = .connecting(NSLocalizedString("Allowed. Connecting…", comment: ""))
            self.link = nil
            link.close(nil)
            Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                self.connectToSavedIfFound()
            }
        case .pong:
            break
        }
    }

    private func closed(link: RemoteLink, mac: FoundMac, reason: String?) {
        guard self.link === link else { return }
        self.link = nil
        pingTask?.cancel()
        frame = nil
        guard isActive else { return }
        if case .pairing = phase {
            phase = .failed(reason ?? NSLocalizedString("The Mac closed the connection.", comment: ""))
            return
        }
        if case .failed = phase { return }
        guard saved != nil else {
            phase = .failed(reason ?? NSLocalizedString("The connection ended.", comment: ""))
            return
        }
        phase = .connecting(NSLocalizedString("Reconnecting…", comment: ""))
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled, self.isActive, self.link == nil else { return }
            // Bonjour may have lost the Mac for a moment; browse again.
            self.browser?.cancel()
            self.browser = nil
            self.startBrowsing()
            if let mac = self.macs.first(where: { $0.macID == self.saved?.macID }) { self.connect(to: mac) }
        }
    }

    private func startPing() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self?.send(.ping)
            }
        }
    }

    func cancelPairing() {
        link?.close(nil)
        link = nil
        pendingPair = nil
        phase = .searching
    }

    func forgetMac() {
        Keychain.saveMac(nil)
        saved = nil
        link?.close(nil)
        link = nil
        state = nil
        frame = nil
        phase = .searching
    }

    func retry() {
        phase = .searching
        browser?.cancel()
        browser = nil
        startBrowsing()
        connectToSavedIfFound()
    }

    // MARK: - Commands

    private func send(_ command: RemoteCommand) {
        guard let link, link.isEncrypted, let payload = RemotePayload.json(command) else { return }
        link.send(payload)
    }

    func select(window: UUID) {
        selectedWindow = window
        if let name = state?.windows.first(where: { $0.id == window })?.name {
            UserDefaults.standard.set(name, forKey: "windowName")
        }
        frame = nil
        sendWatch()
    }

    func select(mode: String) {
        guard let window = selectedWindow else { return }
        if isDemo { state?.mode = mode; return }
        send(.watch(window: window, mode: mode, frames: wantsFrames))
    }

    private func sendWatch() {
        guard case .connected = phase else { return }
        send(.watch(window: selectedWindow, mode: nil, frames: wantsFrames))
    }

    func tap(_ point: CGPoint) {
        guard let window = selectedWindow else { return }
        send(.tap(window: window, x: Double(point.x), y: Double(point.y)))
    }

    func drag(from start: CGPoint, to end: CGPoint, duration: Double) {
        guard let window = selectedWindow else { return }
        send(.drag(window: window, fromX: Double(start.x), fromY: Double(start.y),
                   toX: Double(end.x), toY: Double(end.y), duration: duration))
    }

    func type(_ text: String) {
        guard let window = selectedWindow, !text.isEmpty else { return }
        send(.type(window: window, text: text))
    }

    func set(_ key: String, _ value: RemoteValue) {
        guard let window = state?.window else { return }
        send(.set(window: window, key: key, value: value))
    }

    func perform(_ action: String) {
        guard let window = state?.window else { return }
        send(.action(window: window, id: action))
    }

    var frameIsStale: Bool { Date().timeIntervalSince(lastFrameAt) > 3 }

    /// iOS only tells apps "iPhone"; the model says more on the Mac.
    private static var displayName: String {
        let name = UIDevice.current.name
        guard name == "iPhone" || name.isEmpty else { return name }
        let models = ["iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max", "iPhone18,3": "iPhone 17",
                      "iPhone18,4": "iPhone Air", "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
                      "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus", "iPhone17,5": "iPhone 16e",
                      "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max", "iPhone15,4": "iPhone 15",
                      "iPhone15,5": "iPhone 15 Plus", "iPhone11,2": "iPhone XS", "iPhone11,6": "iPhone XS Max"]
        #if targetEnvironment(simulator)
        return "iPhone Simulator"
        #else
        return models[modelName] ?? modelName
        #endif
    }

    private static var modelName: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    // MARK: - Demo

    private func loadDemo() {
        guard let url = Bundle.main.url(forResource: "demo-state", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder.remote.decode(RemoteState.self, from: data) else {
            phase = .searching
            return
        }
        self.state = state
        selectedWindow = state.window
        saved = SavedMac(macID: UUID(), name: state.macName, key: Data())
        phase = .connected
        if let image = Bundle.main.url(forResource: "demo-frame", withExtension: "jpg").flatMap({ UIImage(contentsOfFile: $0.path) }) {
            frame = image
            frameWindow = state.window
            lastFrameAt = .distantFuture
        }
    }
}

/// The paired Mac's key, only on this iPhone.
enum Keychain {
    /// The Keychain item for the pairing key: this app's bundle ID.
    private static let service = Bundle.main.bundleIdentifier ?? "autocore.remote"
    private static let account = "mac"

    static func loadMac() -> SavedMac? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(SavedMac.self, from: data)
    }

    static func saveMac(_ mac: SavedMac?) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard let mac, let data = try? JSONEncoder().encode(mac) else { return }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}
