import CoreWLAN
import Foundation

/// `WiFiRadio` on the Mac's built-in Wi-Fi interface. Never reads the current network's name (that needs Location
/// permission on macOS 14+); "connected" is judged by the interface's IPv4 address.
public final class CoreWLANRadio: WiFiRadio {
    public init() {}

    private var iface: CWInterface? { CWWiFiClient.shared().interface() }

    public var hasWiFi: Bool { iface?.interfaceName != nil }

    public func isPowered() -> Bool { iface?.powerOn() ?? false }

    public func setPower(_ on: Bool) throws {
        guard let i = iface else { throw HotspotError.unsupported }
        try i.setPower(on)
    }

    public func ipv4() -> String? {
        guard let name = iface?.interfaceName else { return nil }
        return lanIPv4Addresses().first { $0.name == name }?.ip
    }

    /// Joins by name through `networksetup` (see `joinByName`). CoreWLAN's own join needs a scan result, and without
    /// Location permission macOS blanks the name in an app's scan results, which airportd then cannot join (-3900,
    /// seen on a real device). networksetup scans by itself, so a separate CoreWLAN scan would only add ~6 s.
    public func join(ssid: String, password: String) throws {
        guard let name = iface?.interfaceName else { throw HotspotError.unsupported }
        try joinByName(interface: name, ssid: ssid, password: password)
    }

    public func disassociate() { iface?.disassociate() }

    public func forget(ssid: String) -> Bool {
        guard let name = iface?.interfaceName else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = ["-removepreferredwirelessnetwork", name, ssid]
        let out = Pipe()
        p.standardOutput = out; p.standardError = out; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return p.terminationStatus == 0 && text.contains("Removed")
    }

    /// Joins by name with the system's `networksetup` tool: CoreWLAN can only join a scan result, and without Location
    /// permission macOS blanks the name in scan results, which it then cannot join. The password goes in on stdin
    /// (networksetup reads it there when given "-"), so it never appears in the process list; it is never logged.
    private func joinByName(interface: String, ssid: String, password: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = ["-setairportnetwork", interface, ssid, "-"]
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out; p.standardError = out; p.standardInput = inp
        do { try p.run() } catch { throw HotspotError.joinFailed("networksetup: could not run") }
        inp.fileHandleForWriting.write(Data((password + "\n").utf8))
        try? inp.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        // networksetup exits 0 even when it fails; it prints why (e.g. "Could not find network …",
        // "Failed to join network … Error: -3905"). Only the error number is kept.
        if p.terminationStatus != 0 || text.contains("Could not") || text.contains("Failed") || text.contains("Error") {
            if text.contains("Could not find") { throw HotspotError.notFound }
            let code = text.range(of: #"-?\d{3,}"#, options: .regularExpression).map { String(text[$0]) } ?? "status \(p.terminationStatus)"
            throw HotspotError.joinFailed("networksetup \(code)")
        }
    }
}
