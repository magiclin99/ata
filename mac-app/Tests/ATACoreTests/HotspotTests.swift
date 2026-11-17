import XCTest
@testable import ATACore
@testable import ATAFakePhone

/// A Wi-Fi radio that only exists in memory. Thread-safe; records every call.
final class FakeRadio: WiFiRadio {
    private let lock = NSLock()
    private var _powered: Bool
    private var _ip: String?
    private(set) var calls: [String] = []
    private(set) var passwords: [String] = []
    /// Join attempts that fail (scan sees nothing) before one succeeds; nil = never succeeds.
    var notFoundTimes: Int? = 0
    var joinError: HotspotError?
    /// Address given by the phone's hotspot (the fake phone connects to it, so tests use loopback).
    var hotspotIP = "127.0.0.1"
    /// Address the Mac had before, and gets back when macOS rejoins its usual network.
    let homeIP: String?
    /// macOS rejoins the usual network by itself after `disassociate` (else only after a power cycle).
    var autoRejoin = true
    var rejoinAfterPowerCycle = true

    init(powered: Bool = true, homeIP: String? = "10.1.2.3") {
        _powered = powered; self.homeIP = homeIP; _ip = powered ? homeIP : nil
    }

    private func record(_ c: String) { lock.lock(); calls.append(c); lock.unlock() }
    var ip: String? { lock.lock(); defer { lock.unlock() }; return _ip }

    let hasWiFi = true
    func isPowered() -> Bool { lock.lock(); defer { lock.unlock() }; return _powered }
    func setPower(_ on: Bool) throws {
        record("power \(on ? "on" : "off")")
        lock.lock(); defer { lock.unlock() }
        _powered = on
        _ip = on && rejoinAfterPowerCycle ? homeIP : nil
    }
    func ipv4() -> String? { ip }
    func join(ssid: String, password: String) throws {
        record("join \(ssid)")
        lock.lock(); defer { lock.unlock() }
        passwords.append(password)
        if let e = joinError { throw e }
        guard let n = notFoundTimes else { throw HotspotError.notFound }
        if n > 0 { notFoundTimes = n - 1; throw HotspotError.notFound }
        _ip = hotspotIP
    }
    func disassociate() {
        record("disassociate")
        lock.lock(); defer { lock.unlock() }
        _ip = autoRejoin ? homeIP : nil
    }
}

func fastTimings() -> HotspotTimings {
    var t = HotspotTimings()
    t.scanFor = 1; t.retryEvery = 0.1; t.addressWait = 1; t.rejoinWait = 0.4; t.powerCycleWait = 0.4; t.poll = 0.02
    return t
}

final class HotspotJoinerTests: XCTestCase {
    var marker: URL!

    override func setUp() {
        marker = FileManager.default.temporaryDirectory.appendingPathComponent("ata-wifi-\(UUID().uuidString).json")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: marker) }

    func join(_ j: HotspotJoiner) -> Result<String, HotspotError> {
        let e = expectation(description: "join")
        var r: Result<String, HotspotError>!
        j.join(ssid: "Phone-1234", password: "secret-pass-123") { r = $0; e.fulfill() }
        wait(for: [e], timeout: 5)
        return r
    }

    func restore(_ j: HotspotJoiner) -> Bool {
        let e = expectation(description: "restore")
        var ok = false
        j.restore { ok = $0; e.fulfill() }
        wait(for: [e], timeout: 5)
        return ok
    }

    func testJoinThenAutomaticRejoin() throws {
        let radio = FakeRadio()
        let j = HotspotJoiner(radio: radio, markerURL: marker, timings: fastTimings())
        XCTAssertEqual(try join(j).get(), "127.0.0.1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "restore note written before touching Wi-Fi")
        XCTAssertTrue(restore(j))
        XCTAssertEqual(radio.calls, ["join Phone-1234", "disassociate"])
        XCTAssertEqual(radio.ip, "10.1.2.3")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(restore(j), "second restore is a no-op")
        XCTAssertEqual(radio.calls.count, 2)
    }

    func testPowerCycleWhenMacOSDoesNotRejoin() throws {
        let radio = FakeRadio()
        radio.autoRejoin = false
        let j = HotspotJoiner(radio: radio, markerURL: marker, timings: fastTimings())
        _ = try join(j).get()
        XCTAssertTrue(restore(j))
        XCTAssertEqual(radio.calls, ["join Phone-1234", "disassociate", "power off", "power on"])
    }

    func testRestoreNotConfirmed() throws {
        let radio = FakeRadio()
        radio.autoRejoin = false
        radio.rejoinAfterPowerCycle = false
        let j = HotspotJoiner(radio: radio, markerURL: marker, timings: fastTimings())
        _ = try join(j).get()
        XCTAssertFalse(restore(j))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testWiFiThatWasOffIsTurnedOffAgain() throws {
        let radio = FakeRadio(powered: false)
        let j = HotspotJoiner(radio: radio, markerURL: marker, timings: fastTimings())
        _ = try join(j).get()
        XCTAssertTrue(restore(j))
        XCTAssertEqual(radio.calls, ["power on", "join Phone-1234", "disassociate", "power off"])
        XCTAssertFalse(radio.isPowered())
    }

    func testRetriesUntilTheHotspotShowsUp() throws {
        let radio = FakeRadio()
        radio.notFoundTimes = 2
        let j = HotspotJoiner(radio: radio, markerURL: marker, timings: fastTimings())
        XCTAssertEqual(try join(j).get(), "127.0.0.1")
        XCTAssertEqual(radio.calls, ["join Phone-1234", "join Phone-1234", "join Phone-1234"])
    }

    func testNeverFoundLeavesTheNetworkAlone() {
        let radio = FakeRadio()
        radio.notFoundTimes = nil
        let j = HotspotJoiner(radio: radio, markerURL: marker, timings: fastTimings())
        XCTAssertEqual(join(j), .failure(.notFound))
        XCTAssertTrue(restore(j))
        XCTAssertFalse(radio.calls.contains("disassociate"), "nothing was changed, so the Mac is not disconnected")
        XCTAssertEqual(radio.ip, "10.1.2.3")
    }

    func testFailedAssociationIsUndone() {
        let radio = FakeRadio()
        radio.joinError = .joinFailed("associate: test")
        radio.autoRejoin = true
        let j = HotspotJoiner(radio: radio, markerURL: marker, timings: fastTimings())
        if case .failure(.joinFailed) = join(j) {} else { XCTFail("expected joinFailed") }
        XCTAssertTrue(restore(j))
        XCTAssertTrue(radio.calls.contains("disassociate"))
    }

    func testRestoreDuringJoinStopsTheJoin() {
        let radio = FakeRadio()
        radio.notFoundTimes = nil
        var t = fastTimings(); t.scanFor = 30
        let j = HotspotJoiner(radio: radio, markerURL: marker, timings: t)
        let e = expectation(description: "join ends")
        var r: Result<String, HotspotError>?
        j.join(ssid: "Phone-1234", password: "secret-pass-123") { r = $0; e.fulfill() }
        Thread.sleep(forTimeInterval: 0.2)
        let started = Date()
        XCTAssertTrue(restore(j))
        wait(for: [e], timeout: 2)
        XCTAssertEqual(r, .failure(.cancelled))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testCrashRecoveryRestoresOnlyWhenStillOnTheHotspot() throws {
        // Still on the hotspot: restore.
        let radio = FakeRadio()
        _ = try join(HotspotJoiner(radio: radio, markerURL: marker, timings: fastTimings())).get()
        // (the process "crashed": a new joiner finds the note)
        let j2 = HotspotJoiner(radio: radio, markerURL: marker, timings: fastTimings())
        let e = expectation(description: "recover")
        j2.recoverAfterCrash { ok in XCTAssertTrue(ok); e.fulfill() }
        wait(for: [e], timeout: 5)
        XCTAssertEqual(radio.calls.last, "disassociate")
        XCTAssertEqual(radio.ip, "10.1.2.3")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

        // Already back home: leave it alone.
        let radio2 = FakeRadio()
        _ = try join(HotspotJoiner(radio: radio2, markerURL: marker, timings: fastTimings())).get()
        radio2.disassociate()
        let before = radio2.calls.count
        let e2 = expectation(description: "recover 2")
        HotspotJoiner(radio: radio2, markerURL: marker, timings: fastTimings()).recoverAfterCrash { _ in e2.fulfill() }
        wait(for: [e2], timeout: 5)
        XCTAssertEqual(radio2.calls.count, before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testSameSubnet() {
        XCTAssertTrue(sameSubnet24("192.168.49.20", "192.168.49.1"))
        XCTAssertFalse(sameSubnet24("192.168.48.20", "192.168.49.1"))
        XCTAssertFalse(sameSubnet24("192.168.49.20", nil))
    }
}

/// The engine side of SPEC §7c with a fake phone and a fake radio.
final class HotspotEngineTests: EngineTestCase {
    var radio: FakeRadio!
    var joiner: HotspotJoiner!
    var logURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        radio = FakeRadio()
        joiner = HotspotJoiner(radio: radio, markerURL: dir.appendingPathComponent(".wifi-restore.json"), timings: fastTimings())
        var cfg = EngineConfig(macId: macId, macName: "Test Mac", saveDir: dir)
        cfg.idleTimeout = 5; cfg.handshakeTimeout = 5; cfg.finishGrace = 2
        cfg.lanAddresses = { ["127.0.0.1"] }
        cfg.hotspot = joiner
        engine = ReceiverEngine(config: cfg, store: store)
        let ev = events!
        engine.onEvent = { ev.record($0) }
        logURL = FileManager.default.temporaryDirectory.appendingPathComponent("ata-log-\(UUID().uuidString).txt")
        Log.setFile(logURL)
    }

    override func tearDownWithError() throws {
        Log.setFile(nil)
        let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: logURL)
        XCTAssertFalse(log.contains(psk), "the hotspot password must never be logged")
        try super.tearDownWithError()
    }

    let psk = "Pw-0f-the-ph0ne"

    func sendWithCaps(_ p: FakePhone, _ fs: [OutgoingFile], caps: [String]? = ["hotspot"]) throws -> [String: Any] {
        var m: [String: Any] = ["t": "send", "files": fs.map { ["name": $0.name, "size": $0.data.count] },
                                "total": fs.reduce(0) { $0 + $1.data.count }]
        if let caps { m["caps"] = caps }
        try p.sendEncrypted(m)
        return try p.receiveEncrypted()
    }

    func restoredEvent() -> Bool? {
        events.wait(5) { if case .wifiRestored(let ok) = $0 { return ok }; return nil }
    }

    func testTransferOverThePhonesHotspot() throws {
        let (p, link, _) = try pairedPhone()
        let fs = files([300_000])
        let a = try sendWithCaps(p, fs)
        XCTAssertEqual(a["hotspot"] as? Bool, true)
        try p.sendEncrypted(["t": "hotspot", "ssid": "Phone-1234", "psk": psk])
        let r = try p.receiveEncrypted()
        XCTAssertEqual(r["t"] as? String, "hotspot_ready", "\(r)")
        XCTAssertEqual(r["lan"] as? [String], ["127.0.0.1"])
        XCTAssertEqual(jsonInt64(r["tcpPort"]), jsonInt64(a["tcpPort"]))
        XCTAssertEqual(radio.passwords, [psk])
        let sock = try p.connectLAN(addresses: ["127.0.0.1"], port: UInt16(try XCTUnwrap(jsonInt64(r["tcpPort"]))))
        XCTAssertEqual(try p.sendFilesLAN(sock, files: fs), [FileOutcome(ok: true, error: nil)])
        try p.bye(ok: true, via: "hotspot")
        let s = try XCTUnwrap(events.sessionEnded())
        XCTAssertTrue(s.ok)
        XCTAssertEqual(s.via, "hotspot")
        XCTAssertEqual(restoredEvent(), true)
        XCTAssertEqual(radio.calls, ["join Phone-1234", "disassociate"])
        XCTAssertEqual(radio.ip, "10.1.2.3")
        _ = link
    }

    func testOldPhoneIsNotOfferedTheHotspot() throws {
        let (p, _, _) = try pairedPhone()
        let a = try sendWithCaps(p, files([10]), caps: nil)
        XCTAssertNil(a["hotspot"])
        try p.sendEncrypted(["t": "hotspot", "ssid": "Phone-1234", "psk": psk])
        let r = try p.receiveEncrypted()
        XCTAssertEqual(r["t"] as? String, "hotspot_error")
        XCTAssertEqual(r["error"] as? String, "unsupported")
        XCTAssertTrue(radio.calls.isEmpty)
    }

    func testBadCredentialsAreRefused() throws {
        let (p, _, _) = try pairedPhone()
        _ = try sendWithCaps(p, files([10]))
        try p.sendEncrypted(["t": "hotspot", "ssid": "Phone-1234", "psk": "short"])
        let r = try p.receiveEncrypted()
        XCTAssertEqual(r["error"] as? String, "bad_request")
        XCTAssertTrue(radio.calls.isEmpty)
    }

    func testJoinFailureIsReportedAndUndone() throws {
        radio.joinError = .joinFailed("associate: test")
        let (p, _, _) = try pairedPhone()
        _ = try sendWithCaps(p, files([10]))
        try p.sendEncrypted(["t": "hotspot", "ssid": "Phone-1234", "psk": psk])
        let r = try p.receiveEncrypted(timeout: 5)
        XCTAssertEqual(r["t"] as? String, "hotspot_error")
        XCTAssertEqual(r["error"] as? String, "join_failed")
        XCTAssertEqual(restoredEvent(), true)
        XCTAssertTrue(radio.calls.contains("disassociate"))
        try p.bye(ok: false, via: nil, error: "hotspot_failed")
        XCTAssertNotNil(events.sessionEnded())
    }

    func testBluetoothDropWhileOnTheHotspotRestores() throws {
        let (p, link, _) = try pairedPhone()
        _ = try sendWithCaps(p, files([10]))
        try p.sendEncrypted(["t": "hotspot", "ssid": "Phone-1234", "psk": psk])
        XCTAssertEqual(try p.receiveEncrypted()["t"] as? String, "hotspot_ready")
        link.disconnect()
        XCTAssertNotNil(events.sessionEnded())
        XCTAssertEqual(restoredEvent(), true)
        XCTAssertEqual(radio.ip, "10.1.2.3")
    }

    func testAppQuitWhileOnTheHotspotRestores() throws {
        let (p, _, _) = try pairedPhone()
        _ = try sendWithCaps(p, files([10]))
        try p.sendEncrypted(["t": "hotspot", "ssid": "Phone-1234", "psk": psk])
        XCTAssertEqual(try p.receiveEncrypted()["t"] as? String, "hotspot_ready")
        engine.endActiveSession(reason: "Mac app quit")
        XCTAssertTrue(joiner.waitUntilIdle(timeout: 5))
        XCTAssertEqual(radio.calls.last, "disassociate")
        XCTAssertEqual(radio.ip, "10.1.2.3")
    }

    func testIdleTimeoutAfterJoiningRestores() throws {
        let (p, _, _) = try pairedPhone()
        _ = try sendWithCaps(p, files([10]))
        try p.sendEncrypted(["t": "hotspot", "ssid": "Phone-1234", "psk": psk])
        XCTAssertEqual(try p.receiveEncrypted()["t"] as? String, "hotspot_ready")
        // The phone goes silent: the 5 s idle timeout ends the session.
        let s = try XCTUnwrap(events.sessionEnded(10))
        XCTAssertFalse(s.ok)
        XCTAssertEqual(restoredEvent(), true)
    }

    func testPasswordIsRedactedInMessageSummaries() {
        XCTAssertFalse(logSummary(["t": "hotspot", "ssid": "x", "psk": psk]).contains(psk))
    }
}
