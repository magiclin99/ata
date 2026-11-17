import XCTest
@testable import ATACore

final class TransferErrorKindTests: XCTestCase {
    func testNoDirectPath() {
        // What the Mac's WebRTC receiver reports when the phone and the Mac cannot reach each other
        // (seen on real devices: tablet on guest Wi-Fi, Mac on office Wi-Fi, same NAT without hairpinning).
        XCTAssertEqual(TransferErrorKind.classify("WebRTC transfer failed: ICE failed"), .noPath)
        XCTAssertEqual(TransferErrorKind.classify("WebRTC transfer failed: data channel did not open within 20 s"), .noPath)
        XCTAssertEqual(TransferErrorKind.classify("no_path"), .noPath, "phone's bye error")
    }

    func testExistingCasesUnchanged() {
        XCTAssertEqual(TransferErrorKind.classify("cancelled"), .cancelled)
        XCTAssertEqual(TransferErrorKind.classify("phone disconnected"), .phoneStopped)
        XCTAssertEqual(TransferErrorKind.classify("phone ended the session before the transfer finished"), .phoneStopped)
        XCTAssertEqual(TransferErrorKind.classify("device removed"), .deviceRemoved)
        XCTAssertEqual(TransferErrorKind.classify("timed out (no activity for 30 s)"), .timedOut)
        XCTAssertEqual(TransferErrorKind.classify("LAN transfer failed: connection reset"), .other)
        XCTAssertEqual(TransferErrorKind.classify("phone reported failure"), .other)
    }

    func testCandidateTypesCarryNoAddresses() {
        let sdp = """
        v=0
        a=candidate:1 1 udp 2122260223 192.0.2.10 52923 typ host generation 0
        a=candidate:2 1 udp 1686052607 198.51.100.7 52923 typ srflx raddr 192.0.2.10 rport 52923
        """
        let types = RTCSupport.candidateTypes(inSDP: sdp)
        XCTAssertEqual(types, ["host udp", "srflx udp"])
        XCTAssertFalse(types.joined().contains("192.0.2"))
    }
}
