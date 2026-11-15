import XCTest
@testable import ATACore
@testable import ATAFakePhone

/// Opt-in tests against a running debug ATA.app (skipped unless ATA_LIVE_SIGNAL_PORT is set):
///   ATA_LIVE_SIGNAL_PORT=47990 ATA_LIVE_STATE=<ata-fakephone state file> swift test --filter LiveAppTests
/// The state file must come from a successful `ata-fakephone --uri-file …` pairing with that app.
final class LiveAppTests: XCTestCase {
    struct State: Codable { var phoneId: String; var name: String; var macId: String?; var k: String? }

    func phone() throws -> FakePhone {
        guard let p = ProcessInfo.processInfo.environment["ATA_LIVE_SIGNAL_PORT"].flatMap(UInt16.init),
              let sp = ProcessInfo.processInfo.environment["ATA_LIVE_STATE"] else {
            throw XCTSkip("ATA_LIVE_SIGNAL_PORT / ATA_LIVE_STATE not set")
        }
        let st = try JSONDecoder().decode(State.self, from: Data(contentsOf: URL(fileURLWithPath: sp)))
        let ph = FakePhone(channel: try LoopbackChannel(port: p), phoneId: Hex.decode(st.phoneId)!, name: st.name)
        ph.log = { print("[PHONE] \($0)") }
        try ph.awaitHello()
        guard case .ok = try ph.authenticate(k: Base64URL.decode(st.k!)!, pairing: false) else {
            throw FakePhoneError("live app rejected auth")
        }
        return ph
    }

    func testLiveWebRTC() throws {
        let ph = try phone()
        let fs = [OutgoingFile(name: "live-rtc-1.bin", data: randomBytes(3 << 20)), OutgoingFile(name: "live-rtc-2.bin", data: randomBytes(100_000))]
        let a = try ph.requestSend(fs)
        XCTAssertEqual(a["t"] as? String, "accept")
        let out = try ph.sendFilesRTC(fs)
        XCTAssertEqual(out.map(\.ok), [true, true])
        try ph.bye(ok: true, via: "rtc")
        Thread.sleep(forTimeInterval: 0.3)
        ph.channel.disconnect()
    }
}
