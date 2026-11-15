import XCTest
@testable import ATACore

/// SPEC §8: every value in spec/vectors.json.
final class VectorTests: XCTestCase {
    struct V {
        let j: [String: Any]
        func s(_ path: String) -> String {
            var o: Any = j
            for p in path.split(separator: ".") { o = (o as! [String: Any])[String(p)]! }
            return o as! String
        }
        func h(_ path: String) -> Data { Hex.decode(s(path))! }
    }

    static func vectors() throws -> V {
        // Tests/ATACoreTests/CodecTests.swift → ../../../spec/vectors.json (the canonical file, not a copy)
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../spec/vectors.json").standardizedFileURL
        let d = try Data(contentsOf: url)
        return V(j: try JSONSerialization.jsonObject(with: d) as! [String: Any])
    }

    func testHandshakeMACs() throws {
        let v = try Self.vectors()
        let k = v.h("inputs.K"), mid = v.h("inputs.macId"), pid = v.h("inputs.phoneId")
        let nM = v.h("inputs.nonceM"), nP = v.h("inputs.nonceP")
        XCTAssertEqual(Base64URL.encode(k), v.s("inputs.K_b64url"))
        XCTAssertEqual(Base64URL.decode(v.s("inputs.K_b64url")), k)
        let phone = ATACrypto.phoneAuthMAC(k: k, macId: mid, phoneId: pid, nonceM: nM, nonceP: nP)
        XCTAssertEqual(Hex.encode(phone), v.s("handshake.auth_phone_mac"))
        XCTAssertEqual(B64.encode(phone), v.s("handshake.auth_phone_mac_b64"))
        let mac = ATACrypto.macAuthMAC(k: k, macId: mid, phoneId: pid, nonceM: nM, nonceP: nP)
        XCTAssertEqual(Hex.encode(mac), v.s("handshake.auth_mac_mac"))
        XCTAssertEqual(B64.encode(mac), v.s("handshake.auth_mac_mac_b64"))
    }

    func testKeySchedule() throws {
        let v = try Self.vectors()
        let ks = ATACrypto.deriveSessionKeys(k: v.h("inputs.K"), nonceM: v.h("inputs.nonceM"), nonceP: v.h("inputs.nonceP"))
        XCTAssertEqual(Hex.encode(ks.kP2M), v.s("keys.kP2M"))
        XCTAssertEqual(Hex.encode(ks.kM2P), v.s("keys.kM2P"))
        XCTAssertEqual(Hex.encode(ks.kFile), v.s("keys.kFile"))
        XCTAssertEqual(Hex.encode(ks.sid), v.s("keys.sid"))
    }

    func testBLEMessages() throws {
        let v = try Self.vectors()
        let ks = ATACrypto.deriveSessionKeys(k: v.h("inputs.K"), nonceM: v.h("inputs.nonceM"), nonceP: v.h("inputs.nonceP"))
        let p2mPlain = Data(v.s("ble_p2m.plaintext_utf8").utf8)
        var seal = CounterCipher(key: ks.kP2M, prefix: CounterCipher.bleP2MPrefix)
        XCTAssertEqual(Hex.encode(seal.seal(p2mPlain)), v.s("ble_p2m.counter0_wire"))
        XCTAssertEqual(Hex.encode(seal.seal(p2mPlain)), v.s("ble_p2m.counter1_wire"))
        var open = CounterCipher(key: ks.kP2M, prefix: CounterCipher.bleP2MPrefix)
        XCTAssertEqual(try open.open(v.h("ble_p2m.counter0_wire")), p2mPlain)
        XCTAssertEqual(try open.open(v.h("ble_p2m.counter1_wire")), p2mPlain)

        let m2pPlain = Data(v.s("ble_m2p.plaintext_utf8").utf8)
        var m2p = CounterCipher(key: ks.kM2P, prefix: CounterCipher.bleM2PPrefix)
        XCTAssertEqual(Hex.encode(m2p.seal(m2pPlain)), v.s("ble_m2p.counter0_wire"))

        // Wrong counter (replay) fails.
        var replay = CounterCipher(key: ks.kP2M, prefix: 0, counter: 1)
        XCTAssertThrowsError(try replay.open(v.h("ble_p2m.counter0_wire")))
    }

    func testTCPRecords() throws {
        let v = try Self.vectors()
        let ks = ATACrypto.deriveSessionKeys(k: v.h("inputs.K"), nonceM: v.h("inputs.nonceM"), nonceP: v.h("inputs.nonceP"))
        XCTAssertEqual(Hex.encode(CounterCipher.nonce(prefix: 1, counter: 5)), v.s("tcp_record_p2m.nonce"))
        XCTAssertEqual(Hex.encode(CounterCipher.nonce(prefix: 2, counter: 0)), v.s("tcp_record_m2p.nonce"))

        var p2m = CounterCipher(key: ks.kFile, prefix: CounterCipher.tcpP2MPrefix, counter: 5)
        let wire = TCPFrame.frame(p2m.seal(v.h("tcp_record_p2m.record_plaintext")))
        XCTAssertEqual(Hex.encode(wire), v.s("tcp_record_p2m.wire_with_length_prefix"))
        XCTAssertEqual(try Record.decode(v.h("tcp_record_p2m.record_plaintext")), Record(.data, Data("abc".utf8)))

        var m2p = CounterCipher(key: ks.kFile, prefix: CounterCipher.tcpM2PPrefix)
        let reply = Record.fileResult(ok: true)
        XCTAssertEqual(Hex.encode(reply.encoded), v.s("tcp_record_m2p.record_plaintext"))
        XCTAssertEqual(Hex.encode(m2p.seal(reply.encoded)), v.s("tcp_record_m2p.sealed"))

        // And the receiver side opens the vector frame.
        var rx = CounterCipher(key: ks.kFile, prefix: CounterCipher.tcpP2MPrefix, counter: 5)
        let w = v.h("tcp_record_p2m.wire_with_length_prefix")
        XCTAssertEqual(TCPFrame.length(of: w.prefix(4)), w.count - 4)
        XCTAssertEqual(Hex.encode(try rx.open(w.dropFirst(4))), v.s("tcp_record_p2m.record_plaintext"))
    }
}

final class FramingTests: XCTestCase {
    func testFragmentRoundTrip() throws {
        for size in [0, 1, 18, 19, 20, 181, 182, 511, 512, 513, 5000, 70_000] {
            for maxFrag in [20, 23, 182, 185, 512, 600] {
                let msg = randomBytes(size)
                let frags = Fragmenter.fragment(msg, maxFragment: maxFrag)
                XCTAssertTrue(frags.allSatisfy { $0.count <= min(maxFrag, 512) && $0.count >= 1 })
                XCTAssertTrue(frags.dropLast().allSatisfy { $0.first == 0x00 })
                XCTAssertEqual(frags.last?.first, 0x01)
                var r = Reassembler()
                var out: Data?
                for (i, f) in frags.enumerated() {
                    out = try r.feed(f)
                    if i < frags.count - 1 { XCTAssertNil(out) }
                }
                XCTAssertEqual(out, msg, "size \(size) maxFrag \(maxFrag)")
            }
        }
    }

    func testFragmentErrors() {
        var r = Reassembler()
        XCTAssertThrowsError(try r.feed(Data()))
        XCTAssertThrowsError(try r.feed(Data([0x02, 0x41])))
        var big = Reassembler()
        let chunk = Data([0x00]) + Data(count: 511)
        XCTAssertThrowsError(try { for _ in 0..<1000 { _ = try big.feed(chunk) } }())
    }

    func testRecordFraming() throws {
        let r = Record.fileStart(name: "a.jpg", size: 12345)
        XCTAssertEqual(r.encoded.first, 0x01)
        let back = try Record.decode(r.encoded)
        XCTAssertEqual(back.type, .fileStart)
        XCTAssertEqual(back.jsonBody()?["name"] as? String, "a.jpg")
        XCTAssertEqual(jsonInt64(back.jsonBody()?["size"]), 12345)
        XCTAssertEqual(Record(.allDone).encoded, Data([0x05]))
        XCTAssertThrowsError(try Record.decode(Data([0x09])))
        XCTAssertThrowsError(try Record.decode(Data()))
        XCTAssertNoThrow(try TCPFrame.checkLength(17))
        XCTAssertNoThrow(try TCPFrame.checkLength(1 << 20))
        XCTAssertThrowsError(try TCPFrame.checkLength((1 << 20) + 1))
        XCTAssertThrowsError(try TCPFrame.checkLength(16))
        XCTAssertEqual(TCPFrame.frame(Data(count: 300)).prefix(4), Data([0, 0, 1, 0x2c]))
    }

    func testJSONNumbers() {
        XCTAssertEqual(jsonInt64(ProtocolJSON.decode(Data(#"{"a":3}"#.utf8))?["a"]), 3)
        XCTAssertEqual(jsonInt64(ProtocolJSON.decode(Data(#"{"a":3.0}"#.utf8))?["a"]), 3)
        XCTAssertNil(jsonInt64(ProtocolJSON.decode(Data(#"{"a":3.5}"#.utf8))?["a"]))
        XCTAssertNil(jsonInt64(ProtocolJSON.decode(Data(#"{"a":true}"#.utf8))?["a"]))
        XCTAssertNil(jsonInt64(ProtocolJSON.decode(Data(#"{"a":"3"}"#.utf8))?["a"]))
        XCTAssertEqual(jsonBool(ProtocolJSON.decode(Data(#"{"a":true}"#.utf8))?["a"]), true)
        XCTAssertNil(jsonBool(ProtocolJSON.decode(Data(#"{"a":1}"#.utf8))?["a"]))
    }

    func testSanitizeFileName() {
        XCTAssertEqual(sanitizeFileName("a.jpg"), "a.jpg")
        XCTAssertEqual(sanitizeFileName("../../etc/passwd"), "passwd")
        XCTAssertEqual(sanitizeFileName("DCIM/Camera/IMG_1.jpg"), "IMG_1.jpg")
        XCTAssertEqual(sanitizeFileName("..\\x\\y.txt"), "y.txt")
        XCTAssertEqual(sanitizeFileName(".hidden"), "hidden")
        XCTAssertEqual(sanitizeFileName(""), "file")
        XCTAssertEqual(sanitizeFileName(".."), "file")
        XCTAssertEqual(sanitizeFileName("a:b\u{01}.txt"), "a_b_.txt")
        XCTAssertLessThanOrEqual(sanitizeFileName(String(repeating: "é", count: 300) + ".jpg").utf8.count, 240)
        XCTAssertTrue(sanitizeFileName(String(repeating: "é", count: 300) + ".jpg").hasSuffix(".jpg"))
    }

    func testPairingURI() throws {
        let macId = Hex.decode("a0a1a2a3a4a5a6a7a8a9aaabacadaeaf")!
        let k = Hex.decode("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")!
        let o = PairingOffer(k: k)
        let uri = o.uri(macId: macId, macName: "Ann's MacBook Pro & 中文")
        XCTAssertEqual(uri, "ata://pair?v=2&id=a0a1a2a3a4a5a6a7a8a9aaabacadaeaf&name=Ann%27s%20MacBook%20Pro%20%26%20%E4%B8%AD%E6%96%87&k=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
        let p = try XCTUnwrap(PairingOffer.parse(uri))
        XCTAssertEqual(p.macId, macId)
        XCTAssertEqual(p.k, k)
        XCTAssertEqual(p.name, "Ann's MacBook Pro & 中文")
        XCTAssertTrue(o.isValid())
        XCTAssertFalse(o.isValid(at: Date().addingTimeInterval(301)))
    }

    func testAdvertisedLocalName() {
        XCTAssertEqual(BLEPeripheral.localName(macId: Hex.decode("a0a1a2a3a4a5a6a7a8a9aaabacadaeaf")!), "ATA-a0a1a2a3")
    }

    func testConstantTimeEqual() {
        XCTAssertTrue(ATACrypto.constantTimeEqual(Data([1, 2, 3]), Data([1, 2, 3])))
        XCTAssertFalse(ATACrypto.constantTimeEqual(Data([1, 2, 3]), Data([1, 2, 4])))
        XCTAssertFalse(ATACrypto.constantTimeEqual(Data([1, 2]), Data([1, 2, 3])))
        XCTAssertTrue(ATACrypto.constantTimeEqual(Data(), Data()))
    }
}
