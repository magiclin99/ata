import Foundation

// MARK: - BLE fragments (SPEC §3)

/// Fragment = 1 flag byte (0x00 more follow, 0x01 last) ‖ payload. A message always yields at least one fragment.
public enum Fragmenter {
    public static let more: UInt8 = 0x00
    public static let last: UInt8 = 0x01

    /// `maxFragment` is the whole fragment length including the flag byte (≤ min(ATT MTU − 3, 512)).
    public static func fragment(_ message: Data, maxFragment: Int) -> [Data] {
        let chunk = max(1, min(512, maxFragment) - 1)
        var out: [Data] = []
        var off = message.startIndex
        repeat {
            let end = min(off + chunk, message.endIndex)
            var f = Data([end == message.endIndex ? last : more])
            f.append(message[off..<end])
            out.append(f)
            off = end
        } while off < message.endIndex
        return out
    }
}

public enum FramingError: Error, CustomStringConvertible {
    case emptyFragment, badFlag(UInt8), messageTooLarge(Int), recordTooLarge(Int), recordTooShort(Int), badRecordType(UInt8)
    public var description: String {
        switch self {
        case .emptyFragment: return "empty fragment"
        case .badFlag(let f): return String(format: "bad fragment flag 0x%02x", f)
        case .messageTooLarge(let n): return "message too large (\(n) B)"
        case .recordTooLarge(let n): return "record length \(n) exceeds 1 MiB"
        case .recordTooShort(let n): return "record length \(n) too short"
        case .badRecordType(let t): return String(format: "unknown record type 0x%02x", t)
        }
    }
}

/// Reassembles fragments of one direction into messages.
public struct Reassembler {
    public static let maxMessage = 256 * 1024
    private var buffer = Data()
    public private(set) var fragmentCount = 0

    public init() {}

    /// Returns the complete message on the last fragment, nil while more are expected.
    public mutating func feed(_ fragment: Data) throws -> Data? {
        guard let flag = fragment.first else { throw FramingError.emptyFragment }
        guard flag == Fragmenter.more || flag == Fragmenter.last else { throw FramingError.badFlag(flag) }
        buffer.append(fragment.dropFirst())
        fragmentCount += 1
        guard buffer.count <= Self.maxMessage else { throw FramingError.messageTooLarge(buffer.count) }
        guard flag == Fragmenter.last else { return nil }
        defer { buffer = Data(); fragmentCount = 0 }
        return buffer
    }
}

// MARK: - File records (SPEC §7)

public enum RecordType: UInt8 {
    case fileStart = 0x01
    case data = 0x02
    case fileEnd = 0x03
    case fileResult = 0x04
    case allDone = 0x05
}

public struct Record: Equatable {
    public let type: RecordType
    public let body: Data

    public init(_ type: RecordType, _ body: Data = Data()) { self.type = type; self.body = body }

    public init(_ type: RecordType, json: [String: Any]) {
        self.init(type, try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes]))
    }

    public var encoded: Data { Data([type.rawValue]) + body }

    public static func decode(_ d: Data) throws -> Record {
        guard let t = d.first else { throw FramingError.recordTooShort(0) }
        guard let type = RecordType(rawValue: t) else { throw FramingError.badRecordType(t) }
        return Record(type, Data(d.dropFirst()))
    }

    public func jsonBody() -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    // Convenience constructors (phone side and Mac reply).
    public static func fileStart(name: String, size: Int64) -> Record { Record(.fileStart, json: ["name": name, "size": size]) }
    public static func fileEnd(sha256 hex: String) -> Record { Record(.fileEnd, json: ["sha256": hex]) }
    public static func fileResult(ok: Bool, error: String? = nil) -> Record {
        ok ? Record(.fileResult, json: ["ok": true]) : Record(.fileResult, json: ["ok": false, "error": error ?? "error"])
    }
}

/// SPEC §7a: 4-byte big-endian length N ‖ N bytes (AES-256-GCM(kFile) ciphertext ‖ tag).
public enum TCPFrame {
    public static let maxLength = 1 << 20
    public static let maxDataPlaintext = 64 * 1024

    public static func frame(_ sealed: Data) -> Data {
        var d = Data(capacity: 4 + sealed.count)
        withUnsafeBytes(of: UInt32(sealed.count).bigEndian) { d.append(contentsOf: $0) }
        d.append(sealed)
        return d
    }

    /// Validates a length prefix. A sealed record is at least 1 type byte + 16 tag bytes.
    public static func checkLength(_ n: Int) throws {
        if n > maxLength { throw FramingError.recordTooLarge(n) }
        if n < 17 { throw FramingError.recordTooShort(n) }
    }

    public static func length(of header: Data) -> Int {
        precondition(header.count == 4)
        let b = Array(header)
        return Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
    }
}

// MARK: - Protocol messages

public enum ProtocolJSON {
    public static func encode(_ obj: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])
    }

    public static func decode(_ d: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
}

/// Reads an integer JSON field that may arrive as any JSON number (rejects fractions, bools and strings).
public func jsonInt64(_ v: Any?) -> Int64? {
    guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
    let d = n.doubleValue
    guard d.rounded() == d, abs(d) < 9.0e15 else { return nil }
    return n.int64Value
}

public func jsonBool(_ v: Any?) -> Bool? {
    guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
    return n.boolValue
}
