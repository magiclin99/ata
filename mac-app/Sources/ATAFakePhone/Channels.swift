import Foundation
import ATACore

/// The phone's view of the message channel to the Mac (one whole message per call).
public protocol PhoneChannel: AnyObject {
    func send(_ message: Data) throws
    /// Throws `SocketError.timeout` or `SocketError.closed`.
    func receive(timeout: TimeInterval) throws -> Data
    /// The phone drops the connection (BLE disconnect).
    func disconnect()
}

/// Connects to the Mac app's debug loopback signaling port (`LoopbackSignalServer` framing).
public final class LoopbackChannel: PhoneChannel {
    private let sock: TCPSocket

    public init(port: UInt16, host: String = "127.0.0.1") throws {
        sock = try TCPSocket.connect(ip: host, port: port, timeout: 3)
    }

    public func send(_ message: Data) throws { try sock.writeAll(TCPFrame.frame(message)) }

    public func receive(timeout: TimeInterval) throws -> Data {
        let n = TCPFrame.length(of: try sock.readExact(4, timeout: timeout))
        return try sock.readExact(n, timeout: timeout)
    }

    public func disconnect() { sock.shutdown(); sock.close() }
}

/// In-process pipe: the Mac side is a `PhoneLink` given to the engine, the phone side is a `PhoneChannel`.
/// Messages are passed through `Fragmenter`/`Reassembler` with a small MTU so the BLE framing is exercised too.
public final class InMemoryLink: PhoneLink, PhoneChannel {
    private let engine: ReceiverEngine
    private let cond = NSCondition()
    private var inbox: [Data] = []
    private var macClosed = false
    private var phoneClosed = false
    private let mtuPayload: Int
    private var reassembler = Reassembler()
    public private(set) var closedByMac = false
    public let id: Int
    nonisolated(unsafe) private static var counter = 0

    public init(engine: ReceiverEngine, fragmentSize: Int = 182) {
        self.engine = engine
        mtuPayload = fragmentSize
        Self.counter += 1
        id = Self.counter
    }

    /// Tells the engine a phone has subscribed (the engine replies with hello).
    public func open() { engine.linkOpened(self) }

    // MARK: PhoneLink (Mac → phone)
    public var linkDescription: String { "mem[\(id)]" }

    public func sendMessage(_ data: Data) {
        cond.lock(); defer { cond.unlock() }
        guard !phoneClosed else { return }
        // Fragment and reassemble as BLE would.
        var r = Reassembler()
        var out: Data?
        for f in Fragmenter.fragment(data, maxFragment: mtuPayload) { out = try! r.feed(f) }
        inbox.append(out!)
        cond.broadcast()
    }

    public func close() {
        cond.lock(); defer { cond.unlock() }
        macClosed = true
        closedByMac = true
        cond.broadcast()
    }

    /// The Mac closes a link right *after* sending its last message (e.g. auth_fail), on its own queue, so a test
    /// that has just received that message must wait for the close instead of reading `closedByMac` at once.
    public func waitClosedByMac(timeout: TimeInterval = 2) -> Bool {
        cond.lock(); defer { cond.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !closedByMac { if !cond.wait(until: deadline) { return closedByMac } }
        return true
    }

    // MARK: PhoneChannel (phone → Mac)
    public func send(_ message: Data) throws {
        cond.lock()
        let closed = phoneClosed
        cond.unlock()
        if closed { throw SocketError.closed }
        for f in Fragmenter.fragment(message, maxFragment: mtuPayload) {
            if let m = try reassembler.feed(f) { engine.linkReceived(self, m) }
        }
    }

    public func receive(timeout: TimeInterval) throws -> Data {
        cond.lock(); defer { cond.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while inbox.isEmpty {
            if macClosed { throw SocketError.closed }
            if !cond.wait(until: deadline) { throw SocketError.timeout }
        }
        return inbox.removeFirst()
    }

    /// The phone disconnects (like a BLE drop).
    public func disconnect() {
        cond.lock()
        let already = phoneClosed
        phoneClosed = true
        cond.unlock()
        if !already { engine.linkClosed(self) }
    }
}
