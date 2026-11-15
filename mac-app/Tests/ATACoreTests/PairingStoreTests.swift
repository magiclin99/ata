import XCTest
@testable import ATACore

final class FilePairingStoreTests: XCTestCase {
    var dir: URL!
    var url: URL { dir.appendingPathComponent("io.example.ata/pairings.json") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ata-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func mode(_ u: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func device(_ name: String, at t: TimeInterval = 1_700_000_000) -> PairedDevice {
        PairedDevice(phoneId: Hex.encode(randomBytes(16)), name: name, pairedAt: Date(timeIntervalSince1970: t))
    }

    func testRoundTripAcrossInstancesWithPrivatePermissions() throws {
        let s = FilePairingStore(url: url)
        XCTAssertFalse(s.fileExists)
        XCTAssertEqual(s.devices(), [])
        let a = device("Pixel A", at: 1_700_000_000), b = device("Pixel B", at: 1_700_000_100)
        let ka = randomBytes(32), kb = randomBytes(32)
        try s.save(b, key: kb)
        try s.save(a, key: ka)

        XCTAssertEqual(try mode(url.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try mode(url), 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["pairings.json"], "no temp files left behind")

        let s2 = FilePairingStore(url: url)
        XCTAssertEqual(s2.devices().map(\.name), ["Pixel A", "Pixel B"], "sorted by pairing date")
        XCTAssertEqual(s2.key(for: a.phoneId), ka)
        XCTAssertEqual(s2.key(for: b.phoneId.uppercased()), kb)

        s2.rename(phoneId: a.phoneId, to: "Renamed")
        s2.remove(phoneId: b.phoneId)
        let s3 = FilePairingStore(url: url)
        XCTAssertEqual(s3.devices().map(\.name), ["Renamed"])
        XCTAssertNil(s3.key(for: b.phoneId))
        XCTAssertEqual(try mode(url), 0o600)
    }

    func testRepairReplacesKey() throws {
        let s = FilePairingStore(url: url)
        let d = device("Pixel")
        try s.save(d, key: randomBytes(32))
        let k2 = randomBytes(32)
        try s.save(d, key: k2)
        XCTAssertEqual(FilePairingStore(url: url).key(for: d.phoneId), k2)
        XCTAssertEqual(FilePairingStore(url: url).devices().count, 1)
    }

    func testUnreadableFileIsMovedAsideNotOverwritten() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let s = FilePairingStore(url: url)
        XCTAssertEqual(s.devices(), [])
        let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertTrue(names.contains { $0.hasPrefix("pairings.json.unreadable-") }, "\(names)")
    }

    func testImportAddsOnlyNewValidPairingsAndCreatesFile() throws {
        let s = FilePairingStore(url: url)
        let existing = device("Existing")
        let kExisting = randomBytes(32)
        try s.save(existing, key: kExisting)
        let new = device("Imported")
        let added = s.importPairings([(existing, randomBytes(32)), (new, randomBytes(32)), (device("Bad key"), randomBytes(5))])
        XCTAssertEqual(added, 1)
        let r = FilePairingStore(url: url)
        XCTAssertEqual(Set(r.devices().map(\.name)), ["Existing", "Imported"])
        XCTAssertEqual(r.key(for: existing.phoneId), kExisting, "import never overwrites a newer pairing")

        // Nothing to import still writes the file, so the one-time import is not attempted again.
        let url2 = dir.appendingPathComponent("other/pairings.json")
        let empty = FilePairingStore(url: url2)
        XCTAssertEqual(empty.importPairings([]), 0)
        XCTAssertTrue(empty.fileExists)
    }

    func testDocumentedFileFormat() throws {
        // Guards the format documented on FilePairingStore (version 1, base64 keys).
        // Fixed key whose base64 contains both "/" and "+" (a random key did only some of the time, which made
        // this test flaky while the encoder escaped "/" as "\/").
        let s = FilePairingStore(url: url)
        // 0xFB 0xEF 0xFF encodes to "++//" (sextets 62 62 63 63).
        let k = Data([0xFB, 0xEF, 0xFF] + (3..<32).map { UInt8($0 * 37 & 0xFF) })
        let b64 = k.base64EncodedString()
        XCTAssertTrue(b64.contains("/") && b64.contains("+"), b64)
        let dev = device("Pixel")
        try s.save(dev, key: k)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\"key\" : \"\(b64)\""), text)
        XCTAssertFalse(text.contains("\\/"), "slashes are not escaped")
        XCTAssertEqual(FilePairingStore(url: url).key(for: dev.phoneId), k)
        XCTAssertTrue(text.contains("\"version\" : 1"))
    }
}
