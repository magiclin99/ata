import Foundation

/// Read-only look at the macOS application firewall (ATA never changes its settings).
enum Firewall {
    /// True when the application firewall is on. Reads the system setting; falls back to `socketfilterfw`, which
    /// reports the state without administrator rights.
    static func isEnabled() -> Bool {
        if let d = NSDictionary(contentsOfFile: "/Library/Preferences/com.apple.alf.plist"),
           let st = d["globalstate"] as? Int { return st > 0 }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/libexec/ApplicationFirewall/socketfilterfw")
        p.arguments = ["--getglobalstate"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return s.contains("enabled")
    }

    /// True when the firewall already has an "allow" rule for this app (so there's no question to bring forward).
    static func isAllowed(_ appPath: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/libexec/ApplicationFirewall/socketfilterfw")
        p.arguments = ["--getappblocked", appPath]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return s.contains("permitted")
    }
}
