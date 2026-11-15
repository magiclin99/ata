import Foundation

/// Timestamped log lines to stdout and (optionally, SPEC §9 `--log-file`) to a file.
/// Never pass key material or the pairing URI to these functions.
public enum Log {
    private static let lock = NSLock()
    private static var fileHandle: FileHandle?
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

    public static func log(_ tag: String, _ msg: String) {
        lock.lock(); defer { lock.unlock() }
        let line = "\(fmt.string(from: Date())) [\(tag)] \(msg)\n"
        let d = Data(line.utf8)
        if echoToStdout { FileHandle.standardOutput.write(d) }
        if let h = fileHandle { try? h.write(contentsOf: d) }
    }

    public static func ble(_ m: String) { log("BLE", m) }
    public static func msg(_ m: String) { log("MSG", m) }
    public static func auth(_ m: String) { log("AUTH", m) }
    public static func tcp(_ m: String) { log("TCP", m) }
    public static func rtc(_ m: String) { log("RTC", m) }
    public static func file(_ m: String) { log("FILE", m) }
    public static func session(_ m: String) { log("SESSION", m) }
    public static func pair(_ m: String) { log("PAIR", m) }
    public static func info(_ m: String) { log("INFO", m) }
    public static func err(_ m: String) { log("ERR", m) }
}

/// Short, secret-free rendering of a protocol JSON message for logs (SDP bodies are summarised).
public func logSummary(_ obj: [String: Any]) -> String {
    var o = obj
    if let sdp = o["sdp"] as? String { o["sdp"] = "<\(sdp.utf8.count) B sdp>" }
    if o["mac"] is String { o["mac"] = "<mac>" }
    return jsonString(o)
}

public func jsonString(_ obj: Any) -> String {
    guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]),
          let s = String(data: d, encoding: .utf8) else { return "<unencodable>" }
    return s
}
