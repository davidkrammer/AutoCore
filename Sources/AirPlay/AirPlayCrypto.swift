import CryptoKit
import Foundation

private final class X25519KeyBox {
    let privateKey: Curve25519.KeyAgreement.PrivateKey?
    let publicKey: Curve25519.KeyAgreement.PublicKey

    init(privateKey: Curve25519.KeyAgreement.PrivateKey) {
        self.privateKey = privateKey
        self.publicKey = privateKey.publicKey
    }

    init(publicKey: Curve25519.KeyAgreement.PublicKey) {
        self.privateKey = nil
        self.publicKey = publicKey
    }
}

private final class Ed25519KeyBox {
    let privateKey: Curve25519.Signing.PrivateKey?
    let publicKey: Curve25519.Signing.PublicKey

    init(privateKey: Curve25519.Signing.PrivateKey) {
        self.privateKey = privateKey
        self.publicKey = privateKey.publicKey
    }

    init(publicKey: Curve25519.Signing.PublicKey) {
        self.privateKey = nil
        self.publicKey = publicKey
    }
}

private func retainedPointer<T: AnyObject>(_ value: T) -> UnsafeMutableRawPointer {
    UnsafeMutableRawPointer(Unmanaged.passRetained(value).toOpaque())
}

private func takeUnretained<T: AnyObject>(_ pointer: UnsafeRawPointer?, as _: T.Type) -> T? {
    guard let pointer else { return nil }
    return Unmanaged<T>.fromOpaque(pointer).takeUnretainedValue()
}

private func writeBytes(_ bytes: some Sequence<UInt8>, to destination: UnsafeMutablePointer<UInt8>?, count: Int) {
    guard let destination else { return }
    Array(bytes.prefix(count)).withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return }
        memcpy(destination, base, rawBuffer.count)
    }
}

@_cdecl("x25519_key_generate")
func x25519_key_generate_c() -> UnsafeMutableRawPointer? {
    retainedPointer(X25519KeyBox(privateKey: Curve25519.KeyAgreement.PrivateKey()))
}

@_cdecl("x25519_key_from_raw")
func x25519_key_from_raw_c(_ data: UnsafePointer<UInt8>?) -> UnsafeMutableRawPointer? {
    guard let data else { return nil }
    let bytes = Data(bytes: data, count: 32)
    guard let publicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: bytes) else {
        return nil
    }
    return retainedPointer(X25519KeyBox(publicKey: publicKey))
}

@_cdecl("x25519_key_get_raw")
func x25519_key_get_raw_c(_ data: UnsafeMutablePointer<UInt8>?, _ key: UnsafeRawPointer?) {
    guard let key = takeUnretained(key, as: X25519KeyBox.self) else { return }
    writeBytes(key.publicKey.rawRepresentation, to: data, count: 32)
}

@_cdecl("x25519_key_destroy")
func x25519_key_destroy_c(_ key: UnsafeMutableRawPointer?) {
    guard let key else { return }
    Unmanaged<X25519KeyBox>.fromOpaque(key).release()
}

@_cdecl("x25519_derive_secret")
func x25519_derive_secret_c(_ secret: UnsafeMutablePointer<UInt8>?, _ ours: UnsafeRawPointer?, _ theirs: UnsafeRawPointer?) {
    guard
        let ours = takeUnretained(ours, as: X25519KeyBox.self),
        let theirs = takeUnretained(theirs, as: X25519KeyBox.self),
        let privateKey = ours.privateKey,
        let secret
    else { return }

    guard let sharedSecret = try? privateKey.sharedSecretFromKeyAgreement(with: theirs.publicKey) else {
        return
    }

    sharedSecret.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return }
        memcpy(secret, base, min(rawBuffer.count, 32))
    }
}

@_cdecl("ed25519_key_generate")
func ed25519_key_generate_c() -> UnsafeMutableRawPointer? {
    retainedPointer(Ed25519KeyBox(privateKey: Curve25519.Signing.PrivateKey()))
}

@_cdecl("ed25519_key_from_raw")
func ed25519_key_from_raw_c(_ data: UnsafePointer<UInt8>?) -> UnsafeMutableRawPointer? {
    guard let data else { return nil }
    let bytes = Data(bytes: data, count: 32)
    guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: bytes) else {
        return nil
    }
    return retainedPointer(Ed25519KeyBox(publicKey: publicKey))
}

@_cdecl("ed25519_key_get_raw")
func ed25519_key_get_raw_c(_ data: UnsafeMutablePointer<UInt8>?, _ key: UnsafeRawPointer?) {
    guard let key = takeUnretained(key, as: Ed25519KeyBox.self) else { return }
    writeBytes(key.publicKey.rawRepresentation, to: data, count: 32)
}

@_cdecl("ed25519_key_copy")
func ed25519_key_copy_c(_ key: UnsafeRawPointer?) -> UnsafeMutableRawPointer? {
    guard let key else { return nil }
    _ = Unmanaged<Ed25519KeyBox>.fromOpaque(key).retain()
    return UnsafeMutableRawPointer(mutating: key)
}

@_cdecl("ed25519_key_destroy")
func ed25519_key_destroy_c(_ key: UnsafeMutableRawPointer?) {
    guard let key else { return }
    Unmanaged<Ed25519KeyBox>.fromOpaque(key).release()
}

@_cdecl("ed25519_sign")
func ed25519_sign_c(
    _ signature: UnsafeMutablePointer<UInt8>?,
    _ signatureLen: Int,
    _ data: UnsafePointer<UInt8>?,
    _ dataLen: Int,
    _ key: UnsafeRawPointer?
) {
    guard
        let signature,
        let data,
        let key = takeUnretained(key, as: Ed25519KeyBox.self),
        let privateKey = key.privateKey,
        let signed = try? privateKey.signature(for: Data(bytes: data, count: dataLen))
    else { return }

    signed.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return }
        memcpy(signature, base, min(signatureLen, rawBuffer.count))
    }
}

@_cdecl("ed25519_verify")
func ed25519_verify_c(
    _ signature: UnsafePointer<UInt8>?,
    _ signatureLen: Int,
    _ data: UnsafePointer<UInt8>?,
    _ dataLen: Int,
    _ key: UnsafeRawPointer?
) -> Int32 {
    guard
        let signature,
        let data,
        let key = takeUnretained(key, as: Ed25519KeyBox.self)
    else { return 0 }

    let signatureData = Data(bytes: signature, count: signatureLen)
    let payload = Data(bytes: data, count: dataLen)
    return key.publicKey.isValidSignature(signatureData, for: payload) ? 1 : 0
}
