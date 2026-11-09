import CryptoKit
import Network
import XCTest
@testable import AutoCore

final class RemoteLinkTests: XCTestCase {
    private func handshake(pairKey: Data?) throws -> (mac: RemoteCipher, remote: RemoteCipher, codes: (String, String)) {
        let macKey = Curve25519.KeyAgreement.PrivateKey()
        let remoteKey = Curve25519.KeyAgreement.PrivateKey()
        let clientNonce = RemoteCipher.randomNonce()
        let serverNonce = RemoteCipher.randomNonce()
        let macShared = try macKey.sharedSecretFromKeyAgreement(with: remoteKey.publicKey)
        let remoteShared = try remoteKey.sharedSecretFromKeyAgreement(with: macKey.publicKey)
        return (RemoteCipher(shared: macShared, pairKey: pairKey, clientNonce: clientNonce, serverNonce: serverNonce, isServer: true),
                RemoteCipher(shared: remoteShared, pairKey: pairKey, clientNonce: clientNonce, serverNonce: serverNonce, isServer: false),
                (RemoteCipher.pairingCode(shared: macShared, clientNonce: clientNonce, serverNonce: serverNonce),
                 RemoteCipher.pairingCode(shared: remoteShared, clientNonce: clientNonce, serverNonce: serverNonce)))
    }

    func testBothSidesShowTheSameCodeAndReadEachOther() throws {
        var (mac, remote, codes) = try handshake(pairKey: nil)
        XCTAssertEqual(codes.0, codes.1)
        XCTAssertEqual(codes.0.count, 6)
        for text in ["watch", "tap", String(repeating: "x", count: 5000)] {
            XCTAssertEqual(try remote.open(mac.seal(Data(text.utf8))), Data(text.utf8))
            XCTAssertEqual(try mac.open(remote.seal(Data(text.utf8))), Data(text.utf8))
        }
    }

    func testWrongKeyAndReplayAreRefused() throws {
        var (mac, _, _) = try handshake(pairKey: Data(repeating: 1, count: 32))
        var (_, stranger, _) = try handshake(pairKey: Data(repeating: 2, count: 32))
        XCTAssertThrowsError(try stranger.open(mac.seal(Data("state".utf8))))

        var (sender, receiver, _) = try handshake(pairKey: Data(repeating: 3, count: 32))
        let first = try sender.seal(Data("one".utf8))
        XCTAssertNoThrow(try receiver.open(first))
        // The same message again does not open: every message is numbered.
        XCTAssertThrowsError(try receiver.open(first))
    }

    func testFramesAndStateSurviveTheWire() throws {
        let window = UUID()
        guard case let .frame(id, jpeg)? = RemotePayload.decode(RemotePayload.frame(window: window, jpeg: Data([1, 2, 3]))) else {
            return XCTFail("No frame")
        }
        XCTAssertEqual(id, window)
        XCTAssertEqual(jpeg, Data([1, 2, 3]))
        let command = RemoteCommand.set(window: window, key: "AutoCore.demoText", value: .string("hello"))
        guard case let .json(body)? = RemotePayload.decode(try XCTUnwrap(RemotePayload.json(command))) else {
            return XCTFail("No JSON")
        }
        XCTAssertEqual(try JSONDecoder.remote.decode(RemoteCommand.self, from: body), command)
    }

    /// A Remote over a real local connection: hello, pairing code, sealed messages.
    func testLinkCarriesSealedMessagesOverTCP() throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let received = expectation(description: "Mac reads the Remote")
        let answered = expectation(description: "Remote reads the Mac")
        var macLink: RemoteLink?
        let (mac, remote, _) = try handshake(pairKey: Data(repeating: 7, count: 32))
        listener.newConnectionHandler = { connection in
            let link = RemoteLink(connection: connection, label: "test-mac")
            macLink = link
            var encrypted = false
            link.onMessage = { data in
                if !encrypted {
                    XCTAssertEqual(String(decoding: data, as: UTF8.self), "hello")
                    encrypted = true
                    link.encrypt(with: mac)
                    return
                }
                XCTAssertEqual(String(decoding: data, as: UTF8.self), "watch")
                received.fulfill()
                link.send(Data("state".utf8))
            }
            link.start()
        }
        let ready = expectation(description: "Listening")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .global())
        wait(for: [ready], timeout: 5)
        let port = try XCTUnwrap(listener.port)
        let client = RemoteLink(connection: NWConnection(host: "127.0.0.1", port: port, using: .tcp), label: "test-remote")
        client.onReady = {
            client.send(Data("hello".utf8))
            client.encrypt(with: remote)
            client.send(Data("watch".utf8))
        }
        client.onMessage = { data in
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "state")
            answered.fulfill()
        }
        client.start()
        wait(for: [received, answered], timeout: 5)
        client.close(nil)
        macLink?.close(nil)
        listener.cancel()
    }
}
