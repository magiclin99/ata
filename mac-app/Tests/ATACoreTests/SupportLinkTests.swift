import XCTest
@testable import ATACore

final class SupportLinkTests: XCTestCase {
    func testEmptyOrMissingHidesTheEntry() {
        XCTAssertNil(SupportLink.url(from: nil))
        XCTAssertNil(SupportLink.url(from: ""))
        XCTAssertNil(SupportLink.url(from: "   \n"))
        XCTAssertNil(SupportLink.url(from: 42), "non-string plist value")
    }

    func testInvalidHidesTheEntry() {
        for v in ["http://recur.tw/ata", "ftp://example.com", "javascript:alert(1)", "recur.tw/ata", "https://",
                  "https:///path", "https://user:pw@example.com/", "https://exa mple.com", "not a url", "mailto:a@b.c"] {
            XCTAssertNil(SupportLink.url(from: v), v)
        }
    }

    func testValidHttpsShowsTheEntry() {
        XCTAssertEqual(SupportLink.url(from: "https://recur.tw/ata")?.absoluteString, "https://recur.tw/ata")
        XCTAssertEqual(SupportLink.url(from: "  https://example.com/support?x=1  ")?.absoluteString, "https://example.com/support?x=1")
        XCTAssertEqual(SupportLink.url(from: "HTTPS://Example.com")?.host, "Example.com")
    }

    func testShippedInfoPlistHasTheEntryOff() throws {
        let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Resources/Info.plist").standardizedFileURL
        let d = try XCTUnwrap(NSDictionary(contentsOf: plist))
        XCTAssertEqual(d[SupportLink.infoPlistKey] as? String, "", "ATASupportURL must stay empty until support is enabled")
        XCTAssertNil(SupportLink.url(from: d[SupportLink.infoPlistKey]))
    }
}
