import Foundation
import CryptoKit
import ATACore

public struct FakePhoneError: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

/// A file to send: name plus bytes (memory-mapped for files on disk).
public struct OutgoingFile {
    public let name: String
    public let data: Data
    public init(name: String, data: Data) { self.name = name; self.data = data }
    public init(url: URL) throws {
        name = url.lastPathComponent
        data = try Data(contentsOf: url, options: .alwaysMapped)
    }
}

public struct FileOutcome: Equatable {
    public let ok: Bool
    public let error: String?
}

/// Tamper switches for negative tests of the LAN TCP path.
public struct LANTamper {
    public var wrongSid = false
    /// Flip one bit in the sealed bytes of the n-th record sent (0-based, counting every record).
    public var corruptRecordIndex: Int?
    /// Send a wrong sha256 for these file indices.
    public var badShaFiles: Set<Int> = []
    /// Close the socket after this many payload bytes of the first file.
    public var truncateAfterBytes: Int?
    public init() {}
}

/// Phone side of SPEC v2 (handshake, encrypted BLE messages, LAN TCP sender). Blocking, for tests and the CLI.
public final class FakePhone {
    public let channel: PhoneChannel
    public let phoneId: Data
    public let name: String
    public var timeout: TimeInterval = 10
    public var log: (String) -> Void = { _ in }

    public private(set) var macId = Data()
    public private(set) var nonceM = Data()
    public private(set) var nonceP = Data()
    public private(set) var macName = ""
    public private(set) var keys: ATACrypto.SessionKeys?
    private var txCipher: CounterCipher?
    private var rxCipher: CounterCipher?

    public init(channel: PhoneChannel, phoneId: Data = randomBytes(16), name: String = "Fake Phone") {
        self.channel = channel
        self.phoneId = phoneId
        self.name = name
    }

    // MARK: handshake

    public func awaitHello() throws {
        let m = try receivePlain()
        guard m["t"] as? String == "hello", jsonInt64(m["v"]) == 2,
              let id = (m["id"] as? String).flatMap(Hex.decode), id.count == 16,
              let n = (m["n"] as? String).flatMap(B64.decode), n.count == 16 else {
            throw FakePhoneError("bad hello: \(m)")
        }
        macId = id
        nonceM = n
        log("hello from mac \(Hex.encode(id))")
    }

    public enum AuthResult: Equatable { case ok(macName: String), fail(reason: String) }

    /// Sends `auth`; on `auth_ok` verifies the Mac's MAC and derives the session keys.
    public func authenticate(k: Data, pairing: Bool, corruptMAC: Bool = false, extra: [String: Any] = [:]) throws -> AuthResult {
        nonceP = randomBytes(16)
        var mac = ATACrypto.phoneAuthMAC(k: k, macId: macId, phoneId: phoneId, nonceM: nonceM, nonceP: nonceP)
        if corruptMAC { mac[mac.startIndex] ^= 0x01 }
        var auth: [String: Any] = ["t": "auth", "id": Hex.encode(phoneId), "name": name, "n": B64.encode(nonceP),
                                   "pairing": pairing, "mac": B64.encode(mac)]
        for (k, v) in extra { auth[k] = v }
        try channel.send(ProtocolJSON.encode(auth))
        let r = try receivePlain()
        switch r["t"] as? String {
        case "auth_ok":
            guard let theirs = (r["mac"] as? String).flatMap(B64.decode) else { throw FakePhoneError("auth_ok without mac") }
            let expect = ATACrypto.macAuthMAC(k: k, macId: macId, phoneId: phoneId, nonceM: nonceM, nonceP: nonceP)
            guard ATACrypto.constantTimeEqual(theirs, expect) else { throw FakePhoneError("Mac's auth_ok mac is wrong") }
            let ks = ATACrypto.deriveSessionKeys(k: k, nonceM: nonceM, nonceP: nonceP)
            keys = ks
            txCipher = CounterCipher(key: ks.kP2M, prefix: CounterCipher.bleP2MPrefix)
            rxCipher = CounterCipher(key: ks.kM2P, prefix: CounterCipher.bleM2PPrefix)
            macName = r["name"] as? String ?? ""
            log("auth_ok from \"\(macName)\"")
            return .ok(macName: macName)
        case "auth_fail":
            let reason = r["reason"] as? String ?? "?"
            log("auth_fail \(reason)")
            return .fail(reason: reason)
        default:
            throw FakePhoneError("unexpected reply to auth: \(r)")
        }
    }

    private func receivePlain() throws -> [String: Any] {
        let d = try channel.receive(timeout: timeout)
        guard let m = ProtocolJSON.decode(d) else { throw FakePhoneError("non-JSON plaintext message") }
        return m
    }

    // MARK: encrypted messages

    public func sendEncrypted(_ obj: [String: Any]) throws {
        guard var c = txCipher else { throw FakePhoneError("not authenticated") }
        let wire = c.seal(ProtocolJSON.encode(obj))
        txCipher = c
        try channel.send(wire)
    }

    /// Sends raw bytes as an encrypted-phase message (for tamper tests); advances the counter like a real send.
    public func sendRawCiphertext(_ wire: Data, advanceCounter: Bool = true) throws {
        if advanceCounter, var c = txCipher { _ = c.seal(Data()); txCipher = c }
        try channel.send(wire)
    }

    public func receiveEncrypted(timeout t: TimeInterval? = nil) throws -> [String: Any] {
        guard var c = rxCipher else { throw FakePhoneError("not authenticated") }
        let d = try channel.receive(timeout: t ?? timeout)
        let pt = try c.open(d)
        rxCipher = c
        guard let m = ProtocolJSON.decode(pt) else { throw FakePhoneError("encrypted message is not JSON") }
        return m
    }

    /// Sends `send` and returns the Mac's reply (`accept` or `reject`).
    public func requestSend(_ files: [OutgoingFile]) throws -> [String: Any] {
        let list: [[String: Any]] = files.map { ["name": $0.name, "size": $0.data.count] }
        try sendEncrypted(["t": "send", "files": list, "total": files.reduce(0) { $0 + $1.data.count }])
        return try receiveEncrypted()
    }

    public func bye(ok: Bool, via: String?, error: String? = nil) throws {
        try sendEncrypted(["t": "bye", "ok": ok, "via": via.map { $0 as Any } ?? NSNull(), "error": error.map { $0 as Any } ?? NSNull()])
    }

    // MARK: LAN TCP (SPEC §7a)

    /// Tries each address with a 1.5 s connect timeout, like the Android sender.
    public func connectLAN(addresses: [String], port: UInt16) throws -> TCPSocket {
        var last: Error = FakePhoneError("no addresses")
        for ip in addresses {
            do {
                let s = try TCPSocket.connect(ip: ip, port: port, timeout: 1.5)
                log("TCP connected to \(ip):\(port)")
                return s
            } catch { last = error; log("TCP \(ip):\(port) failed: \(error)") }
        }
        throw last
    }

    /// Sends all files over an already-connected socket and returns the per-file 0x04 outcomes.
    /// Throws if the Mac closes the connection (e.g. after a corrupted record) or a tamper truncates the stream.
    public func sendFilesLAN(_ sock: TCPSocket, files: [OutgoingFile], tamper: LANTamper = LANTamper(),
                             chunk: Int = TCPFrame.maxDataPlaintext) throws -> [FileOutcome] {
        guard let keys else { throw FakePhoneError("not authenticated") }
        try sock.writeAll(tamper.wrongSid ? randomBytes(16) : keys.sid)
        var out = CounterCipher(key: keys.kFile, prefix: CounterCipher.tcpP2MPrefix)
        var inn = CounterCipher(key: keys.kFile, prefix: CounterCipher.tcpM2PPrefix)
        var recordIndex = 0
        func put(_ r: Record) throws {
            var sealed = out.seal(r.encoded)
            if tamper.corruptRecordIndex == recordIndex { sealed[sealed.startIndex + sealed.count / 2] ^= 0x40 }
            recordIndex += 1
            try sock.writeAll(TCPFrame.frame(sealed))
        }
        var outcomes: [FileOutcome] = []
        for (i, f) in files.enumerated() {
            try put(.fileStart(name: f.name, size: Int64(f.data.count)))
            var hasher = SHA256()
            var off = 0
            while off < f.data.count {
                let end = min(off + chunk, f.data.count)
                if i == 0, let t = tamper.truncateAfterBytes, end > t {
                    let piece = f.data.subdata(in: off..<max(off, t))
                    if !piece.isEmpty { try put(Record(.data, piece)) }
                    log("truncating stream after \(t) B")
                    sock.shutdown(); sock.close()
                    throw FakePhoneError("truncated by tamper")
                }
                let piece = f.data.subdata(in: off..<end)
                hasher.update(data: piece)
                try put(Record(.data, piece))
                off = end
            }
            let sha = tamper.badShaFiles.contains(i) ? String(repeating: "0", count: 64) : Hex.encode(Data(hasher.finalize()))
            try put(.fileEnd(sha256: sha))
            let n = TCPFrame.length(of: try sock.readExact(4, timeout: 30))
            let rec = try Record.decode(try inn.open(try sock.readExact(n, timeout: 30)))
            guard rec.type == .fileResult, let j = rec.jsonBody() else { throw FakePhoneError("expected 0x04") }
            let o = FileOutcome(ok: jsonBool(j["ok"]) ?? false, error: j["error"] as? String)
            log("file \(i) \"\(f.name)\": \(o.ok ? "ok" : "failed: \(o.error ?? "?")")")
            outcomes.append(o)
        }
        try put(Record(.allDone))
        return outcomes
    }
}
