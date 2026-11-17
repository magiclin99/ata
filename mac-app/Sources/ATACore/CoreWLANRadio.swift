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

    public func join(ssid: String, password: String) throws {
        guard let i = iface else { throw HotspotError.unsupported }
        let found: Set<CWNetwork>
        do { found = try i.scanForNetworks(withName: ssid) } catch { throw HotspotError.joinFailed("scan: \((error as NSError).code)") }
        // The scan is filtered by name. Without Location permission the results may carry no name at all, so an
        // exact match is preferred but any result of this filtered scan is accepted.
        let candidates = found.filter { $0.ssid == ssid }
        guard let net = (candidates.isEmpty ? found : candidates).max(by: { $0.rssiValue < $1.rssiValue }) else {
            throw HotspotError.notFound
        }
        do { try i.associate(to: net, password: password) } catch {
            // NSError code only: the description could echo network details.
            throw HotspotError.joinFailed("associate: \((error as NSError).domain) \((error as NSError).code)")
        }
    }

    public func disassociate() { iface?.disassociate() }
}
