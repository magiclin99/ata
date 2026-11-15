import Foundation
import CryptoKit
import Security

// MARK: - Encodings

public enum Hex {
    public static func encode(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    /// Accepts upper or lower case; returns nil on odd length or a non-hex character.
    public static func decode(_ s: String) -> Data? {
        let chars = Array(s.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        func v(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 97...102: return c - 87
            case 65...70: return c - 55
            default: return nil
            }
        }
        var i = 0
        while i < chars.count {
            guard let hi = v(chars[i]), let lo = v(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }
}

public enum Base64URL {
    /// base64url without padding (SPEC §2 `k=`).
    public static func encode(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Accepts with or without padding.
    public static func decode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t.append("=") }
        return Data(base64Encoded: t)
    }
}

public enum B64 {
    /// Standard base64 with padding (SPEC §4 "b64").
    public static func encode(_ d: Data) -> String { d.base64EncodedString() }
    /// Standard alphabet; missing padding is tolerated.
    public static func decode(_ s: String) -> Data? {
        var t = s
        while t.count % 4 != 0 { t.append("=") }
        return Data(base64Encoded: t)
    }
}

public func randomBytes(_ n: Int) -> Data {
    var d = Data(count: n)
    let ok = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
    precondition(ok == errSecSuccess, "SecRandomCopyBytes failed")
    return d
}

// MARK: - Handshake and key schedule (SPEC §4, §5)

public enum ATACrypto {
    public static let authPhoneLabel = "ata2-auth-phone"
    public static let authMacLabel = "ata2-auth-mac"

    /// HMAC-SHA256(K, label ‖ macId ‖ phoneId ‖ nonceM ‖ nonceP), no separators.
    public static func authMAC(label: String, k: Data, macId: Data, phoneId: Data, nonceM: Data, nonceP: Data) -> Data {
        var m = Data(label.utf8)
        m.append(macId); m.append(phoneId); m.append(nonceM); m.append(nonceP)
        return Data(HMAC<SHA256>.authenticationCode(for: m, using: SymmetricKey(data: k)))
    }

    public static func phoneAuthMAC(k: Data, macId: Data, phoneId: Data, nonceM: Data, nonceP: Data) -> Data {
        authMAC(label: authPhoneLabel, k: k, macId: macId, phoneId: phoneId, nonceM: nonceM, nonceP: nonceP)
    }

    public static func macAuthMAC(k: Data, macId: Data, phoneId: Data, nonceM: Data, nonceP: Data) -> Data {
        authMAC(label: authMacLabel, k: k, macId: macId, phoneId: phoneId, nonceM: nonceM, nonceP: nonceP)
    }

    /// Constant-time equality (time depends only on the lengths).
    public static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        let x = [UInt8](a), y = [UInt8](b)
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    public struct SessionKeys {
        public let kP2M: Data
        public let kM2P: Data
        public let kFile: Data
        public let sid: Data
    }

    /// HKDF-SHA256, ikm = K, salt = nonceM ‖ nonceP.
    public static func deriveSessionKeys(k: Data, nonceM: Data, nonceP: Data) -> SessionKeys {
        let salt = nonceM + nonceP
        func hkdf(_ info: String, _ n: Int) -> Data {
            let key: SymmetricKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: k), salt: salt,
                                                           info: Data(info.utf8), outputByteCount: n)
            let bytes: [UInt8] = key.withUnsafeBytes { Array($0) }
            return Data(bytes)
        }
        return SessionKeys(kP2M: hkdf("ata2 ble p2m", 32), kM2P: hkdf("ata2 ble m2p", 32),
                           kFile: hkdf("ata2 file", 32), sid: hkdf("ata2 sid", 16))
    }
}

// MARK: - AES-256-GCM with a counter nonce (SPEC §5, §7a)

public enum CipherError: Error, CustomStringConvertible {
    case tooShort, authFailed
    public var description: String {
        switch self {
        case .tooShort: return "ciphertext shorter than the GCM tag"
        case .authFailed: return "AES-GCM authentication failed"
        }
    }
}

/// One direction of an AES-256-GCM stream. Nonce = 4-byte big-endian prefix ‖ 8-byte big-endian counter;
/// the counter starts at 0 and increments per message. Wire form = ciphertext ‖ 16-byte tag, no AAD.
/// BLE uses prefix 0; TCP uses 1 (phone → Mac) and 2 (Mac → phone).
public struct CounterCipher {
    public static let bleP2MPrefix: UInt32 = 0
    public static let bleM2PPrefix: UInt32 = 0
    public static let tcpP2MPrefix: UInt32 = 1
    public static let tcpM2PPrefix: UInt32 = 2

    private let key: SymmetricKey
    public let prefix: UInt32
    public private(set) var counter: UInt64

    public init(key: Data, prefix: UInt32, counter: UInt64 = 0) {
        self.key = SymmetricKey(data: key)
        self.prefix = prefix
        self.counter = counter
    }

    public static func nonce(prefix: UInt32, counter: UInt64) -> Data {
        var d = Data(capacity: 12)
        withUnsafeBytes(of: prefix.bigEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: counter.bigEndian) { d.append(contentsOf: $0) }
        return d
    }

    public mutating func seal(_ plaintext: Data) -> Data {
        let n = try! AES.GCM.Nonce(data: Self.nonce(prefix: prefix, counter: counter))
        let box = try! AES.GCM.seal(plaintext, using: key, nonce: n)
        counter += 1
        return box.ciphertext + box.tag
    }

    /// The counter only advances on success.
    public mutating func open(_ wire: Data) throws -> Data {
        guard wire.count >= 16 else { throw CipherError.tooShort }
        let n = try! AES.GCM.Nonce(data: Self.nonce(prefix: prefix, counter: counter))
        let ct = wire.prefix(wire.count - 16)
        let tag = wire.suffix(16)
        do {
            let box = try AES.GCM.SealedBox(nonce: n, ciphertext: ct, tag: tag)
            let pt = try AES.GCM.open(box, using: key)
            counter += 1
            return pt
        } catch {
            throw CipherError.authFailed
        }
    }
}
