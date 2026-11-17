import Foundation

/// The few Wi-Fi operations the temporary-hotspot path needs (SPEC §7c). CoreWLAN on a real Mac, a fake in tests.
/// Every call may block; `HotspotJoiner` only calls them on its own queue.
public protocol WiFiRadio: AnyObject {
    /// False when this Mac has no Wi-Fi interface.
    var hasWiFi: Bool { get }
    func isPowered() -> Bool
    func setPower(_ on: Bool) throws
    /// IPv4 address of the Wi-Fi interface (not link-local), or nil. "Connected" means this is non-nil: reading the
    /// network name would need Location permission, so it is never used.
    func ipv4() -> String?
    /// One scan for `ssid` and one association attempt. Throws `HotspotError.notFound` if the scan did not see it.
    func join(ssid: String, password: String) throws
    func disassociate()
}

public enum HotspotError: Error, Equatable, CustomStringConvertible {
    case unsupported, notFound, joinFailed(String), noAddress, cancelled
    /// The `hotspot_error` wire value (SPEC §6).
    public var wire: String {
        switch self {
        case .unsupported: return "unsupported"
        case .notFound: return "not_found"
        case .joinFailed: return "join_failed"
        case .noAddress: return "no_address"
        case .cancelled: return "cancelled"
        }
    }
    public var description: String {
        if case .joinFailed(let why) = self { return "join_failed (\(why))" }
        return wire
    }
}

/// What the Wi-Fi looked like before ATA touched it; written to disk so a crash can still be undone at next launch.
public struct WiFiRestorePoint: Codable, Equatable {
    public var powered: Bool
    public var connected: Bool
    /// The address the Mac got on the phone's hotspot (set once joined), to recognise "still on the hotspot" later.
    public var hotspotIP: String?
    /// An association attempt was made (a scan that found nothing changes nothing, so it needs no undo).
    public var associationTouched = false
    public init(powered: Bool, connected: Bool, hotspotIP: String? = nil) {
        self.powered = powered; self.connected = connected; self.hotspotIP = hotspotIP
    }
}

public struct HotspotTimings {
    /// The phone sends the name as soon as Android reports the hotspot started; its first beacons can come a moment
    /// later, and a scan that misses them costs a whole `retryEvery`.
    public var firstScanDelay: TimeInterval = 2
    public var scanFor: TimeInterval = 30
    /// macOS gives an app that is not frontmost at most one live scan per 10 s; an earlier request only gets the
    /// cached results of the last scan (airportd: "requested a live scan less than 10 seconds after previous request").
    public var retryEvery: TimeInterval = 10.5
    public var addressWait: TimeInterval = 15
    public var rejoinWait: TimeInterval = 10
    public var powerCycleWait: TimeInterval = 20
    public var poll: TimeInterval = 0.25
    public init() {}
}

/// Joins a phone's temporary hotspot and always puts the Mac's Wi-Fi back the way it was (SPEC §7c).
/// All radio work runs on one serial queue, so a restore requested during a join runs right after that join gives up.
public final class HotspotJoiner {
    private let radio: WiFiRadio
    private let markerURL: URL?
    private let timings: HotspotTimings
    private let q = DispatchQueue(label: "ata.hotspot")
    private let lock = NSLock()
    private var cancelled = false
    /// Set while ATA has changed the Wi-Fi and not yet restored it (only touched on `q`).
    private var restorePoint: WiFiRestorePoint?

    public init(radio: WiFiRadio, markerURL: URL?, timings: HotspotTimings = HotspotTimings()) {
        self.radio = radio; self.markerURL = markerURL; self.timings = timings
    }

    public var available: Bool { radio.hasWiFi }

    /// Blocks the caller until all queued radio work (a join, a restore) is done.
    public func waitUntilIdle() { q.sync {} }

    /// Like `waitUntilIdle` but gives up after `timeout`; false if work was still running.
    public func waitUntilIdle(timeout: TimeInterval) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        q.async { sem.signal() }
        return sem.wait(timeout: .now() + timeout) == .success
    }

    /// Joins `ssid`; `done` gets the Mac's IPv4 address on the hotspot. Called back on the joiner's queue.
    /// The password is passed straight to the radio and never logged.
    public func join(ssid: String, password: String, done: @escaping (Result<String, HotspotError>) -> Void) {
        lock.lock(); cancelled = false; lock.unlock()
        q.async { [self] in done(joinNow(ssid: ssid, password: password)) }
    }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    private func joinNow(ssid: String, password: String) -> Result<String, HotspotError> {
        guard radio.hasWiFi else { return .failure(.unsupported) }
        let before = WiFiRestorePoint(powered: radio.isPowered(), connected: radio.ipv4() != nil)
        let oldIP = radio.ipv4()
        restorePoint = before
        saveMarker(before)
        Log.log("WIFI", "joining the phone's hotspot (Wi-Fi was \(before.powered ? "on" : "off"), \(before.connected ? "connected" : "not connected"))", public: true)
        let t0 = Date()
        if !before.powered {
            do { try radio.setPower(true) } catch { return .failure(.joinFailed("power on: \(error)")) }
        }
        sleepUnlessCancelled(timings.firstScanDelay)
        let scanDeadline = Date().addingTimeInterval(timings.scanFor)
        var lastError: HotspotError = .notFound
        var joined = false
        while !joined {
            if isCancelled { return .failure(.cancelled) }
            do {
                try radio.join(ssid: ssid, password: password)
                joined = true
            } catch let e as HotspotError {
                lastError = e
            } catch {
                lastError = .joinFailed("\(error)")
            }
            if lastError != .notFound || joined, restorePoint?.associationTouched == false {
                restorePoint?.associationTouched = true
                saveMarker(restorePoint!)
            }
            if joined { break }
            if Date().addingTimeInterval(timings.retryEvery) > scanDeadline { return .failure(lastError) }
            Log.log("WIFI", "hotspot not joined yet (\(lastError.wire)); retrying", public: true)
            sleepUnlessCancelled(timings.retryEvery)
        }
        let addrDeadline = Date().addingTimeInterval(timings.addressWait)
        while Date() < addrDeadline {
            if isCancelled { return .failure(.cancelled) }
            if let ip = radio.ipv4(), ip != oldIP {
                restorePoint?.hotspotIP = ip
                saveMarker(restorePoint!)
                Log.log("WIFI", "on the phone's hotspot after \(Int(Date().timeIntervalSince(t0) * 1000)) ms", public: true)
                return .success(ip)
            }
            Thread.sleep(forTimeInterval: timings.poll)
        }
        return .failure(.noAddress)
    }

    private func sleepUnlessCancelled(_ t: TimeInterval) {
        let end = Date().addingTimeInterval(t)
        while Date() < end && !isCancelled { Thread.sleep(forTimeInterval: min(timings.poll, t)) }
    }

    /// Puts the Wi-Fi back if ATA changed it; no-op otherwise. Stops a join in progress first.
    /// `done(true)` means restored (or nothing to do); false means it could not confirm the Mac is back online.
    public func restore(done: ((Bool) -> Void)? = nil) {
        lock.lock(); cancelled = true; lock.unlock()
        q.async { [self] in
            guard let before = restorePoint else { done?(true); return }
            let ok = restoreNow(before)
            restorePoint = nil
            removeMarker()
            done?(ok)
        }
    }

    private func restoreNow(_ before: WiFiRestorePoint) -> Bool {
        let t0 = Date()
        if before.powered && !before.associationTouched {
            Log.log("WIFI", "Wi-Fi was not changed; nothing to restore", public: true)
            return true
        }
        radio.disassociate()
        var ok = true
        if !before.powered {
            do { try radio.setPower(false) } catch { ok = false }
        } else if before.connected {
            ok = waitForNetwork(away: before.hotspotIP, timings.rejoinWait)
            if !ok {
                Log.log("WIFI", "no automatic rejoin within \(Int(timings.rejoinWait)) s; turning Wi-Fi off and on", public: true)
                try? radio.setPower(false)
                try? radio.setPower(true)
                ok = waitForNetwork(away: before.hotspotIP, timings.powerCycleWait)
            }
        }
        Log.log("WIFI", "Wi-Fi restore \(ok ? "done" : "NOT confirmed") after \(Int(Date().timeIntervalSince(t0) * 1000)) ms", public: true)
        return ok
    }

    /// True once the Wi-Fi has an address that is not the hotspot's.
    private func waitForNetwork(away hotspotIP: String?, _ t: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(t)
        repeat {
            if let ip = radio.ipv4(), ip != hotspotIP, !sameSubnet24(ip, hotspotIP) { return true }
            Thread.sleep(forTimeInterval: timings.poll)
        } while Date() < end
        return false
    }

    /// At launch: undoes a change left behind by a crash (SPEC §7c). Only acts if the Wi-Fi still looks like it is on
    /// the phone's hotspot (or was switched on by ATA and is not connected); always removes the marker.
    public func recoverAfterCrash(done: ((Bool) -> Void)? = nil) {
        q.async { [self] in
            guard let url = markerURL, let data = try? Data(contentsOf: url),
                  let before = try? JSONDecoder().decode(WiFiRestorePoint.self, from: data) else { done?(true); return }
            let ip = radio.ipv4()
            let stillOnHotspot = ip != nil && before.hotspotIP != nil && sameSubnet24(ip!, before.hotspotIP)
            let leftPoweredOn = !before.powered && radio.isPowered() && ip == nil
            Log.log("WIFI", "found a Wi-Fi restore note from an earlier run; \(stillOnHotspot || leftPoweredOn ? "restoring" : "nothing to undo")", public: true)
            var ok = true
            if stillOnHotspot || leftPoweredOn { ok = restoreNow(before) }
            removeMarker()
            done?(ok)
        }
    }

    private func saveMarker(_ p: WiFiRestorePoint) {
        guard let url = markerURL, let d = try? JSONEncoder().encode(p) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: url, options: .atomic)
    }

    private func removeMarker() {
        if let url = markerURL { try? FileManager.default.removeItem(at: url) }
    }
}

/// Same /24 (hotspots hand out /24s; good enough to recognise "still on the phone's network").
func sameSubnet24(_ a: String, _ b: String?) -> Bool {
    guard let b else { return false }
    let pa = a.split(separator: "."), pb = b.split(separator: ".")
    return pa.count == 4 && pb.count == 4 && pa[0..<3] == pb[0..<3]
}
