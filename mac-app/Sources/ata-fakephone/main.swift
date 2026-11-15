import Foundation
import ATACore
import ATAFakePhone

// Regression driver for a running debug ATA.app without a phone: speaks SPEC v2 over the app's debug loopback
// signaling port (instead of BLE) and then sends files over LAN TCP or WebRTC.

setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
usage: ata-fakephone --signal-port P [options]

  --signal-port P        the app's --debug-signal-port
  --uri-file F | --uri U pair with this ata://pair URI (pairing:true); saves the key to the state file
  --state F              phone identity + keys (default: $TMPDIR/ata-fakephone-state.json)
  --name NAME            phone name (default "Fake Phone")
  --pair-only            stop after the handshake (sends bye)
  --files A B ...        send these files (must be last)
  --count M --mib N      send M random files of N MiB each (default 1 x 1 MiB)
  --rtc                  skip LAN TCP, use the WebRTC data channel
  --lan-ip IP            connect to this IP instead of accept.lan (e.g. 127.0.0.1)
  tamper (expect failure): --wrong-sid  --bad-sha I  --corrupt-record N  --truncate BYTES
                           --bad-mac (handshake)
Prints a final line: RESULT ok=<bool> via=<lan|rtc|none> files=<n> bytes=<n> ms=<n>
"""

var args = Array(CommandLine.arguments.dropFirst())
func opt(_ n: String) -> String? {
    guard let i = args.firstIndex(of: n), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func flag(_ n: String) -> Bool { args.contains(n) }
func log(_ s: String) { Log.log("PHONE", s) }
func die(_ s: String) -> Never { log("ERROR \(s)"); print("RESULT ok=false via=none files=0 bytes=0 ms=0"); exit(1) }

if flag("-h") || flag("--help") { print(usage); exit(0) }
guard let portS = opt("--signal-port"), let signalPort = UInt16(portS) else { print(usage); exit(2) }

let statePath = URL(fileURLWithPath: opt("--state") ?? (NSTemporaryDirectory() + "ata-fakephone-state.json"))
struct State: Codable { var phoneId: String; var name: String; var macId: String?; var k: String? }
var state: State = {
    if let d = try? Data(contentsOf: statePath), let s = try? JSONDecoder().decode(State.self, from: d) { return s }
    return State(phoneId: Hex.encode(randomBytes(16)), name: "Fake Phone", macId: nil, k: nil)
}()
if let n = opt("--name") { state.name = n }

var pairURI: String? = opt("--uri")
if let f = opt("--uri-file") {
    guard let s = try? String(contentsOfFile: f, encoding: .utf8) else { die("cannot read \(f)") }
    pairURI = s.trimmingCharacters(in: .whitespacesAndNewlines)
}

let t0 = Date()
let channel: LoopbackChannel
do { channel = try LoopbackChannel(port: signalPort) } catch { die("connect to signaling port \(signalPort): \(error)") }
let phone = FakePhone(channel: channel, phoneId: Hex.decode(state.phoneId)!, name: state.name)
phone.log = log

do {
    try phone.awaitHello()
    let k: Data
    let pairing: Bool
    if let uri = pairURI {
        guard let p = PairingOffer.parse(uri) else { die("malformed pairing URI") }
        guard p.macId == phone.macId else { die("URI is for mac \(Hex.encode(p.macId)) but hello says \(Hex.encode(phone.macId))") }
        k = p.k; pairing = true
        log("pairing with \"\(p.name)\"")
    } else {
        guard let ks = state.k, let kk = Base64URL.decode(ks), state.macId == Hex.encode(phone.macId) else {
            die("not paired with mac \(Hex.encode(phone.macId)); pass --uri-file")
        }
        k = kk; pairing = false
    }
    switch try phone.authenticate(k: k, pairing: pairing, corruptMAC: flag("--bad-mac")) {
    case .fail(let reason): die("auth_fail \(reason)")
    case .ok(let name): log("authenticated with \"\(name)\"")
    }
    if pairing {
        state.macId = Hex.encode(phone.macId)
        state.k = Base64URL.encode(k)
        try JSONEncoder().encode(state).write(to: statePath, options: .atomic)
        log("pairing saved to \(statePath.path)")
    }
    if flag("--pair-only") {
        try phone.bye(ok: true, via: nil)
        print("RESULT ok=true via=none files=0 bytes=0 ms=\(Int(Date().timeIntervalSince(t0) * 1000))")
        exit(0)
    }

    var files: [OutgoingFile] = []
    if let i = args.firstIndex(of: "--files") {
        for p in args[(i + 1)...] { files.append(try OutgoingFile(url: URL(fileURLWithPath: p))) }
    } else {
        let count = opt("--count").flatMap(Int.init) ?? 1
        let mib = opt("--mib").flatMap(Double.init) ?? 1
        for i in 0..<count {
            files.append(OutgoingFile(name: "fakephone-\(i + 1).bin", data: randomBytes(Int(mib * 1024 * 1024))))
        }
    }
    let bytes = files.reduce(0) { $0 + $1.data.count }
    let accept = try phone.requestSend(files)
    guard accept["t"] as? String == "accept" else { die("send not accepted: \(logSummary(accept))") }
    let lan = (accept["lan"] as? [String]) ?? []
    let port = UInt16(jsonInt64(accept["tcpPort"]) ?? 0)
    log("accept tcpPort=\(port) lan=\(lan)")

    let tStart = Date()
    var outcomes: [FileOutcome] = []
    var via = "none"
    var failure: String?
    do {
        if flag("--rtc") {
            via = "rtc"
            outcomes = try phone.sendFilesRTC(files, badShaFiles: Set(opt("--bad-sha").flatMap(Int.init).map { [$0] } ?? []))
        } else {
            via = "lan"
            var t = LANTamper()
            t.wrongSid = flag("--wrong-sid")
            t.corruptRecordIndex = opt("--corrupt-record").flatMap(Int.init)
            t.badShaFiles = Set(opt("--bad-sha").flatMap(Int.init).map { [$0] } ?? [])
            t.truncateAfterBytes = opt("--truncate").flatMap(Int.init)
            let sock = try phone.connectLAN(addresses: opt("--lan-ip").map { [$0] } ?? lan, port: port)
            outcomes = try phone.sendFilesLAN(sock, files: files, tamper: t)
            sock.close()
        }
    } catch {
        failure = "\(error)"
        log("transfer failed: \(error)")
    }
    let ok = failure == nil && outcomes.count == files.count && outcomes.allSatisfy(\.ok)
    let ms = Int(Date().timeIntervalSince(tStart) * 1000)
    if ok { log(String(format: "%.1f MB/s", Double(bytes) / 1e6 / max(0.001, Date().timeIntervalSince(tStart)))) }
    let err = failure ?? outcomes.first(where: { !$0.ok })?.error
    try? phone.bye(ok: ok, via: failure == nil ? via : nil, error: err)
    Thread.sleep(forTimeInterval: 0.3)
    channel.disconnect()
    print("RESULT ok=\(ok) via=\(failure == nil ? via : "none") files=\(outcomes.filter(\.ok).count) bytes=\(bytes) ms=\(ms)")
    exit(ok ? 0 : 1)
} catch {
    die("\(error)")
}
