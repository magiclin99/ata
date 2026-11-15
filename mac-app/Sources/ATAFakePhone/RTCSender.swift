import Foundation
import CryptoKit
import WebRTC
import ATACore

/// Phone side of SPEC §7b: creates the `ata-file` channel, makes a complete (non-trickle) offer, sends records as
/// binary messages with bufferedAmount back-pressure (high water 1 MiB).
public final class RTCSender: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    private var pc: RTCPeerConnection!
    private var dc: RTCDataChannel!
    private var gathered: (() -> Void)?
    private let cond = NSCondition()
    private var isOpen = false
    private var replies: [Data] = []
    private var closed = false
    public var log: (String) -> Void = { _ in }
    static let highWater: UInt64 = 1 << 20

    public override init() {
        super.init()
        pc = RTCSupport.factory.peerConnection(with: RTCSupport.config(), constraints: RTCSupport.noConstraints, delegate: self)
        let cfg = RTCDataChannelConfiguration()
        cfg.isOrdered = true
        dc = pc.dataChannel(forLabel: RTCSupport.channelLabel, configuration: cfg)
        dc.delegate = self
    }

    /// Complete offer SDP after ICE gathering (≤ 5 s).
    public func makeOffer() throws -> String {
        let sem = DispatchSemaphore(value: 0)
        var offer: String?
        pc.offer(for: RTCSupport.noConstraints) { [self] sdp, _ in
            guard let sdp else { sem.signal(); return }
            pc.setLocalDescription(sdp) { [self] _ in
                let fin = { [self] in offer = pc.localDescription?.sdp ?? sdp.sdp; sem.signal() }
                if pc.iceGatheringState == .complete { fin() } else { gathered = fin }
            }
        }
        if sem.wait(timeout: .now() + RTCSupport.gatheringTimeout + 1) == .timedOut {
            gathered = nil
            offer = pc.localDescription?.sdp
        }
        guard let offer else { throw FakePhoneError("could not create offer") }
        log("offer ready (\(offer.utf8.count) B)")
        return offer
    }

    public func setAnswer(_ sdp: String) throws {
        let sem = DispatchSemaphore(value: 0)
        var err: Error?
        pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { e in err = e; sem.signal() }
        sem.wait()
        if let err { throw err }
    }

    public func waitOpen(timeout: TimeInterval = RTCSupport.channelOpenTimeout) throws {
        cond.lock(); defer { cond.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !isOpen { if !cond.wait(until: deadline) { throw FakePhoneError("data channel did not open") } }
        log("data channel open")
    }

    private func put(_ r: Record) throws {
        cond.lock()
        while dc.bufferedAmount > Self.highWater && !closed { _ = cond.wait(until: Date().addingTimeInterval(0.05)) }
        let c = closed
        cond.unlock()
        if c { throw FakePhoneError("data channel closed") }
        guard dc.sendData(RTCDataBuffer(data: r.encoded, isBinary: true)) else { throw FakePhoneError("sendData failed") }
    }

    private func nextReply(timeout: TimeInterval) throws -> Record {
        cond.lock(); defer { cond.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while replies.isEmpty {
            if closed { throw FakePhoneError("data channel closed") }
            if !cond.wait(until: deadline) { throw FakePhoneError("no 0x04 reply") }
        }
        return try Record.decode(replies.removeFirst())
    }

    public func sendFiles(_ files: [OutgoingFile], badShaFiles: Set<Int> = []) throws -> [FileOutcome] {
        var outcomes: [FileOutcome] = []
        for (i, f) in files.enumerated() {
            try put(.fileStart(name: f.name, size: Int64(f.data.count)))
            var hasher = SHA256()
            var off = 0
            while off < f.data.count {
                let end = min(off + RTCSupport.maxDataRecord, f.data.count)
                let piece = f.data.subdata(in: off..<end)
                hasher.update(data: piece)
                try put(Record(.data, piece))
                off = end
            }
            let sha = badShaFiles.contains(i) ? String(repeating: "0", count: 64) : Hex.encode(Data(hasher.finalize()))
            try put(.fileEnd(sha256: sha))
            let rec = try nextReply(timeout: 60)
            guard rec.type == .fileResult, let j = rec.jsonBody() else { throw FakePhoneError("expected 0x04") }
            outcomes.append(FileOutcome(ok: jsonBool(j["ok"]) ?? false, error: j["error"] as? String))
        }
        try put(Record(.allDone))
        // Let the last message drain before the caller closes.
        let deadline = Date().addingTimeInterval(5)
        while dc.bufferedAmount > 0 && Date() < deadline { usleep(10_000) }
        return outcomes
    }

    public func close() {
        dc.close()
        pc.close()
    }

    // MARK: delegates
    public func peerConnection(_ p: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    public func peerConnection(_ p: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    public func peerConnection(_ p: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    public func peerConnectionShouldNegotiate(_ p: RTCPeerConnection) {}
    public func peerConnection(_ p: RTCPeerConnection, didChange newState: RTCIceConnectionState) { log("ICE \(RTCSupport.name(newState))") }
    public func peerConnection(_ p: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete, let g = gathered { gathered = nil; g() }
    }
    public func peerConnection(_ p: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    public func peerConnection(_ p: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    public func peerConnection(_ p: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    public func dataChannelDidChangeState(_ d: RTCDataChannel) {
        cond.lock()
        if d.readyState == .open { isOpen = true }
        if d.readyState == .closed { closed = true }
        cond.broadcast()
        cond.unlock()
    }
    public func dataChannel(_ d: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        cond.lock()
        replies.append(buffer.data)
        cond.broadcast()
        cond.unlock()
    }
    public func dataChannel(_ d: RTCDataChannel, didChangeBufferedAmount amount: UInt64) {
        cond.lock(); cond.broadcast(); cond.unlock()
    }
}

extension FakePhone {
    /// After `accept`: WebRTC path over the encrypted message channel (rtc_offer → rtc_answer → data channel).
    public func sendFilesRTC(_ files: [OutgoingFile], badShaFiles: Set<Int> = []) throws -> [FileOutcome] {
        let s = RTCSender()
        s.log = log
        defer { s.close() }
        let offer = try s.makeOffer()
        try sendEncrypted(["t": "rtc_offer", "sdp": offer])
        let r = try receiveEncrypted(timeout: 15)
        guard r["t"] as? String == "rtc_answer", let sdp = r["sdp"] as? String else {
            throw FakePhoneError("expected rtc_answer, got \(logSummary(r))")
        }
        try s.setAnswer(sdp)
        try s.waitOpen()
        return try s.sendFiles(files, badShaFiles: badShaFiles)
    }
}
