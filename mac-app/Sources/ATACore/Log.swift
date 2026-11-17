import Foundation
import os

/// Timestamped log lines to stdout, to the unified log (subsystem `io.github.magiclin99.ata.mac`, one category per
/// tag; read with `/usr/bin/log show --predicate 'subsystem == "io.github.magiclin99.ata.mac"'`) and (optionally,
/// SPEC §9 `--log-file`) to a file. A Mac app started from Finder has its stdout on /dev/null, so the unified log
/// is the only place a release build's lines can be read.
///
/// Never pass key material or the pairing URI to these functions. In the unified log a line is redacted
/// (`<private>`) unless the call passes `public: true`; pass it only for lines with nothing personal in them
/// (state names, durations, counts, the transport chosen) — never names, file names, paths, addresses or IDs.
public enum Log {
    public static let subsystem = "io.github.magiclin99.ata.mac"
    private static let lock = NSLock()
    private static var fileHandle: FileHandle?
    nonisolated(unsafe) private static var loggers: [String: Logger] = [:]
    nonisolated(unsafe) public static var echoToStdout = true
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Appends to `url` (creating it). Lines are flushed as they are written.
    public static func setFile(_ url: URL?) {
        lock.lock(); defer { lock.unlock() }
        try? fileHandle?.close()
        fileHandle = nil
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            _ = try? h.seekToEnd()
            fileHandle = h
        }
    }

    public static func log(_ tag: String, _ msg: String, public isPublic: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        let line = "\(fmt.string(from: Date())) [\(tag)] \(msg)\n"
        let d = Data(line.utf8)
        if echoToStdout { FileHandle.standardOutput.write(d) }
        if let h = fileHandle { try? h.write(contentsOf: d) }
        let logger = loggers[tag] ?? Logger(subsystem: subsystem, category: tag)
        loggers[tag] = logger
        // Default level (not info/debug) so the lines are kept on disk and `log show` finds them without flags.
        let level: OSLogType = tag == "ERR" ? .error : .default
        if isPublic { logger.log(level: level, "\(msg, privacy: .public)") }
        else { logger.log(level: level, "\(msg)") }
    }

    public static func ble(_ m: String, public p: Bool = false) { log("BLE", m, public: p) }
    public static func msg(_ m: String, public p: Bool = false) { log("MSG", m, public: p) }
    public static func auth(_ m: String, public p: Bool = false) { log("AUTH", m, public: p) }
    public static func tcp(_ m: String, public p: Bool = false) { log("TCP", m, public: p) }
    public static func rtc(_ m: String, public p: Bool = false) { log("RTC", m, public: p) }
    public static func file(_ m: String, public p: Bool = false) { log("FILE", m, public: p) }
    public static func session(_ m: String, public p: Bool = false) { log("SESSION", m, public: p) }
    public static func pair(_ m: String, public p: Bool = false) { log("PAIR", m, public: p) }
    public static func info(_ m: String, public p: Bool = false) { log("INFO", m, public: p) }
    public static func err(_ m: String, public p: Bool = false) { log("ERR", m, public: p) }
}

/// Short, secret-free rendering of a protocol JSON message for logs (SDP bodies are summarised).
public func logSummary(_ obj: [String: Any]) -> String {
    var o = obj
    if let sdp = o["sdp"] as? String { o["sdp"] = "<\(sdp.utf8.count) B sdp>" }
    if o["mac"] is String { o["mac"] = "<mac>" }
    if o["psk"] != nil { o["psk"] = "<redacted>" }   // the phone's hotspot password (SPEC §7c)
    return jsonString(o)
}

public func jsonString(_ obj: Any) -> String {
    guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]),
          let s = String(data: d, encoding: .utf8) else { return "<unencodable>" }
    return s
}
