import XCTest
@testable import ATACore
@testable import ATAFakePhone

/// Collects engine events and lets a test wait for one.
final class EventRecorder {
    private let cond = NSCondition()
    private var events: [EngineEvent] = []

    func record(_ e: EngineEvent) { cond.lock(); events.append(e); cond.broadcast(); cond.unlock() }

    @discardableResult
    func wait<T>(_ timeout: TimeInterval = 10, _ match: (EngineEvent) -> T?) -> T? {
        cond.lock(); defer { cond.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        var seen = 0
        while true {
            while seen < events.count {
                if let t = match(events[seen]) { events.remove(at: seen); return t }
                seen += 1
            }
            if !cond.wait(until: deadline) { return nil }
        }
    }

    func sessionEnded(_ timeout: TimeInterval = 10) -> SessionSummary? {
        wait(timeout) { if case .sessionEnded(let s) = $0 { return s }; return nil }
    }
}

class EngineTestCase: XCTestCase {
    var dir: URL!
    var store: MemoryPairingStore!
    var engine: ReceiverEngine!
    var events: EventRecorder!
    let macId = randomBytes(16)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ata-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = MemoryPairingStore()
        events = EventRecorder()
        engine = makeEngine()
    }

    func makeEngine(idle: TimeInterval = 5, handshake: TimeInterval = 5) -> ReceiverEngine {
        var cfg = EngineConfig(macId: macId, macName: "Test Mac", saveDir: dir)
        cfg.idleTimeout = idle
        cfg.handshakeTimeout = handshake
        cfg.finishGrace = 2
        cfg.lanAddresses = { ["127.0.0.1"] }
        let e = ReceiverEngine(config: cfg, store: store)
        let ev = events!
        e.onEvent = { ev.record($0) }
        return e
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Everything in the save folder, including hidden temp files.
    func dirContents() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    func newPhone(phoneId: Data = randomBytes(16), name: String = "Pixel Test") -> (FakePhone, InMemoryLink) {
        let link = InMemoryLink(engine: engine)
        let p = FakePhone(channel: link, phoneId: phoneId, name: name)
        link.open()
        return (p, link)
    }

    /// Pairs a new phone (pairing:true) and returns it with its K, session still open.
    func pairedPhone(name: String = "Pixel Test") throws -> (FakePhone, InMemoryLink, Data) {
        let (uri, _) = engine.startPairing()
        let parsed = try XCTUnwrap(PairingOffer.parse(uri))
        XCTAssertEqual(parsed.macId, macId)
        let (p, link) = newPhone(name: name)
        try p.awaitHello()
        XCTAssertEqual(p.macId, macId)
        XCTAssertEqual(try p.authenticate(k: parsed.k, pairing: true), .ok(macName: "Test Mac"))
        return (p, link, parsed.k)
    }

    func files(_ sizes: [Int], names: [String]? = nil) -> [OutgoingFile] {
        sizes.enumerated().map { i, n in OutgoingFile(name: names?[i] ?? "file\(i).bin", data: randomBytes(n)) }
    }

    func accept(_ p: FakePhone, _ fs: [OutgoingFile]) throws -> UInt16 {
        let a = try p.requestSend(fs)
        XCTAssertEqual(a["t"] as? String, "accept", "\(a)")
        XCTAssertEqual(a["lan"] as? [String], ["127.0.0.1"])
        return UInt16(try XCTUnwrap(jsonInt64(a["tcpPort"])))
    }
}

final class HandshakeTests: EngineTestCase {
    func testPairingStoresKeyAndReconnects() throws {
        let (p, link, k) = try pairedPhone()
        XCTAssertNotNil(events.wait { if case .paired(let d) = $0 { return d }; return nil })
        XCTAssertEqual(store.devices().map(\.name), ["Pixel Test"])
        XCTAssertEqual(store.key(for: Hex.encode(p.phoneId)), k)
        try p.bye(ok: true, via: nil)
        XCTAssertEqual(events.sessionEnded()?.ok, true, "a pairing-only session is a success")
        link.disconnect()

        // Second connection: stored key, pairing:false.
        let (p2, _) = newPhone(phoneId: p.phoneId, name: "Pixel Renamed")
        try p2.awaitHello()
        XCTAssertEqual(try p2.authenticate(k: k, pairing: false), .ok(macName: "Test Mac"))
        XCTAssertNotNil(events.wait { if case .devicesChanged = $0, self.store.devices().first?.name == "Pixel Renamed" { return true }; return nil })
    }

    /// A Keychain read waiting on a user prompt must not freeze the engine (other links still get hello, etc.).
    func testSlowKeychainDoesNotBlockEngine() throws {
        final class SlowStore: PairingStore {
            let inner: MemoryPairingStore
            init(_ i: MemoryPairingStore) { inner = i }
            func devices() -> [PairedDevice] { inner.devices() }
            func key(for phoneId: String) -> Data? { Thread.sleep(forTimeInterval: 3); return inner.key(for: phoneId) }
            func save(_ device: PairedDevice, key: Data) throws { try inner.save(device, key: key) }
            func rename(phoneId: String, to name: String) { inner.rename(phoneId: phoneId, to: name) }
            func remove(phoneId: String) { inner.remove(phoneId: phoneId) }
        }
        var cfg = EngineConfig(macId: macId, macName: "Test Mac", saveDir: dir)
        cfg.handshakeTimeout = 1
        engine = ReceiverEngine(config: cfg, store: SlowStore(store))
        let k = randomBytes(32), pid = randomBytes(16)
        try store.save(PairedDevice(phoneId: Hex.encode(pid), name: "Slow", pairedAt: Date()), key: k)
        let (p, _) = newPhone(phoneId: pid)
        try p.awaitHello()
        let t0 = Date()
        let other = DispatchQueue.global()
        let done = DispatchSemaphore(value: 0)
        var result: FakePhone.AuthResult?
        other.async { result = try? p.authenticate(k: k, pairing: false); done.signal() }
        Thread.sleep(forTimeInterval: 0.3)
        let (p2, _) = newPhone()
        p2.timeout = 1
        try p2.awaitHello()                                   // engine still responsive
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1.5)
        // A pairing (Keychain write) completes while the slow read is still pending.
        let (uri, _) = engine.startPairing()
        XCTAssertEqual(try p2.authenticate(k: PairingOffer.parse(uri)!.k, pairing: true), .ok(macName: "Test Mac"))
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2.5)
        try p2.bye(ok: true, via: nil)
        Thread.sleep(forTimeInterval: 0.2)
        done.wait()
        XCTAssertEqual(result, .ok(macName: "Test Mac"))       // and not killed by the 1 s handshake timeout
    }

    func testPairingCodeIsSingleUse() throws {
        let (uri, _) = engine.startPairing()
        let k = PairingOffer.parse(uri)!.k
        let (p, link) = newPhone()
        try p.awaitHello()
        XCTAssertEqual(try p.authenticate(k: k, pairing: true), .ok(macName: "Test Mac"))
        try p.bye(ok: true, via: nil)
        _ = events.sessionEnded()
        link.disconnect()
        let (p2, _) = newPhone()
        try p2.awaitHello()
        XCTAssertEqual(try p2.authenticate(k: k, pairing: true), .fail(reason: "pairing_expired"))
    }

    func testPairingExpired() throws {
        let (p, link) = newPhone()
        try p.awaitHello()
        XCTAssertEqual(try p.authenticate(k: randomBytes(32), pairing: true), .fail(reason: "pairing_expired"))
        XCTAssertTrue(link.closedByMac)

        let (uri, _) = engine.startPairing(lifetime: 0.2)
        Thread.sleep(forTimeInterval: 0.4)
        let (p2, _) = newPhone()
        try p2.awaitHello()
        XCTAssertEqual(try p2.authenticate(k: PairingOffer.parse(uri)!.k, pairing: true), .fail(reason: "pairing_expired"))
    }

    func testBadMAC() throws {
        let (uri, _) = engine.startPairing()
        let (p, link) = newPhone()
        try p.awaitHello()
        XCTAssertEqual(try p.authenticate(k: PairingOffer.parse(uri)!.k, pairing: true, corruptMAC: true), .fail(reason: "bad_mac"))
        XCTAssertTrue(link.closedByMac)
        XCTAssertTrue(store.devices().isEmpty)
        XCTAssertNotNil(events.wait { if case .pairingFailed(let r) = $0 { return r }; return nil })

        // Wrong key for a stored phone.
        try store.save(PairedDevice(phoneId: Hex.encode(p.phoneId), name: "x", pairedAt: Date()), key: randomBytes(32))
        let (p2, _) = newPhone(phoneId: p.phoneId)
        try p2.awaitHello()
        XCTAssertEqual(try p2.authenticate(k: randomBytes(32), pairing: false), .fail(reason: "bad_mac"))
    }

    func testUnknownDeviceAndRemoval() throws {
        let (p, _) = newPhone()
        try p.awaitHello()
        XCTAssertEqual(try p.authenticate(k: randomBytes(32), pairing: false), .fail(reason: "unknown_device"))

        let (p2, l2, k) = try pairedPhone()
        try p2.bye(ok: true, via: nil)
        _ = events.sessionEnded()
        l2.disconnect()
        engine.removeDevice(phoneId: Hex.encode(p2.phoneId))
        let (p3, _) = newPhone(phoneId: p2.phoneId)
        try p3.awaitHello()
        XCTAssertEqual(try p3.authenticate(k: k, pairing: false), .fail(reason: "unknown_device"))
    }

    func testBadVersion() throws {
        let (p, _) = newPhone()
        try p.awaitHello()
        XCTAssertEqual(try p.authenticate(k: randomBytes(32), pairing: false, extra: ["v": 3]), .fail(reason: "bad_version"))
    }

    func testBusy() throws {
        let (_, _, _) = try pairedPhone()
        let (p2, l2) = newPhone()
        try p2.awaitHello()
        XCTAssertEqual(try p2.authenticate(k: randomBytes(32), pairing: false), .fail(reason: "busy"))
        XCTAssertTrue(l2.closedByMac)
    }

    /// SPEC §3: a central that only reads hello (and maybe lingers) does not occupy the session.
    func testProbeConnectionsDoNotBlock() throws {
        let (probe1, l1) = newPhone()
        try probe1.awaitHello()
        l1.disconnect()
        let (probe2, _) = newPhone()
        try probe2.awaitHello()          // stays connected, never authenticates
        XCTAssertFalse(engine.isBusy)
        let (_, _, _) = try pairedPhone()
        XCTAssertTrue(engine.isBusy)
    }

    /// SPEC §3: picker probes (subscribe → hello → disconnect), several in a row and overlapping a real
    /// session, never occupy the slot, never cause busy, emit no UI events, and each get a fresh nonce.
    func testProbeThenRealSession() throws {
        var nonces = Set<Data>()
        // Probes in a row.
        for _ in 0..<3 {
            let (probe, link) = newPhone()
            try probe.awaitHello()
            XCTAssertEqual(probe.macId, macId)
            nonces.insert(probe.nonceM)
            link.disconnect()
        }
        // Two overlapping probes that stay connected.
        let (pa, la) = newPhone(); try pa.awaitHello(); nonces.insert(pa.nonceM)
        let (pb, lb) = newPhone(); try pb.awaitHello(); nonces.insert(pb.nonceM)
        XCTAssertFalse(engine.isBusy)
        XCTAssertNil(events.wait(0.3) { e -> Bool? in
            switch e { case .sessionStarted, .sessionEnded, .transferAccepted, .pairingFailed: return true; default: return nil }
        }, "probes must not produce UI events")

        // Real session while probes are still connected.
        let (p, link, _) = try pairedPhone()
        nonces.insert(p.nonceM)
        XCTAssertEqual(nonces.count, 6, "every subscriber gets its own nonceM")
        XCTAssertNotNil(events.wait { if case .sessionStarted = $0 { return true }; return nil })
        XCTAssertTrue(engine.isBusy)

        // More probes during the real session: hello still sent, no events, session unaffected.
        let (pc, lc) = newPhone(); try pc.awaitHello(); lc.disconnect()
        la.disconnect(); lb.disconnect()
        XCTAssertTrue(engine.isBusy)
        let fs = files([100_000])
        let port = try accept(p, fs)
        let sock = try p.connectLAN(addresses: ["127.0.0.1"], port: port)
        XCTAssertEqual(try p.sendFilesLAN(sock, files: fs).map(\.ok), [true])
        try p.bye(ok: true, via: "lan")
        XCTAssertEqual(events.sessionEnded()?.ok, true)
        link.disconnect()
        XCTAssertNil(events.wait(0.3) { e -> Bool? in if case .sessionEnded = e { return true }; return nil },
                     "exactly one session ended; probes ended nothing")
        XCTAssertFalse(engine.isBusy)
    }

    func testHandshakeTimeout() throws {
        engine = makeEngine(handshake: 1)
        let (p, link) = newPhone()
        try p.awaitHello()
        Thread.sleep(forTimeInterval: 2.0)
        XCTAssertTrue(link.closedByMac)
    }

    func testIdleTimeoutFreesTheReceiver() throws {
        engine = makeEngine(idle: 1)
        let (_, _, k) = try pairedPhone()
        let s = try XCTUnwrap(events.sessionEnded(5))
        XCTAssertFalse(s.ok)
        XCTAssertTrue(s.error?.contains("timed out") == true, s.error ?? "")
        XCTAssertFalse(engine.isBusy)
        _ = k
    }

    func testCorruptedBLEMessageDropsSession() throws {
        let (p, link, _) = try pairedPhone()
        try p.sendRawCiphertext(randomBytes(40))
        let s = try XCTUnwrap(events.sessionEnded())
        XCTAssertFalse(s.ok)
        XCTAssertTrue(link.closedByMac)
    }

    func testReplayedBLEMessageDropsSession() throws {
        let (p, link, _) = try pairedPhone()
        // Seal a message with counter 0 by hand, send it twice.
        var c = CounterCipher(key: p.keys!.kP2M, prefix: 0)
        let wire = c.seal(ProtocolJSON.encode(["t": "noop"]))
        try p.sendRawCiphertext(wire)
        try p.sendRawCiphertext(wire)
        XCTAssertNotNil(events.sessionEnded())
        XCTAssertTrue(link.closedByMac)
    }
}

final class LANTransferTests: EngineTestCase {
    func testMultiFileTransfer() throws {
        let (p, link, _) = try pairedPhone()
        let fs = files([0, 1, 65_536, 300_001, 2_000_000], names: ["empty.txt", "one.bin", "a.jpg", "DCIM/b.mov", "a.jpg"])
        let port = try accept(p, fs)
        XCTAssertNotNil(events.wait { if case .transferAccepted(_, let n, _) = $0, n == 5 { return true }; return nil })
        let sock = try p.connectLAN(addresses: ["127.0.0.1"], port: port)
        let out = try p.sendFilesLAN(sock, files: fs)
        XCTAssertEqual(out, Array(repeating: FileOutcome(ok: true, error: nil), count: 5))
        try p.bye(ok: true, via: "lan")
        let s = try XCTUnwrap(events.sessionEnded())
        XCTAssertTrue(s.ok)
        XCTAssertEqual(s.via, "lan")
        XCTAssertEqual(s.saved.count, 5)
        XCTAssertEqual(dirContents(), ["a (1).jpg", "a.jpg", "b.mov", "empty.txt", "one.bin"])
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("a.jpg")), fs[2].data)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("a (1).jpg")), fs[4].data)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("b.mov")), fs[3].data)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("empty.txt")), Data())
        _ = link
    }

    func testSessionEndsWithoutByeAfterGrace() throws {
        let (p, _, _) = try pairedPhone()
        let fs = files([1000])
        let port = try accept(p, fs)
        let sock = try p.connectLAN(addresses: ["127.0.0.1"], port: port)
        XCTAssertEqual(try p.sendFilesLAN(sock, files: fs), [FileOutcome(ok: true, error: nil)])
        let s = try XCTUnwrap(events.sessionEnded(5))
        XCTAssertTrue(s.ok)
        XCTAssertFalse(engine.isBusy)
    }

    func testWrongSidIsRejectedThenRightSidWorks() throws {
        let (p, _, _) = try pairedPhone()
        let fs = files([5000])
        let port = try accept(p, fs)
        let bad = try p.connectLAN(addresses: ["127.0.0.1"], port: port)
        var t = LANTamper(); t.wrongSid = true
        XCTAssertThrowsError(try p.sendFilesLAN(bad, files: fs, tamper: t))
        XCTAssertEqual(dirContents(), [])
        let good = try p.connectLAN(addresses: ["127.0.0.1"], port: port)
        XCTAssertEqual(try p.sendFilesLAN(good, files: fs), [FileOutcome(ok: true, error: nil)])
        try p.bye(ok: true, via: "lan")
        XCTAssertEqual(events.sessionEnded()?.ok, true)
        XCTAssertEqual(dirContents(), ["file0.bin"])
    }

    func testCorruptedRecordAbortsAndDeletesTemp() throws {
        let (p, link, _) = try pairedPhone()
        let fs = files([300_000])
        let port = try accept(p, fs)
        let sock = try p.connectLAN(addresses: ["127.0.0.1"], port: port)
        var t = LANTamper(); t.corruptRecordIndex = 3   // 01, 02, 02, [02 corrupted]
        XCTAssertThrowsError(try p.sendFilesLAN(sock, files: fs, tamper: t))
        let s = try XCTUnwrap(events.sessionEnded())
        XCTAssertFalse(s.ok)
        XCTAssertTrue(s.error?.contains("LAN transfer failed") == true, s.error ?? "")
        XCTAssertEqual(dirContents(), [])
        XCTAssertTrue(link.closedByMac)
    }

    func testShaMismatchDeletesOnlyThatFile() throws {
        let (p, _, _) = try pairedPhone()
        let fs = files([10_000, 20_000], names: ["bad.bin", "good.bin"])
        let port = try accept(p, fs)
        let sock = try p.connectLAN(addresses: ["127.0.0.1"], port: port)
        var t = LANTamper(); t.badShaFiles = [0]
        let out = try p.sendFilesLAN(sock, files: fs, tamper: t)
        XCTAssertEqual(out.map(\.ok), [false, true])
        XCTAssertEqual(out[0].error, "sha256 mismatch")
        try p.bye(ok: false, via: "lan", error: "1 file failed")
        let s = try XCTUnwrap(events.sessionEnded())
        XCTAssertEqual(s.saved.map(\.lastPathComponent), ["good.bin"])
        XCTAssertEqual(s.failedFiles, 1)
        XCTAssertEqual(dirContents(), ["good.bin"])
    }

    func testTruncatedStream() throws {
        let (p, _, _) = try pairedPhone()
        let fs = files([500_000])
        let port = try accept(p, fs)
        let sock = try p.connectLAN(addresses: ["127.0.0.1"], port: port)
        var t = LANTamper(); t.truncateAfterBytes = 200_000
        XCTAssertThrowsError(try p.sendFilesLAN(sock, files: fs, tamper: t))
        let s = try XCTUnwrap(events.sessionEnded())
        XCTAssertFalse(s.ok)
        XCTAssertEqual(dirContents(), [])
    }

    func testBLEDropMidTransfer() throws {
        let (p, link, _) = try pairedPhone()
        let fs = files([1_000_000])
        let port = try accept(p, fs)
        let sock = try p.connectLAN(addresses: ["127.0.0.1"], port: port)
        let keys = try XCTUnwrap(p.keys)
        try sock.writeAll(keys.sid)
        var c = CounterCipher(key: keys.kFile, prefix: CounterCipher.tcpP2MPrefix)
        try sock.writeAll(TCPFrame.frame(c.seal(Record.fileStart(name: "x.bin", size: 1_000_000).encoded)))
        try sock.writeAll(TCPFrame.frame(c.seal(Record(.data, randomBytes(65_536)).encoded)))
        // Wait until the temp file exists.
        let deadline = Date().addingTimeInterval(3)
        while !dirContents().contains(where: { $0.hasSuffix(".part") }) && Date() < deadline { usleep(20_000) }
        XCTAssertEqual(dirContents().count, 1)
        link.disconnect()
        let s = try XCTUnwrap(events.sessionEnded())
        XCTAssertFalse(s.ok)
        XCTAssertEqual(s.error, "phone disconnected")
        // The TCP side is shut down by the Mac.
        XCTAssertThrowsError(try sock.readExact(1, timeout: 3))
        let d2 = Date().addingTimeInterval(3)
        while !dirContents().isEmpty && Date() < d2 { usleep(20_000) }
        XCTAssertEqual(dirContents(), [])
        XCTAssertFalse(engine.isBusy)
    }

    func testOversizedDataRecordIsRejected() throws {
        let (p, _, _) = try pairedPhone()
        let fs = files([200_000])
        let port = try accept(p, fs)
        let sock = try p.connectLAN(addresses: ["127.0.0.1"], port: port)
        XCTAssertThrowsError(try p.sendFilesLAN(sock, files: fs, chunk: 65_537))
        XCTAssertEqual(events.sessionEnded()?.ok, false)
        XCTAssertEqual(dirContents(), [])
    }

    func testRejectsBadSend() throws {
        let (p, _, _) = try pairedPhone()
        try p.sendEncrypted(["t": "send", "files": [], "total": 0])
        let r = try p.receiveEncrypted()
        XCTAssertEqual(r["t"] as? String, "reject")
        XCTAssertEqual(r["reason"] as? String, "bad_request")
    }

    func testLoopbackSignalServer() throws {
        let server = LoopbackSignalServer(engine: engine)
        try server.start(port: 0)
        defer { server.stop() }
        let (uri, _) = engine.startPairing()
        let ch = try LoopbackChannel(port: server.port)
        let p = FakePhone(channel: ch)
        try p.awaitHello()
        XCTAssertEqual(try p.authenticate(k: PairingOffer.parse(uri)!.k, pairing: true), .ok(macName: "Test Mac"))
        let fs = files([123_456, 7])
        let port = try accept(p, fs)
        let sock = try p.connectLAN(addresses: ["127.0.0.1"], port: port)
        XCTAssertEqual(try p.sendFilesLAN(sock, files: fs).map(\.ok), [true, true])
        try p.bye(ok: true, via: "lan")
        XCTAssertEqual(events.sessionEnded()?.ok, true)
        ch.disconnect()
        XCTAssertEqual(dirContents(), ["file0.bin", "file1.bin"])
    }
}

final class RTCTransferTests: EngineTestCase {
    func testWebRTCLoopbackMultiFile() throws {
        let (p, _, _) = try pairedPhone()
        let fs = files([0, 40_000, 3_000_000], names: ["z.txt", "y.bin", "x.bin"])
        _ = try accept(p, fs)
        let out = try p.sendFilesRTC(fs, badShaFiles: [])
        XCTAssertEqual(out.map(\.ok), [true, true, true])
        try p.bye(ok: true, via: "rtc")
        let s = try XCTUnwrap(events.sessionEnded(15))
        XCTAssertTrue(s.ok)
        XCTAssertEqual(s.via, "rtc")
        XCTAssertEqual(dirContents(), ["x.bin", "y.bin", "z.txt"])
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("x.bin")), fs[2].data)
    }

    func testWebRTCShaMismatch() throws {
        let (p, _, _) = try pairedPhone()
        let fs = files([50_000, 60_000])
        _ = try accept(p, fs)
        let out = try p.sendFilesRTC(fs, badShaFiles: [1])
        XCTAssertEqual(out.map(\.ok), [true, false])
        try p.bye(ok: false, via: "rtc", error: "1 failed")
        _ = events.sessionEnded(15)
        XCTAssertEqual(dirContents(), ["file0.bin"])
    }
}
