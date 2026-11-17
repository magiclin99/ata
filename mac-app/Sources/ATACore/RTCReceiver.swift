import Foundation
import WebRTC

/// SPEC §7b shared WebRTC settings.
public enum RTCSupport {
    public static let stunURLs = ["stun:stun.l.google.com:19302", "stun:stun.cloudflare.com:3478"]
    public static let channelLabel = "ata-file"
    public static let maxDataRecord = 16 * 1024
    public static let gatheringTimeout: TimeInterval = 5
    public static let channelOpenTimeout: TimeInterval = 20

    /// One factory per process; RTCInitializeSSL must run first.
    public static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }()

    public static func config() -> RTCConfiguration {
        let c = RTCConfiguration()
        c.iceServers = [RTCIceServer(urlStrings: stunURLs)]   // STUN only. Never add TURN or any relay.
        c.sdpSemantics = .unifiedPlan
        c.continualGatheringPolicy = .gatherOnce
        c.iceTransportPolicy = .all
        c.tcpCandidatePolicy = .disabled
        return c
    }

    public static let noConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

    /// "host udp 192.168.1.5:5000" per a=candidate line.
    public static func candidates(inSDP sdp: String) -> [String] {
        sdp.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard line.hasPrefix("a=candidate:") else { return nil }
            let f = line.split(separator: " ")
            guard f.count >= 8 else { return String(line) }
            return "\(f[7]) \(f[2].lowercased()) \(f[4]):\(f[5])"
        }
    }

    /// Candidate types only ("host udp", "srflx udp"), no addresses: safe for the public unified log.
    public static func candidateTypes(inSDP sdp: String) -> [String] {
        sdp.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard line.hasPrefix("a=candidate:") else { return nil }
            let f = line.split(separator: " ")
            return f.count >= 8 ? "\(f[7]) \(f[2].lowercased())" : "?"
        }
    }

    public static func name(_ s: RTCIceConnectionState) -> String {
        switch s {
        case .new: return "new"; case .checking: return "checking"; case .connected: return "connected"
        case .completed: return "completed"; case .failed: return "failed"; case .disconnected: return "disconnected"
        case .closed: return "closed"; case .count: return "count"
        @unknown default: return "?\(s.rawValue)"
        }
    }

    public static func name(_ s: RTCDataChannelState) -> String {
        switch s {
        case .connecting: return "connecting"; case .open: return "open"; case .closing: return "closing"; case .closed: return "closed"
        @unknown default: return "?\(s.rawValue)"
        }
    }

    /// Waits (≤ timeout) for ICE gathering to complete on a peer connection whose local description is set,
    /// then returns the full local SDP. `gathered` must be wired to the delegate's gathering callback.
    public struct Err: Error, CustomStringConvertible {
        public let description: String
        public init(_ d: String) { description = d }
    }
}

/// Mac side of SPEC §7b: answers the phone's complete offer with a complete answer (non-trickle), then receives the
/// record stream on the `ata-file` data channel the phone opens. Every callback is funnelled onto `q`.
final class RTCFileReceiver: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    private let q = DispatchQueue(label: "ata.rtc.receiver")
    private let saveDir: URL
    private let claim: TransferClaim
    private let cb: TransferCallbacks
    private var pc: RTCPeerConnection?
    private var channel: RTCDataChannel?
    private var rx: RecordStreamReceiver?
    private var gatheringDone: (() -> Void)?
    private var done = false
    private var cancelled = false
    private let t0 = Date()

    init(saveDir: URL, claim: TransferClaim, callbacks: TransferCallbacks) {
        self.saveDir = saveDir; self.claim = claim; self.cb = callbacks
        super.init()
    }

    private func log(_ m: String, public p: Bool = false) {
        Log.rtc(String(format: "+%.0fms %@", Date().timeIntervalSince(t0) * 1000, m), public: p)
    }

    /// `reply` gets the complete answer SDP, or an error. Called on an arbitrary queue.
    func answer(offer: String, reply: @escaping (Result<String, Error>) -> Void) {
        q.async { [self] in
            guard let pc = RTCSupport.factory.peerConnection(with: RTCSupport.config(), constraints: RTCSupport.noConstraints, delegate: self) else {
                reply(.failure(RTCSupport.Err("cannot create peer connection"))); return
            }
            self.pc = pc
            log("offer \(offer.utf8.count) B, candidates \(RTCSupport.candidates(inSDP: offer))")
            log("offer candidate types \(RTCSupport.candidateTypes(inSDP: offer))", public: true)
            pc.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: offer)) { [self] err in
                if let err { reply(.failure(RTCSupport.Err("setRemoteDescription: \(err.localizedDescription)"))); return }
                pc.answer(for: RTCSupport.noConstraints) { [self] sdp, err in
                    guard let sdp else { reply(.failure(RTCSupport.Err("createAnswer: \(err?.localizedDescription ?? "nil")"))); return }
                    pc.setLocalDescription(sdp) { [self] err in
                        if let err { reply(.failure(RTCSupport.Err("setLocalDescription: \(err.localizedDescription)"))); return }
                        q.async { [self] in
                            var sent = false
                            let finish = { [self] in
                                guard !sent else { return }
                                sent = true
                                gatheringDone = nil
                                let full = pc.localDescription?.sdp ?? sdp.sdp
                                log("answer ready \(full.utf8.count) B, candidates \(RTCSupport.candidates(inSDP: full))")
                                log("answer candidate types \(RTCSupport.candidateTypes(inSDP: full))", public: true)
                                reply(.success(full))
                                armOpenTimeout()
                            }
                            log("local description set; gathering state \(pc.iceGatheringState.rawValue)", public: true)
                            if pc.iceGatheringState == .complete { finish(); return }
                            gatheringDone = finish
                            q.asyncAfter(deadline: .now() + RTCSupport.gatheringTimeout) { [self] in
                                guard gatheringDone != nil else { return }
                                log("ICE gathering not complete after \(Int(RTCSupport.gatheringTimeout)) s; answering with what we have", public: true)
                                gatheringDone?()
                            }
                        }
                    }
                }
            }
        }
    }

    private func armOpenTimeout() {
        q.asyncAfter(deadline: .now() + RTCSupport.channelOpenTimeout) { [self] in
            guard !done, !cancelled, channel?.readyState != .open else { return }
            fail("data channel did not open within \(Int(RTCSupport.channelOpenTimeout)) s")
        }
    }

    func cancel() {
        q.async { [self] in
            cancelled = true
            rx?.abort()
            teardown()
        }
    }

    private func teardown() {
        channel?.delegate = nil
        channel?.close()
        pc?.close()
        channel = nil
        pc = nil
    }

    /// On q.
    private func fail(_ why: String) {
        guard !done, !cancelled else { return }
        done = true
        rx?.abort()
        log("failed: \(why)")
        if claim.current == nil || claim.current == "rtc" { cb.failed("rtc", why) }
        teardown()
    }

    // MARK: RTCPeerConnectionDelegate (WebRTC signaling thread → q)

    func peerConnection(_ p: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ p: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ p: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ p: RTCPeerConnection) {}
    func peerConnection(_ p: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ p: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ p: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        q.async { [self] in
            log("ICE \(RTCSupport.name(newState))", public: true)
            if newState == .failed { fail("ICE failed") }
        }
    }

    func peerConnection(_ p: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        q.async { [self] in
            log("ICE gathering \(newState == .complete ? "complete" : newState == .gathering ? "gathering" : "new")", public: true)
            if newState == .complete { gatheringDone?() }
        }
    }

    func peerConnection(_ p: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        // Set the delegate right here, on WebRTC's thread, before returning. A message that arrives while the
        // channel has no delegate is dropped by WebRTC, and the phone sends 0x01 as soon as the channel opens, so
        // hopping to `q` first lost the first record now and then ("0x02 without an open file").
        // Messages are still handled on `q`, in order, after the block below has run.
        dataChannel.delegate = self
        q.async { [self] in
            log("remote opened data channel '\(dataChannel.label)' ordered=\(dataChannel.isOrdered)")
            guard dataChannel.label == RTCSupport.channelLabel, channel == nil, !cancelled else {
                log("ignoring data channel '\(dataChannel.label)'")
                dataChannel.delegate = nil
                dataChannel.close()
                return
            }
            channel = dataChannel
            if dataChannel.readyState == .open { channelOpened() }
        }
    }

    private func channelOpened() {
        guard rx == nil, !done else { return }
        guard claim.tryClaim("rtc") else { fail("transfer already running on \(claim.current ?? "?")"); return }
        log("data channel open; receiving records", public: true)
        let r = RecordStreamReceiver(saveDir: saveDir, maxDataRecord: RTCSupport.maxDataRecord)
        r.onProgress = cb.progress
        r.onFileSaved = cb.fileSaved
        rx = r
        cb.activity()
    }

    // MARK: RTCDataChannelDelegate

    func dataChannelDidChangeState(_ dc: RTCDataChannel) {
        let st = dc.readyState
        q.async { [self] in
            guard dc === channel else { return }
            log("data channel \(RTCSupport.name(st))", public: true)
            if st == .open { channelOpened() }
            if st == .closed || st == .closing { if !done { fail("data channel closed before 0x05") } }
        }
    }

    func dataChannel(_ dc: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let isBinary = buffer.isBinary
        let data = buffer.data
        q.async { [self] in
            guard dc === channel, !done, !cancelled else { return }
            if rx == nil { channelOpened() }
            guard let rx else { return }
            guard isBinary else { fail("text message on data channel"); return }
            do {
                let rec = try Record.decode(data)
                cb.activity()
                if let reply = try rx.handle(rec) {
                    let ok = channel?.sendData(RTCDataBuffer(data: reply.encoded, isBinary: true)) ?? false
                    log("-> 0x04 \(String(data: reply.body, encoding: .utf8) ?? "")\(ok ? "" : " (send FAILED)")")
                }
                if rx.finished {
                    done = true
                    log("0x05 received; stream complete", public: true)
                    cb.finished("rtc", rx.saved, rx.failedCount)
                }
            } catch {
                fail("\(error)")
            }
        }
    }
}
