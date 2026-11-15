import Foundation
import CoreBluetooth

/// SPEC §3: GATT peripheral. RX (write with response) carries phone → Mac fragments, TX (notify) Mac → phone.
/// Each subscribed central is one `PhoneLink`; the engine sends `hello` as soon as the central subscribes to TX.
/// All CoreBluetooth work runs on `queue`.
public final class BLEPeripheral: NSObject, CBPeripheralManagerDelegate {
    public static let serviceUUID = CBUUID(string: "8E7F0101-3A5B-4C6D-9E1F-A7A0C0FFEE01")
    public static let rxUUID = CBUUID(string: "8E7F0102-3A5B-4C6D-9E1F-A7A0C0FFEE01")
    public static let txUUID = CBUUID(string: "8E7F0103-3A5B-4C6D-9E1F-A7A0C0FFEE01")

    public enum State: Equatable { case starting, poweredOn, poweredOff, unauthorized, unsupported, other(String) }

    let queue = DispatchQueue(label: "ata.ble")
    private let localName: String
    private weak var engine: ReceiverEngine?
    private var pm: CBPeripheralManager?
    private let rx = CBMutableCharacteristic(type: BLEPeripheral.rxUUID, properties: [.write], value: nil, permissions: [.writeable])
    private let tx = CBMutableCharacteristic(type: BLEPeripheral.txUUID, properties: [.notify], value: nil, permissions: [.readable])
    private var links: [UUID: BLELink] = [:]

    private struct Pending { let link: BLELink; let data: Data }
    /// One FIFO for all outgoing fragments; a message is queued whole before the next, so per-central order holds.
    private var outQueue: [Pending] = []
    private var waitingForReady = false

    /// Called on `queue`.
    public var onStateChange: ((State) -> Void)?

    /// SPEC §3: advertised local name = "ATA-" + first 8 hex chars of macId (e.g. "ATA-a0a1a2a3").
    public static func localName(macId: Data) -> String { "ATA-" + Hex.encode(macId).prefix(8) }

    public init(engine: ReceiverEngine) {
        self.engine = engine
        self.localName = Self.localName(macId: engine.macId)
        super.init()
    }

    public func start() {
        queue.async { [self] in
            Log.ble("starting peripheral manager (authorization=\(Self.authString(CBManager.authorization)))")
            pm = CBPeripheralManager(delegate: self, queue: queue)
        }
    }

    public func stop() {
        queue.sync {
            if pm?.isAdvertising == true { pm?.stopAdvertising(); Log.ble("advertising stopped") }
            pm?.removeAllServices()
        }
    }

    static func authString(_ a: CBManagerAuthorization) -> String {
        switch a {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .allowedAlways: return "allowedAlways"
        @unknown default: return "unknown(\(a.rawValue))"
        }
    }

    // MARK: sending (on queue)

    fileprivate func send(_ message: Data, on link: BLELink) {
        queue.async { [self] in
            guard !link.closed, links[link.central.identifier] === link else { return }
            let maxLen = min(512, max(20, link.central.maximumUpdateValueLength))
            let frags = Fragmenter.fragment(message, maxFragment: maxLen)
            Log.ble("\(link.linkDescription) -> \(message.count) B in \(frags.count) fragment(s) (max \(maxLen))")
            for f in frags { outQueue.append(Pending(link: link, data: f)) }
            pump()
        }
    }

    private func pump() {
        guard let pm else { return }
        while let f = outQueue.first {
            // Fragments queued before close() still go out (e.g. auth_fail).
            guard links[f.link.central.identifier] === f.link else { outQueue.removeFirst(); continue }
            if pm.updateValue(f.data, for: tx, onSubscribedCentrals: [f.link.central]) {
                outQueue.removeFirst()
            } else {
                if !waitingForReady { Log.ble("transmit queue full; waiting (\(outQueue.count) fragment(s) pending)") }
                waitingForReady = true
                return
            }
        }
    }

    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        waitingForReady = false
        pump()
    }

    // MARK: delegate

    public func peripheralManagerDidUpdateState(_ p: CBPeripheralManager) {
        let st: State
        switch p.state {
        case .poweredOn: st = .poweredOn
        case .poweredOff: st = .poweredOff
        case .unauthorized: st = .unauthorized
        case .unsupported: st = .unsupported
        case .resetting: st = .other("resetting")
        case .unknown: st = .other("unknown")
        @unknown default: st = .other("?")
        }
        Log.ble("state = \(st) (authorization=\(Self.authString(CBManager.authorization)))")
        if p.state == .poweredOn {
            let svc = CBMutableService(type: Self.serviceUUID, primary: true)
            svc.characteristics = [rx, tx]
            p.removeAllServices()
            p.add(svc)
        } else {
            // All links are gone.
            let gone = Array(links.values)
            links.removeAll(); outQueue.removeAll()
            for l in gone { l.closed = true; engine?.linkClosed(l) }
            if p.state == .unauthorized {
                Log.err("Bluetooth not authorized: allow ATA in System Settings > Privacy & Security > Bluetooth")
            }
        }
        onStateChange?(st)
    }

    public func peripheralManager(_ p: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error { Log.err("add service failed: \(error)"); return }
        let adv: [String: Any] = [CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID], CBAdvertisementDataLocalNameKey: localName]
        // Legacy advertising PDU is 31 bytes: flags (3) + 128-bit service UUID (18) + local name (2 + n).
        let advBytes = 3 + 18 + 2 + localName.utf8.count
        Log.ble("service \(service.uuid.uuidString) added; startAdvertising serviceUUIDs=[\(Self.serviceUUID.uuidString)] localName=\"\(localName)\" "
                + "(\(advBytes) B incl. flags; \(advBytes > 31 ? "exceeds the 31 B advertising PDU, so CoreBluetooth carries the name in the scan response" : "fits in the advertising PDU"))")
        p.startAdvertising(adv)
    }

    public func peripheralManagerDidStartAdvertising(_ p: CBPeripheralManager, error: Error?) {
        if let error { Log.err("advertising failed: \(error)"); return }
        Log.ble("advertising service \(Self.serviceUUID.uuidString) with local name \"\(localName)\" (isAdvertising=\(p.isAdvertising))")
    }

    public func peripheralManager(_ p: CBPeripheralManager, central: CBCentral, didSubscribeTo c: CBCharacteristic) {
        guard c.uuid == Self.txUUID else { return }
        if let old = links[central.identifier] {
            // Re-subscribe without an unsubscribe: treat as a new connection.
            old.closed = true
            engine?.linkClosed(old)
        }
        let l = BLELink(central: central, peripheral: self)
        links[central.identifier] = l
        Log.ble("\(l.linkDescription) subscribed to TX (maxUpdateValueLength=\(central.maximumUpdateValueLength))")
        engine?.linkOpened(l)
    }

    public func peripheralManager(_ p: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom c: CBCharacteristic) {
        guard c.uuid == Self.txUUID, let l = links.removeValue(forKey: central.identifier) else { return }
        outQueue.removeAll { $0.link === l }
        l.closed = true
        Log.ble("\(l.linkDescription) unsubscribed (disconnected)")
        engine?.linkClosed(l)
    }

    public func peripheralManager(_ p: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        if let bad = requests.first(where: { $0.characteristic.uuid != Self.rxUUID || $0.offset != 0 }) {
            p.respond(to: first, withResult: bad.offset != 0 ? .invalidOffset : .writeNotPermitted)
            return
        }
        p.respond(to: first, withResult: .success)
        for r in requests {
            guard let v = r.value else { continue }
            guard let l = links[r.central.identifier] else {
                Log.ble("write from central[\(r.central.identifier.uuidString.prefix(8))] that has not subscribed to TX; ignored")
                continue
            }
            if l.closed { continue }
            do {
                if let msg = try l.reassembler.feed(v) {
                    Log.ble("\(l.linkDescription) <- message \(msg.count) B")
                    engine?.linkReceived(l, msg)
                }
            } catch {
                Log.ble("\(l.linkDescription) bad fragment: \(error); closing link")
                l.closed = true
                engine?.linkClosed(l)
                links[r.central.identifier] = nil
            }
        }
    }
}

final class BLELink: PhoneLink {
    let central: CBCentral
    weak var peripheral: BLEPeripheral?
    var reassembler = Reassembler()
    var closed = false   // touched only on the BLE queue

    init(central: CBCentral, peripheral: BLEPeripheral) {
        self.central = central
        self.peripheral = peripheral
    }

    var linkDescription: String { "ble[\(central.identifier.uuidString.prefix(8))]" }

    func sendMessage(_ data: Data) { peripheral?.send(data, on: self) }

    /// CoreBluetooth has no API for a peripheral to disconnect a central. Messages already queued (e.g. auth_fail)
    /// are still delivered; after that, writes are ignored and nothing more is sent.
    func close() {
        guard let p = peripheral else { return }
        p.queue.async { [self] in
            closed = true
            Log.ble("\(linkDescription) closed by engine (central must disconnect itself)")
        }
    }
}
