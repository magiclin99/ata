import Foundation

/// A message channel to one phone: BLE (fragments over GATT), the debug loopback socket, or an in-memory test pipe.
/// `sendMessage` takes one whole message (plaintext JSON before auth_ok, ciphertext‖tag after).
public protocol PhoneLink: AnyObject {
    var linkDescription: String { get }
    func sendMessage(_ data: Data)
    /// Stop serving this link. BLE cannot force a disconnect from the peripheral side, so a BLE link just stops
    /// sending and ignores further writes; socket links are closed.
    func close()
}

public struct SessionSummary {
    public let phoneName: String
    /// Files announced in `send` (0 if the phone never sent one, e.g. a pairing-only session).
    public let announcedFiles: Int
    public let saved: [URL]
    public let failedFiles: Int
    public let ok: Bool
    public let via: String?
    public let error: String?
    /// The Mac offered LAN TCP (`accept` had a port and addresses), not a single inbound connection arrived, and the
    /// files came over WebRTC instead. Typical cause: the macOS application firewall dropping the phone's connection.
    /// (Also true if the phone simply wasn't on the same network, so the app pairs it with the firewall state.)
    public var lanUnreached: Bool = false
}

public enum EngineEvent {
    case pairingStarted(uri: String, expiresAt: Date)
    case pairingExpired
    case paired(PairedDevice)
    case pairingFailed(reason: String)
    case devicesChanged
    case sessionStarted(phoneName: String)
    case transferAccepted(phoneName: String, files: Int, totalBytes: Int64)
    case progress(fileName: String, received: Int64, total: Int64)
    case fileSaved(URL)
    case sessionEnded(SessionSummary)
}

public struct EngineConfig {
    public var macId: Data
    public var macName: String
    public var saveDir: URL
    public var handshakeTimeout: TimeInterval = 15
    /// No BLE message and no file bytes for this long → the session is torn down.
    public var idleTimeout: TimeInterval = 30
    /// After 0x05, how long to wait for the phone's `bye` before ending the session anyway.
    public var finishGrace: TimeInterval = 10
    public var lanAddresses: () -> [String] = { lanIPv4Addresses().map(\.ip) }

    public init(macId: Data, macName: String, saveDir: URL) {
        self.macId = macId; self.macName = macName; self.saveDir = saveDir
    }
}

/// The receive state machine (SPEC §4–§7). All state lives on `queue`; public methods are thread-safe.
public final class ReceiverEngine {
    public let queue = DispatchQueue(label: "ata.engine")
    /// PairingStore calls (file I/O; historically Keychain prompts) run here, never on `queue`.
    private let keychainQueue = DispatchQueue(label: "ata.keychain", attributes: .concurrent)
    private var config: EngineConfig
    private let store: PairingStore
    /// Invoked on `queue`.
    public var onEvent: ((EngineEvent) -> Void)?

    private final class LinkState {
        let link: PhoneLink
        let nonceM = randomBytes(16)
        let openedAt = Date()
        var session: Session?
        var dead = false
        /// A Keychain read/write for this link's auth is in flight.
        var authPending = false
        init(link: PhoneLink) { self.link = link }
    }

    private final class Session {
        let link: LinkState
        let phoneId: String
        var phoneName: String
        let keys: ATACrypto.SessionKeys
        var rxCipher: CounterCipher
        var txCipher: CounterCipher
        var accepted = false
        var totalBytes: Int64 = 0
        var fileCount = 0
        let claim = TransferClaim()
        var tcp: TCPFileReceiver?
        /// The session's LAN listener, kept after `tcp` is cancelled so its `sawConnection` can still be read.
        var lanListener: TCPFileReceiver?
        var rtc: RTCFileReceiver?
        var lastActivity = Date()
        var lastProgressEvent = Date.distantPast
        var saved: [URL] = []
        var failedFiles = 0
        var finishedVia: String?
        var finishedAt: Date?
        /// `bye` arrived while the file channel was still delivering the tail of the stream.
        var pendingBye: (at: Date, ok: Bool, error: String?)?
        var ended = false

        init(link: LinkState, phoneId: String, phoneName: String, keys: ATACrypto.SessionKeys) {
            self.link = link; self.phoneId = phoneId; self.phoneName = phoneName; self.keys = keys
            rxCipher = CounterCipher(key: keys.kP2M, prefix: CounterCipher.bleP2MPrefix)
            txCipher = CounterCipher(key: keys.kM2P, prefix: CounterCipher.bleM2PPrefix)
        }
    }

    private var links: [ObjectIdentifier: LinkState] = [:]
    private var active: Session?
    private var offer: PairingOffer?
    private var offerExpiryReported = false
    private var watchdog: DispatchSourceTimer?

    public init(config: EngineConfig, store: PairingStore) {
        self.config = config
        self.store = store
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        watchdog = t
        Log.info("engine: macId=\(Hex.encode(config.macId)) name=\"\(config.macName)\" saveDir=\(config.saveDir.path)")
    }

    deinit { watchdog?.cancel() }

    private func emit(_ e: EngineEvent) { onEvent?(e) }

    // MARK: public API

    public var macId: Data { config.macId }
    public var macName: String { queue.sync { config.macName } }

    public func setSaveDir(_ url: URL) {
        queue.async { [self] in config.saveDir = url; Log.info("save folder: \(url.path)") }
    }

    public var saveDir: URL { queue.sync { config.saveDir } }

    public var isBusy: Bool { queue.sync { active != nil } }

    /// Starts (or restarts) pairing mode and returns the `ata://pair` URI. Do not log the result.
    public func startPairing(lifetime: TimeInterval = PairingOffer.lifetime) -> (uri: String, expiresAt: Date) {
        queue.sync {
            let o = PairingOffer(lifetime: lifetime)
            offer = o
            offerExpiryReported = false
            let uri = o.uri(macId: config.macId, macName: config.macName)
            Log.pair("pairing mode on; code valid until \(o.expiresAt)")
            emit(.pairingStarted(uri: uri, expiresAt: o.expiresAt))
            return (uri, o.expiresAt)
        }
    }

    public func cancelPairing() {
        queue.async { [self] in
            if offer != nil { Log.pair("pairing mode off", public: true) }
            offer = nil
        }
    }

    /// Attributes only; never needs Keychain approval.
    public func devices() -> [PairedDevice] { store.devices() }

    public func removeDevice(phoneId: String) {
        queue.async { [self] in
            Log.pair("removing pairing for phone \(phoneId)")
            if let s = active, s.phoneId == phoneId { endSession(s, error: "device removed") }
            let store = self.store
            keychainQueue.async { [weak self] in
                store.remove(phoneId: phoneId)
                self?.queue.async { self?.emit(.devicesChanged) }
            }
        }
    }

    // MARK: link events (from transports)

    public func linkOpened(_ link: PhoneLink) {
        queue.async { [self] in
            let st = LinkState(link: link)
            links[ObjectIdentifier(link)] = st
            Log.auth("\(link.linkDescription) opened; sending hello")
            sendPlain(st, ["t": "hello", "v": 2, "id": Hex.encode(config.macId), "n": B64.encode(st.nonceM)])
        }
    }

    public func linkReceived(_ link: PhoneLink, _ data: Data) {
        queue.async { [self] in
            guard let st = links[ObjectIdentifier(link)], !st.dead else {
                Log.msg("\(link.linkDescription): \(data.count) B on a closed link, ignored"); return
            }
            if let s = st.session { handleEncrypted(s, data) } else { handleAuth(st, data) }
        }
    }

    public func linkClosed(_ link: PhoneLink) {
        queue.async { [self] in
            guard let st = links.removeValue(forKey: ObjectIdentifier(link)) else { return }
            Log.auth("\(link.linkDescription) disconnected")
            st.dead = true
            if let s = st.session, !s.ended {
                // A session that never asked to send anything (e.g. pairing only) has nothing to lose.
                if s.finishedAt != nil || !s.accepted { endSession(s, error: nil, closeLink: false) }
                else { endSession(s, error: "phone disconnected", closeLink: false) }
            }
        }
    }

    // MARK: handshake (SPEC §4)

    private func sendPlain(_ st: LinkState, _ obj: [String: Any]) {
        Log.msg("-> \(st.link.linkDescription) \(logSummary(obj))")
        st.link.sendMessage(ProtocolJSON.encode(obj))
    }

    private func authFail(_ st: LinkState, _ reason: String) {
        sendPlain(st, ["t": "auth_fail", "reason": reason])
        closeLink(st)
    }

    private func closeLink(_ st: LinkState) {
        st.dead = true
        st.link.close()
    }

    private struct AuthRequest {
        let phoneId: Data
        let phoneHex: String
        let name: String
        let nonceP: Data
        let mac: Data
        let pairing: Bool
    }

    private func handleAuth(_ st: LinkState, _ data: Data) {
        guard let m = ProtocolJSON.decode(data), let t = m["t"] as? String else {
            Log.auth("\(st.link.linkDescription): non-JSON message before auth; closing")
            closeLink(st); return
        }
        Log.msg("<- \(st.link.linkDescription) \(logSummary(m))")
        guard t == "auth" else {
            Log.auth("\(st.link.linkDescription): expected auth, got \(t); closing")
            closeLink(st); return
        }
        guard !st.authPending else { Log.auth("second auth while the first is pending; ignored"); return }
        if let v = m["v"], jsonInt64(v) != 2 { authFail(st, "bad_version"); return }
        let pairing = jsonBool(m["pairing"]) ?? false
        guard let idHex = m["id"] as? String, let phoneId = Hex.decode(idHex), phoneId.count == 16,
              let nP = (m["n"] as? String).flatMap(B64.decode), nP.count == 16,
              let mac = (m["mac"] as? String).flatMap(B64.decode) else {
            Log.auth("malformed auth")
            authFail(st, "bad_version"); return
        }
        let req = AuthRequest(phoneId: phoneId, phoneHex: Hex.encode(phoneId),
                              name: (m["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Android phone",
                              nonceP: nP, mac: mac, pairing: pairing)

        if active != nil {
            Log.auth("phone \(req.phoneHex) rejected: busy with another session")
            authFail(st, "busy"); return
        }

        if pairing {
            guard let o = offer, o.isValid() else {
                Log.auth("pairing auth from \(req.phoneHex) but no valid pairing code")
                emit(.pairingFailed(reason: "pairing_expired"))
                authFail(st, "pairing_expired"); return
            }
            verifyAuth(st, req, k: o.k)
        } else {
            // Keychain reads can block on a user approval prompt; never do them on the engine queue.
            st.authPending = true
            let store = self.store
            keychainQueue.async { [weak self] in
                let k = store.key(for: req.phoneHex)
                self?.queue.async {
                    guard let self else { return }
                    st.authPending = false
                    guard !st.dead else { return }
                    guard let k else {
                        Log.auth("unknown phone \(req.phoneHex)")
                        self.authFail(st, "unknown_device"); return
                    }
                    self.verifyAuth(st, req, k: k)
                }
            }
        }
    }

    private func verifyAuth(_ st: LinkState, _ req: AuthRequest, k: Data) {
        if active != nil {   // someone else won while the key was being read
            authFail(st, "busy"); return
        }
        let expect = ATACrypto.phoneAuthMAC(k: k, macId: config.macId, phoneId: req.phoneId, nonceM: st.nonceM, nonceP: req.nonceP)
        guard ATACrypto.constantTimeEqual(expect, req.mac) else {
            Log.auth("bad mac from \(req.phoneHex) (pairing=\(req.pairing))")
            if req.pairing { emit(.pairingFailed(reason: "bad_mac")) }
            authFail(st, "bad_mac"); return
        }
        if req.pairing {
            // The code is consumed now; the key is stored before auth_ok goes out (SPEC §2).
            guard var o = offer, o.isValid() else { authFail(st, "pairing_expired"); return }
            o.used = true
            offer = o
            st.authPending = true
            let dev = PairedDevice(phoneId: req.phoneHex, name: req.name, pairedAt: Date())
            let store = self.store
            keychainQueue.async { [weak self] in
                var err: Error?
                do { try store.save(dev, key: k) } catch { err = error }
                self?.queue.async {
                    guard let self else { return }
                    st.authPending = false
                    if let err {
                        Log.err("cannot store pairing key: \(err)")
                        self.emit(.pairingFailed(reason: "keychain error"))
                        self.authFail(st, "pairing_expired"); return
                    }
                    Log.pair("paired with \"\(req.name)\" (\(req.phoneHex))")
                    self.emit(.paired(dev))
                    self.emit(.devicesChanged)
                    guard !st.dead else { return }
                    if self.active != nil { self.authFail(st, "busy"); return }
                    self.startSession(st, req, k: k)
                }
            }
        } else {
            let store = self.store
            keychainQueue.async { [weak self] in
                // Keep the stored display name current (attributes only).
                if let d = store.devices().first(where: { $0.phoneId == req.phoneHex }), d.name != req.name {
                    store.rename(phoneId: req.phoneHex, to: req.name)
                    self?.queue.async { self?.emit(.devicesChanged) }
                }
            }
            startSession(st, req, k: k)
        }
    }

    private func startSession(_ st: LinkState, _ req: AuthRequest, k: Data) {
        let keys = ATACrypto.deriveSessionKeys(k: k, nonceM: st.nonceM, nonceP: req.nonceP)
        let s = Session(link: st, phoneId: req.phoneHex, phoneName: req.name, keys: keys)
        st.session = s
        active = s
        let macMac = ATACrypto.macAuthMAC(k: k, macId: config.macId, phoneId: req.phoneId, nonceM: st.nonceM, nonceP: req.nonceP)
        sendPlain(st, ["t": "auth_ok", "name": config.macName, "mac": B64.encode(macMac)])
        Log.session("session started with \"\(req.name)\" (\(req.phoneHex)) pairing=\(req.pairing)")
        emit(.sessionStarted(phoneName: req.name))
    }

    // MARK: encrypted messages (SPEC §5, §6)

    private func sendEncrypted(_ s: Session, _ obj: [String: Any]) {
        guard !s.ended else { return }
        Log.msg("-> \(s.link.link.linkDescription) [enc #\(s.txCipher.counter)] \(logSummary(obj))")
        s.link.link.sendMessage(s.txCipher.seal(ProtocolJSON.encode(obj)))
    }

    private func handleEncrypted(_ s: Session, _ data: Data) {
        guard !s.ended else { return }
        let n = s.rxCipher.counter
        let pt: Data
        do { pt = try s.rxCipher.open(data) } catch {
            Log.auth("decrypt failed on message #\(n): \(error); dropping link")
            endSession(s, error: "BLE message failed to decrypt")
            return
        }
        guard let m = ProtocolJSON.decode(pt), let t = m["t"] as? String else {
            Log.msg("<- [enc #\(n)] not a JSON object with t; ignored"); return
        }
        Log.msg("<- \(s.link.link.linkDescription) [enc #\(n)] \(logSummary(m))")
        s.lastActivity = Date()
        switch t {
        case "send": handleSend(s, m)
        case "rtc_offer": handleRTCOffer(s, m)
        case "bye":
            let ok = jsonBool(m["ok"]) ?? false
            let err = m["error"] as? String
            Log.session("bye ok=\(ok) via=\(m["via"] as? String ?? "null") error=\(err ?? "null")")
            if s.finishedAt != nil { endSession(s, error: nil) }
            else if s.claim.current != nil {
                // The record stream may still be draining (0x05 not processed yet); give it a moment.
                s.pendingBye = (Date(), ok, err)
            } else if !s.accepted && err == nil {
                endSession(s, error: nil)   // e.g. pairing-only session
            } else { endSession(s, error: byeError(ok: ok, err)) }
        default:
            Log.msg("unknown message t=\(t), ignored")
        }
    }

    private func byeError(ok: Bool, _ err: String?) -> String {
        err ?? (ok ? "phone ended the session before the transfer finished" : "phone reported failure")
    }

    private func handleSend(_ s: Session, _ m: [String: Any]) {
        guard !s.accepted else { sendEncrypted(s, ["t": "reject", "reason": "already_accepted"]); return }
        guard let files = m["files"] as? [[String: Any]], !files.isEmpty else {
            sendEncrypted(s, ["t": "reject", "reason": "bad_request"]); return
        }
        var sum: Int64 = 0
        for f in files {
            guard f["name"] is String, let sz = jsonInt64(f["size"]), sz >= 0 else {
                sendEncrypted(s, ["t": "reject", "reason": "bad_request"]); return
            }
            sum += sz
        }
        let total = jsonInt64(m["total"]) ?? sum
        if total != sum { Log.session("send: total \(total) != sum of sizes \(sum); using the sum") }
        let dir = config.saveDir
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
            Log.err("save folder unavailable: \(error)")
            sendEncrypted(s, ["t": "reject", "reason": "save_folder_unavailable"]); return
        }
        if let free = (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage,
           free > 0, free < sum + 64 * 1024 * 1024 {
            Log.session("reject: need \(sum) B, \(free) B free")
            sendEncrypted(s, ["t": "reject", "reason": "no_space"]); return
        }
        s.totalBytes = sum
        s.fileCount = files.count
        s.accepted = true

        let tcp = TCPFileReceiver(sid: s.keys.sid, kFile: s.keys.kFile, saveDir: dir,
                                  idleTimeout: config.idleTimeout, claim: s.claim, callbacks: callbacks(for: s))
        var port = 0
        var lan: [String] = []
        do {
            try tcp.start()
            s.tcp = tcp
            port = Int(tcp.port)
            lan = config.lanAddresses()
            if !lan.isEmpty { s.lanListener = tcp }
        } catch {
            Log.err("TCP listener failed: \(error); phone will have to use WebRTC")
        }
        Log.session("accepting \(files.count) file(s), \(sum) B", public: true)
        emit(.transferAccepted(phoneName: s.phoneName, files: files.count, totalBytes: sum))
        sendEncrypted(s, ["t": "accept", "tcpPort": port, "lan": lan])
    }

    private func handleRTCOffer(_ s: Session, _ m: [String: Any]) {
        guard s.accepted else { sendEncrypted(s, ["t": "rtc_error", "error": "no accepted send"]); return }
        guard let sdp = m["sdp"] as? String, !sdp.isEmpty else { sendEncrypted(s, ["t": "rtc_error", "error": "missing sdp"]); return }
        if let c = s.claim.current { sendEncrypted(s, ["t": "rtc_error", "error": "transfer already running over \(c)"]); return }
        s.rtc?.cancel()
        let r = RTCFileReceiver(saveDir: config.saveDir, claim: s.claim, callbacks: callbacks(for: s))
        s.rtc = r
        r.answer(offer: sdp) { [weak self, weak s] result in
            guard let self else { return }
            self.queue.async {
                guard let s, !s.ended, s.rtc === r else { return }
                s.lastActivity = Date()
                switch result {
                case .success(let answer): self.sendEncrypted(s, ["t": "rtc_answer", "sdp": answer])
                case .failure(let e):
                    Log.rtc("answer failed: \(e)")
                    self.sendEncrypted(s, ["t": "rtc_error", "error": "\(e)"])
                }
            }
        }
    }

    // MARK: file channel callbacks

    private func callbacks(for s: Session) -> TransferCallbacks {
        TransferCallbacks(
            activity: { [weak self, weak s] in
                self?.queue.async { s?.lastActivity = Date() }
            },
            progress: { [weak self, weak s] name, bytes in
                guard let self else { return }
                self.queue.async {
                    guard let s, !s.ended else { return }
                    s.lastActivity = Date()
                    let now = Date()
                    if now.timeIntervalSince(s.lastProgressEvent) >= 0.1 || bytes >= s.totalBytes {
                        s.lastProgressEvent = now
                        self.emit(.progress(fileName: name, received: bytes, total: s.totalBytes))
                    }
                }
            },
            fileSaved: { [weak self, weak s] f in
                self?.queue.async {
                    guard let self, let s else { return }
                    s.saved.append(f.url)
                    self.emit(.fileSaved(f.url))
                }
            },
            finished: { [weak self, weak s] via, saved, failed in
                self?.queue.async {
                    guard let s, !s.ended else { return }
                    s.finishedVia = via
                    s.failedFiles = failed
                    s.finishedAt = Date()
                    Log.session("transfer over \(via) finished: \(saved.count) saved, \(failed) failed", public: true)
                    if s.pendingBye != nil { self?.endSession(s, error: nil) }
                }
            },
            failed: { [weak self, weak s] via, error in
                self?.queue.async {
                    guard let self, let s, !s.ended else { return }
                    self.endSession(s, error: "\(via == "lan" ? "LAN" : "WebRTC") transfer failed: \(error)")
                }
            })
    }

    // MARK: teardown and timeouts

    private func endSession(_ s: Session, error: String?, closeLink close: Bool = true) {
        guard !s.ended else { return }
        s.ended = true
        s.tcp?.cancel(); s.tcp = nil
        s.rtc?.cancel(); s.rtc = nil
        if active === s { active = nil }
        if close { closeLink(s.link) }
        // Success = the file stream finished, or the session ended cleanly without a transfer (pairing only).
        let ok = error == nil && (s.finishedAt != nil || !s.accepted)
        let kind = s.accepted ? "" : " (no transfer)"
        Log.session("session with \"\(s.phoneName)\" ended\(kind): ok=\(ok) via=\(s.finishedVia ?? "none") saved=\(s.saved.count) failed=\(s.failedFiles)\(error.map { " error=\($0)" } ?? "")")
        // The line above names the phone and may quote file names, so it is redacted in the unified log; this one
        // carries only the outcome.
        Log.session("session ended\(kind): ok=\(ok) via=\(s.finishedVia ?? "none") saved=\(s.saved.count) failed=\(s.failedFiles)"
                    + (error.map { " error kind=\(TransferErrorKind.classify($0))" } ?? ""), public: true)
        var summary = SessionSummary(phoneName: s.phoneName, announcedFiles: s.fileCount, saved: s.saved, failedFiles: s.failedFiles, ok: ok,
                                     via: s.finishedVia, error: error)
        if s.finishedVia == "rtc", let l = s.lanListener, !l.sawConnection {
            summary.lanUnreached = true
            Log.session("LAN was offered but no TCP connection ever arrived; the files came over WebRTC (firewall?)", public: true)
        }
        emit(.sessionEnded(summary))
    }

    private func tick() {
        let now = Date()
        for st in links.values where st.session == nil && !st.dead && !st.authPending && now.timeIntervalSince(st.openedAt) > config.handshakeTimeout {
            Log.auth("\(st.link.linkDescription): no auth within \(Int(config.handshakeTimeout)) s; closing")
            closeLink(st)
        }
        if let s = active {
            if let b = s.pendingBye, s.finishedAt == nil, now.timeIntervalSince(b.at) > 3 {
                endSession(s, error: byeError(ok: b.ok, b.error))
            } else if let f = s.finishedAt {
                if now.timeIntervalSince(f) > config.finishGrace {
                    Log.session("no bye within \(Int(config.finishGrace)) s after 0x05; ending session", public: true)
                    endSession(s, error: nil)
                }
            } else if now.timeIntervalSince(s.lastActivity) > config.idleTimeout {
                endSession(s, error: "timed out (no activity for \(Int(config.idleTimeout)) s)")
            }
        }
        if let o = offer, !o.used, now >= o.expiresAt, !offerExpiryReported {
            offerExpiryReported = true
            Log.pair("pairing code expired", public: true)
            emit(.pairingExpired)
        }
    }
}
