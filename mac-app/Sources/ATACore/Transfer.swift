import Foundation

/// Events a file channel (LAN TCP or WebRTC) reports to the engine. Called from the channel's own thread/queue.
struct TransferCallbacks {
    var activity: () -> Void
    var progress: (_ fileName: String, _ sessionBytes: Int64) -> Void
    var fileSaved: (ReceivedFile) -> Void
    /// The phone sent 0x05. `saved` / `failed` are per-file counts for the whole stream.
    var finished: (_ via: String, _ saved: [ReceivedFile], _ failed: Int) -> Void
    /// The claimed channel died (I/O error, protocol error, decrypt failure, timeout, peer closed early).
    var failed: (_ via: String, _ error: String) -> Void
}

/// Only one channel may carry the files of a session: whichever starts first claims it.
final class TransferClaim {
    private let lock = NSLock()
    private var owner: String?
    func tryClaim(_ via: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if owner == nil { owner = via; return true }
        return owner == via
    }
    var current: String? { lock.lock(); defer { lock.unlock() }; return owner }
}

/// SPEC §7a. Listens on 0.0.0.0:<ephemeral>; the first connection that presents the right 16-byte sid carries the
/// encrypted record stream. Connections with a wrong sid are closed and the listener keeps waiting.
final class TCPFileReceiver {
    static let sidTimeout: TimeInterval = 5

    private let sid: Data
    private let kFile: Data
    private let saveDir: URL
    private let idleTimeout: TimeInterval
    private let claim: TransferClaim
    private let cb: TransferCallbacks
    private let listener = TCPListener(name: "file")
    private let lock = NSLock()
    private var cancelled = false
    private var sockets: [TCPSocket] = []
    private var connCounter = 0

    init(sid: Data, kFile: Data, saveDir: URL, idleTimeout: TimeInterval, claim: TransferClaim, callbacks: TransferCallbacks) {
        self.sid = sid; self.kFile = kFile; self.saveDir = saveDir
        self.idleTimeout = idleTimeout; self.claim = claim; self.cb = callbacks
    }

    var port: UInt16 { listener.port }

    /// True once any inbound TCP connection reached the listener (even one with a wrong sid). Stays readable after
    /// `cancel()`. If the phone fell back to WebRTC and this is still false, nothing on the LAN got through to us.
    var sawConnection: Bool { lock.lock(); defer { lock.unlock() }; return connCounter > 0 }

    func start() throws {
        try listener.start(port: 0, loopbackOnly: false) { [weak self] sock in
            guard let self else { sock.close(); return }
            let t = Thread { self.serve(sock) }
            t.name = "ata.file.conn"
            t.start()
        }
        Log.tcp("file listener on 0.0.0.0:\(listener.port)", public: true)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let socks = sockets
        lock.unlock()
        listener.stop()
        socks.forEach { $0.shutdown() }
    }

    private func register(_ s: TCPSocket) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if cancelled { return false }
        sockets.append(s)
        return true
    }

    private func serve(_ sock: TCPSocket) {
        lock.lock(); connCounter += 1; let id = connCounter; lock.unlock()
        defer { sock.close(); Log.tcp("#\(id) closed") }
        guard register(sock) else { return }
        Log.tcp("#\(id) connection from \(sock.peer)")
        let got: Data
        do { got = try sock.readExact(16, timeout: Self.sidTimeout) } catch {
            Log.tcp("#\(id) no sid: \(error)"); return
        }
        guard ATACrypto.constantTimeEqual(got, sid) else { Log.tcp("#\(id) sid mismatch; closing"); return }
        guard claim.tryClaim("lan") else { Log.tcp("#\(id) sid ok but the transfer is already running on \(claim.current ?? "?"); closing"); return }
        Log.tcp("#\(id) sid ok; receiving records", public: true)
        listener.stop()   // one data connection per session
        cb.activity()

        let rx = RecordStreamReceiver(saveDir: saveDir, maxDataRecord: TCPFrame.maxDataPlaintext)
        rx.onProgress = cb.progress
        rx.onFileSaved = cb.fileSaved
        var inC = CounterCipher(key: kFile, prefix: CounterCipher.tcpP2MPrefix)
        var outC = CounterCipher(key: kFile, prefix: CounterCipher.tcpM2PPrefix)
        do {
            while !rx.finished {
                let n = TCPFrame.length(of: try sock.readExact(4, timeout: idleTimeout))
                try TCPFrame.checkLength(n)
                let sealed = try sock.readExact(n, timeout: idleTimeout)
                let pt = try inC.open(sealed)
                let rec = try Record.decode(pt)
                cb.activity()
                if let reply = try rx.handle(rec) {
                    try sock.writeAll(TCPFrame.frame(outC.seal(reply.encoded)))
                    Log.tcp("#\(id) -> 0x04 \(String(data: reply.body, encoding: .utf8) ?? "")")
                }
            }
            Log.tcp("#\(id) 0x05 received; stream complete", public: true)
            cb.finished("lan", rx.saved, rx.failedCount)
        } catch {
            rx.abort()
            let isCancelled: Bool = { lock.lock(); defer { lock.unlock() }; return cancelled }()
            let why = isCancelled ? "cancelled" : "\(error)"
            Log.tcp("#\(id) stream failed: \(why)")
            if !isCancelled { cb.failed("lan", why) }
        }
    }
}
