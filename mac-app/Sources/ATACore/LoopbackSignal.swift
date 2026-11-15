import Foundation

#if ATA_DEBUG_HOOKS

/// Debug-only stand-in for BLE so the whole session can be driven without a phone (fake phone CLI, tests).
/// Listens on 127.0.0.1 only. Each TCP connection is one `PhoneLink`; each message — exactly the bytes a BLE
/// link would reassemble — is framed as 4-byte big-endian length ‖ message. The engine treats it like BLE.
public final class LoopbackSignalServer {
    public static let maxMessage = 1 << 20
    private let listener = TCPListener(name: "signal")
    private weak var engine: ReceiverEngine?

    public init(engine: ReceiverEngine) { self.engine = engine }

    public var port: UInt16 { listener.port }

    public func start(port: UInt16) throws {
        try listener.start(port: port, loopbackOnly: true) { [weak self] sock in
            guard let self, let engine = self.engine else { sock.close(); return }
            let link = SocketLink(sock: sock)
            let t = Thread {
                engine.linkOpened(link)
                while true {
                    do {
                        let n = TCPFrame.length(of: try sock.readExact(4, timeout: 3600))
                        guard n <= Self.maxMessage else { Log.ble("\(link.linkDescription) message too large"); break }
                        let m = try sock.readExact(n, timeout: 60)
                        engine.linkReceived(link, m)
                    } catch {
                        break
                    }
                }
                sock.close()
                engine.linkClosed(link)
            }
            t.name = "ata.signal.conn"
            t.start()
        }
        Log.info("DEBUG loopback signaling on 127.0.0.1:\(listener.port)")
    }

    public func stop() { listener.stop() }
}

final class SocketLink: PhoneLink {
    let sock: TCPSocket
    private let lock = NSLock()
    init(sock: TCPSocket) { self.sock = sock }
    var linkDescription: String { "loop[\(sock.peer)]" }

    func sendMessage(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        try? sock.writeAll(TCPFrame.frame(data))
    }

    func close() {
        // Let the last message (auth_fail) reach the peer before shutting down.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { [sock] in sock.shutdown() }
    }
}
#endif
