import Foundation
import CryptoKit
import Darwin

/// Turns a sender-supplied name into a safe single path component (SPEC §7: last path segment only).
public func sanitizeFileName(_ raw: String) -> String {
    var base = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
    base = String(base.unicodeScalars.map { s -> Character in
        (s.value < 0x20 || s.value == 0x7F || s == ":") ? "_" : Character(s)
    })
    base = base.trimmingCharacters(in: .whitespaces)
    while base.hasPrefix(".") { base.removeFirst() }
    if base.isEmpty { base = "file" }
    // Keep within the 255-byte APFS limit, leaving room for " (9999)".
    while base.utf8.count > 240 {
        let ext = (base as NSString).pathExtension
        var stem = (base as NSString).deletingPathExtension
        if stem.isEmpty { base.removeLast(); continue }
        stem.removeLast()
        base = ext.isEmpty ? stem : "\(stem).\(ext)"
    }
    return base
}

/// One file being written: a hidden temp file in the destination folder, hashed as it is written, renamed to a
/// unique final name only when the sha256 matches, deleted otherwise.
final class IncomingFile {
    let displayName: String
    let declaredSize: Int64
    let tempURL: URL
    private var handle: FileHandle?
    private var hasher = SHA256()
    private(set) var received: Int64 = 0

    init(dir: URL, name: String, size: Int64) throws {
        displayName = sanitizeFileName(name)
        declaredSize = size
        tempURL = dir.appendingPathComponent(".ata-\(Hex.encode(randomBytes(8))).part")
        let fd = open(tempURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else { throw ReceiveError.io("cannot create temp file in \(dir.path): \(String(cString: strerror(errno)))") }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    func write(_ d: Data) throws {
        guard let handle else { throw ReceiveError.io("file closed") }
        hasher.update(data: d)
        do { try handle.write(contentsOf: d) } catch { throw ReceiveError.io("write failed: \(error.localizedDescription)") }
        received += Int64(d.count)
    }

    /// Closes the temp file and returns the lowercase hex sha256 of what was written.
    func finishHash() -> String {
        try? handle?.close(); handle = nil
        return Hex.encode(Data(hasher.finalize()))
    }

    /// Renames to `dir/<name>`, or `<stem> (n).<ext>` if taken, never overwriting (renamex_np RENAME_EXCL).
    func commit(into dir: URL) throws -> URL {
        let ext = (displayName as NSString).pathExtension
        let stem = (displayName as NSString).deletingPathExtension
        for i in 0..<10000 {
            let n = i == 0 ? displayName : (ext.isEmpty ? "\(stem) (\(i))" : "\(stem) (\(i)).\(ext)")
            let dst = dir.appendingPathComponent(n)
            if renamex_np(tempURL.path, dst.path, UInt32(RENAME_EXCL)) == 0 { return dst }
            if errno != EEXIST { throw ReceiveError.io("rename failed: \(String(cString: strerror(errno)))") }
        }
        throw ReceiveError.io("no free file name for \(displayName)")
    }

    func discard() {
        try? handle?.close(); handle = nil
        try? FileManager.default.removeItem(at: tempURL)
    }
}

public enum ReceiveError: Error, CustomStringConvertible {
    case protocolError(String)
    case io(String)
    public var description: String {
        switch self {
        case .protocolError(let s): return "protocol error: \(s)"
        case .io(let s): return s
        }
    }
}

public struct ReceivedFile {
    public let url: URL
    public let size: Int64
}

/// Transport-independent receiver for the SPEC §7 record stream (shared by LAN TCP and WebRTC).
/// Not thread-safe: feed it from one serial context. A thrown error is fatal for the stream; call `abort()`.
public final class RecordStreamReceiver {
    public let saveDir: URL
    public let maxDataRecord: Int
    private var current: IncomingFile?
    public private(set) var saved: [ReceivedFile] = []
    public private(set) var failedCount = 0
    public private(set) var finished = false
    public private(set) var bytesReceived: Int64 = 0

    /// (current file display name, bytes received in this session so far)
    public var onProgress: ((String, Int64) -> Void)?
    public var onFileSaved: ((ReceivedFile) -> Void)?

    public init(saveDir: URL, maxDataRecord: Int) {
        self.saveDir = saveDir
        self.maxDataRecord = maxDataRecord
    }

    public var currentFileName: String? { current?.displayName }

    /// Returns the reply record to send back (only for 0x03), or nil.
    public func handle(_ r: Record) throws -> Record? {
        guard !finished else { throw ReceiveError.protocolError("record after 0x05") }
        switch r.type {
        case .fileStart:
            guard current == nil else { throw ReceiveError.protocolError("0x01 while a file is open") }
            guard let j = r.jsonBody(), let name = j["name"] as? String,
                  let size = jsonInt64(j["size"]), size >= 0 else {
                throw ReceiveError.protocolError("bad 0x01 body")
            }
            try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
            let f = try IncomingFile(dir: saveDir, name: name, size: size)
            current = f
            Log.file("start \"\(f.displayName)\" size=\(size) -> \(f.tempURL.lastPathComponent)")
            onProgress?(f.displayName, bytesReceived)
            return nil

        case .data:
            guard let f = current else { throw ReceiveError.protocolError("0x02 without an open file") }
            guard r.body.count <= maxDataRecord else {
                throw ReceiveError.protocolError("0x02 body \(r.body.count) B exceeds \(maxDataRecord) B")
            }
            guard f.received + Int64(r.body.count) <= f.declaredSize else {
                throw ReceiveError.protocolError("more data than declared size \(f.declaredSize)")
            }
            try f.write(r.body)
            bytesReceived += Int64(r.body.count)
            onProgress?(f.displayName, bytesReceived)
            return nil

        case .fileEnd:
            guard let f = current else { throw ReceiveError.protocolError("0x03 without an open file") }
            current = nil
            let got = f.finishHash()
            let expect = (r.jsonBody()?["sha256"] as? String)?.lowercased()
            if f.received != f.declaredSize {
                f.discard(); failedCount += 1
                Log.file("\"\(f.displayName)\" size mismatch: got \(f.received) of \(f.declaredSize) B; deleted")
                return .fileResult(ok: false, error: "size mismatch: got \(f.received) of \(f.declaredSize) bytes")
            }
            guard let expect, ATACrypto.constantTimeEqual(Data(expect.utf8), Data(got.utf8)) else {
                f.discard(); failedCount += 1
                Log.file("\"\(f.displayName)\" sha256 mismatch (expected \(expect ?? "nil"), got \(got)); deleted")
                return .fileResult(ok: false, error: "sha256 mismatch")
            }
            do {
                let url = try f.commit(into: saveDir)
                let rf = ReceivedFile(url: url, size: f.received)
                saved.append(rf)
                Log.file("saved \"\(url.lastPathComponent)\" (\(f.received) B, sha256 ok)")
                onFileSaved?(rf)
                return .fileResult(ok: true)
            } catch {
                f.discard(); failedCount += 1
                Log.file("\"\(f.displayName)\" commit failed: \(error)")
                return .fileResult(ok: false, error: "\(error)")
            }

        case .allDone:
            guard current == nil else { throw ReceiveError.protocolError("0x05 while a file is open") }
            finished = true
            Log.file("all done: \(saved.count) saved, \(failedCount) failed, \(bytesReceived) B")
            return nil

        case .fileResult:
            throw ReceiveError.protocolError("unexpected 0x04 from phone")
        }
    }

    /// Deletes any partially written file. Saved files are kept.
    public func abort() {
        if let f = current {
            Log.file("aborting \"\(f.displayName)\" at \(f.received)/\(f.declaredSize) B; temp file deleted")
            f.discard()
            current = nil
        }
    }
}
