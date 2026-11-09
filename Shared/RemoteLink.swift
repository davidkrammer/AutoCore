import CryptoKit
import Foundation
import Network

/// Keys for one connection. Both sides make a fresh X25519 key pair per
/// connection; a paired Remote mixes in the key saved at pairing, so only
/// the paired Mac and Remote can read each other. Every message is sealed
/// with ChaCha20-Poly1305 and numbered, so nothing can be replayed or
/// reordered. Nothing depends on the network, so the same channel can later
/// run through a relay for access over the internet.
struct RemoteCipher {
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sent: UInt64 = 0
    private var received: UInt64 = 0

    enum Failure: Error { case unreadable }

    /// `pairKey` nil while pairing.
    init(shared: SharedSecret, pairKey: Data?, clientNonce: Data, serverNonce: Data, isServer: Bool) {
        let salt = clientNonce + serverNonce
        let material: SymmetricKey
        if let pairKey {
            material = SymmetricKey(data: shared.withUnsafeBytes { Data($0) } + pairKey)
        } else {
            material = SymmetricKey(data: shared.withUnsafeBytes { Data($0) })
        }
        let label = pairKey == nil ? "pairing" : "session"
        func key(_ direction: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: material, salt: salt,
                                   info: Data("\(RemoteWire.label) \(label) \(direction)".utf8), outputByteCount: 32)
        }
        sendKey = key(isServer ? "mac" : "remote")
        receiveKey = key(isServer ? "remote" : "mac")
    }

    private static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: counter.bigEndian) { bytes.append(contentsOf: $0) }
        return try! ChaChaPoly.Nonce(data: bytes)
    }

    mutating func seal(_ plain: Data) throws -> Data {
        let box = try ChaChaPoly.seal(plain, using: sendKey, nonce: Self.nonce(sent))
        sent += 1
        return box.ciphertext + box.tag
    }

    mutating func open(_ sealed: Data) throws -> Data {
        guard sealed.count >= 16 else { throw Failure.unreadable }
        let box = try ChaChaPoly.SealedBox(nonce: Self.nonce(received),
                                           ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
        let plain = try ChaChaPoly.open(box, using: receiveKey)
        received += 1
        return plain
    }

    /// Six digits both screens show while pairing; equal digits mean nobody
    /// sits in between.
    static func pairingCode(shared: SharedSecret, clientNonce: Data, serverNonce: Data) -> String {
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: clientNonce + serverNonce,
                                                 sharedInfo: Data("\(RemoteWire.label) code".utf8), outputByteCount: 8)
        let value = key.withUnsafeBytes { bytes in bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }
        return String(format: "%06llu", value % 1_000_000)
    }

    /// The key both sides keep after pairing.
    static func pairKey(shared: SharedSecret, clientNonce: Data, serverNonce: Data) -> Data {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: clientNonce + serverNonce,
                                       sharedInfo: Data("\(RemoteWire.label) pair key".utf8), outputByteCount: 32)
            .withUnsafeBytes { Data($0) }
    }

    static func randomNonce() -> Data {
        Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    }
}

/// A TCP connection carrying length-prefixed messages: JSON during the
/// handshake, then sealed messages.
final class RemoteLink: @unchecked Sendable {
    let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()
    private var closed = false
    private let lock = NSLock()
    private var cipher: RemoteCipher?
    /// Messages handed to the network but not yet sent, to drop frames when
    /// the network is slow.
    private var pendingSends = 0

    /// Messages handed to the network but not sent yet.
    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingSends
    }

    var onReady: (() -> Void)?
    /// A message, decrypted once encryption is on.
    var onMessage: ((Data) -> Void)?
    var onClose: ((String?) -> Void)?

    init(connection: NWConnection, label: String) {
        self.connection = connection
        queue = DispatchQueue(label: "autocore.remote.\(label)")
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?()
                self.receive()
            case let .failed(error):
                self.close(error.localizedDescription)
            case let .waiting(error):
                self.close(error.localizedDescription)
            case .cancelled:
                self.close(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// From now on every message is sealed.
    func encrypt(with cipher: RemoteCipher) {
        lock.lock()
        self.cipher = cipher
        lock.unlock()
    }

    /// Sends a last plain message (the handshake answer), then seals
    /// everything after it, with nothing in between.
    func sendJSONThenEncrypt<T: Encodable>(_ value: T, with cipher: RemoteCipher) {
        guard let data = try? JSONEncoder.remote.encode(value) else { return }
        lock.lock()
        let wasEncrypted = self.cipher != nil
        lock.unlock()
        guard !wasEncrypted else { return }
        send(data)
        encrypt(with: cipher)
    }

    var isEncrypted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cipher != nil
    }

    func send(_ message: Data) {
        // Sealing numbers each message, so sealing and handing it to the
        // network happen together, in order.
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        var payload = message
        if cipher != nil {
            guard let sealed = try? cipher!.seal(message) else { return }
            payload = sealed
        }
        pendingSends += 1
        var framed = Data(count: 4)
        let count = UInt32(payload.count)
        framed[0] = UInt8(count >> 24)
        framed[1] = UInt8((count >> 16) & 0xff)
        framed[2] = UInt8((count >> 8) & 0xff)
        framed[3] = UInt8(count & 0xff)
        framed.append(payload)
        connection.send(content: framed, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.lock.lock()
            self.pendingSends -= 1
            self.lock.unlock()
            if let error { self.close(error.localizedDescription) }
        })
    }

    func sendJSON<T: Encodable>(_ value: T) {
        guard let data = try? JSONEncoder.remote.encode(value) else { return }
        send(data)
    }

    func close(_ reason: String?) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        lock.unlock()
        connection.cancel()
        onClose?(reason)
        onReady = nil
        onMessage = nil
        onClose = nil
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                guard self.drain() else { return }
            }
            if isComplete || error != nil {
                self.close(error?.localizedDescription)
                return
            }
            self.receive()
        }
    }

    /// False when the connection was closed.
    private func drain() -> Bool {
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard length > 0, length <= RemoteWire.maximumMessageBytes + 64 else {
                close("Unreadable message")
                return false
            }
            guard buffer.count >= length + 4 else { break }
            var message = Data(buffer.dropFirst(4).prefix(length))
            buffer.removeFirst(length + 4)
            lock.lock()
            if cipher != nil {
                guard let plain = try? cipher!.open(message) else {
                    lock.unlock()
                    close("Wrong key")
                    return false
                }
                message = plain
            }
            lock.unlock()
            onMessage?(message)
        }
        return true
    }
}

extension JSONEncoder {
    static var remote: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }
}

extension JSONDecoder {
    static var remote: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

/// Inside the encrypted channel: a kind byte, then JSON or a frame.
enum RemotePayload {
    static func json<T: Encodable>(_ value: T) -> Data? {
        guard let body = try? JSONEncoder.remote.encode(value) else { return nil }
        return Data([RemotePayloadKind.json.rawValue]) + body
    }

    static func frame(window: UUID, jpeg: Data) -> Data {
        var data = Data([RemotePayloadKind.frame.rawValue])
        withUnsafeBytes(of: window.uuid) { data.append(contentsOf: $0) }
        data.append(jpeg)
        return data
    }

    enum Decoded {
        case json(Data)
        case frame(UUID, Data)
    }

    static func decode(_ data: Data) -> Decoded? {
        guard let first = data.first, let kind = RemotePayloadKind(rawValue: first) else { return nil }
        let body = data.dropFirst()
        switch kind {
        case .json:
            return .json(Data(body))
        case .frame:
            guard body.count > 16 else { return nil }
            let idBytes = Array(body.prefix(16))
            let id = UUID(uuid: (idBytes[0], idBytes[1], idBytes[2], idBytes[3], idBytes[4], idBytes[5],
                                 idBytes[6], idBytes[7], idBytes[8], idBytes[9], idBytes[10], idBytes[11],
                                 idBytes[12], idBytes[13], idBytes[14], idBytes[15]))
            return .frame(id, Data(body.dropFirst(16)))
        }
    }
}
