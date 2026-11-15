import Foundation
import AppKit
import ServiceManagement
import CoreBluetooth
import Network
import ATACore

/// Web addresses the app links to, in one place.
enum Links {
    /// Where to get the Android app. Before the Google Play launch this is the closed-test page; at launch, switch both
    /// to the Play Store listing (https://play.google.com/store/apps/details?id=io.github.magiclin99.ata).
    static let getAndroidAppEnglish = URL(string: "https://magiclin99.github.io/ata/beta/")!
    static let getAndroidAppChinese = URL(string: "https://magiclin99.github.io/ata/zh-tw/beta/")!

    static var prefersChinese: Bool { Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true }
    static var getAndroidApp: URL { prefersChinese ? getAndroidAppChinese : getAndroidAppEnglish }
}

/// SPEC §9 debug automation flags (debug builds only).
struct LaunchOptions {
    var pairingURIFile: URL?
    var logFile: URL?
    var saveDir: URL?
    var signalPort: UInt16?
    var showPairingWindow = false
    /// Debug only: don't start Bluetooth at all (screenshots / UI checks next to a running ATA without a second
    /// advertising Mac and without a permission question).
    var noBluetooth = false
    /// Debug only: act as if ATA ran from /Applications for the "open at login after the first pairing" step, but
    /// don't actually register a login item (screenshots of a test copy).
    var fakeLoginItem = false
    /// Debug only: show the setup line about the firewall question but don't actually listen (repeat UI runs).
    var noSetupProbes = false

    static func parse(_ args: [String] = CommandLine.arguments) -> LaunchOptions {
        var o = LaunchOptions()
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        func url(_ flag: String) -> URL? {
            value(flag).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }
        }
        #if ATA_DEBUG_HOOKS
        o.pairingURIFile = url("--pairing-uri-file")
        o.logFile = url("--log-file")
        o.saveDir = url("--save-dir")
        o.signalPort = value("--debug-signal-port").flatMap { UInt16($0) }
        o.showPairingWindow = args.contains("--debug-show-pairing")
        o.noBluetooth = args.contains("--debug-no-bluetooth")
        o.fakeLoginItem = args.contains("--debug-fake-login-item")
        o.noSetupProbes = args.contains("--debug-no-setup-probes")
        #else
        if args.contains(where: { $0.hasPrefix("--pairing-uri-file") || $0.hasPrefix("--log-file") || $0.hasPrefix("--save-dir") || $0.hasPrefix("--debug-signal-port") }) {
            Log.info("debug flags ignored: this is a release build")
        }
        #endif
        return o
    }
}

enum BluetoothStatus: Equatable {
    case starting, on, off, unauthorized, unsupported, other(String)
}

struct PairingUIState: Equatable {
    enum Phase: Equatable { case waiting, success(String), failed(String), expired }
    var uri: String
    var expiresAt: Date
    var phase: Phase
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    // Published UI state
    @Published private(set) var bluetooth: BluetoothStatus = .starting
    @Published private(set) var receiving: (phone: String, file: String, fraction: Double)?
    @Published private(set) var connectedPhone: String?
    @Published private(set) var lastError: String?
    @Published private(set) var devices: [PairedDevice] = []
    @Published private(set) var recentFiles: [URL] = []
    @Published private(set) var saveDir: URL
    @Published private(set) var launchAtLogin = false
    @Published private(set) var pairing: PairingUIState?
    /// The last transfer offered the local network, nothing connected, and the macOS firewall is on: show a hint.
    /// Cleared by the next transfer that arrives over the local network.
    @Published private(set) var localNetworkBlocked = false
    /// macOS hasn't asked about Bluetooth yet: the window explains the coming prompt before ATA triggers it.
    @Published private(set) var bluetoothNotAskedYet = CBManager.authorization == .notDetermined
    /// A transfer has arrived over the same Wi-Fi at least once (so the firewall question was answered "Allow").
    @Published private(set) var hadWiFiTransfer = UserDefaults.standard.bool(forKey: "hadWiFiTransfer")
    /// Name of the phone just paired from the welcome window; the window shows the next steps until "Done".
    @Published private(set) var justPairedPhone: String?
    /// "Open at Login" was switched on automatically by the first pairing: say so, with the switch right there.
    @Published private(set) var openAtLoginTurnedOnForYou = false
    /// The firewall question is about to be (or was just) brought forward during setup: show the one-line reason.
    @Published private(set) var firewallQuestionComing = false
    /// macOS 15+: the "find devices on your local network" question is about to be asked during setup.
    @Published private(set) var localNetworkQuestionComing = false
    /// Opened straight from the disk image or from a quarantined download (macOS runs it from a temporary,
    /// read-only place): ATA doesn't start receiving, it asks to be moved to Applications first.
    @Published private(set) var needsMoveToApplications = false
    private(set) var originalAppURL: URL?

    private let options = LaunchOptions.parse()
    private let defaults = UserDefaults.standard
    /// Per bundle id, so a renamed test copy never touches the real pairings.
    private let store = FilePairingStore(url: FilePairingStore.defaultURL(bundleId: Bundle.main.bundleIdentifier ?? "io.github.magiclin99.ata.mac"))
    private(set) var engine: ReceiverEngine!
    private var ble: BLEPeripheral?
    #if ATA_DEBUG_HOOKS
    private var signal: LoopbackSignalServer?
    #endif
    private var started = false
    private var pruneTimer: Timer?
    let notifier = Notifier()

    static let releasesURL = URL(string: "https://github.com/magiclin99/ata/releases")!

    private init() {
        if let p = defaults.string(forKey: "saveDir") {
            saveDir = URL(fileURLWithPath: p)
        } else {
            saveDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        }
        if let o = options.saveDir { saveDir = o }
        recentFiles = (defaults.stringArray(forKey: "recentFiles") ?? []).map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func start() {
        guard !started else { return }
        started = true
        if let lf = options.logFile { Log.setFile(lf) }
        let info = Bundle.main.infoDictionary
        if let problem = InstallLocation.problem() {
            Log.info("running from \(problem) (\(Bundle.main.bundlePath)); asking to move ATA to Applications first")
            needsMoveToApplications = true
            originalAppURL = InstallLocation.originalURL()
            DispatchQueue.main.async { MainWindowController.shared.show() }
            return
        }
        Log.info("ATA \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?")) starting; pid \(getpid())")

        // One time: bring over pairings an earlier build kept in the Keychain (never prompts).
        if !store.fileExists { KeychainPairingImport.run(into: store) }

        let cfg = EngineConfig(macId: DeviceIdentity.loadOrCreate(), macName: DeviceIdentity.computerName(), saveDir: saveDir)
        let e = ReceiverEngine(config: cfg, store: store)
        e.onEvent = { [weak self] ev in DispatchQueue.main.async { self?.handle(ev) } }
        engine = e
        devices = store.devices()
        refreshLaunchAtLogin()

        let b = BLEPeripheral(engine: e)
        b.onStateChange = { [weak self] st in
            DispatchQueue.main.async {
                guard let self else { return }
                if CBManager.authorization != .notDetermined { self.bluetoothNotAskedYet = false }
                switch st {
                case .poweredOn: self.bluetooth = .on
                case .poweredOff: self.bluetooth = .off
                case .unauthorized: self.bluetooth = .unauthorized
                case .unsupported: self.bluetooth = .unsupported
                case .starting: self.bluetooth = .starting
                case .other(let s): self.bluetooth = .other(s)
                }
            }
        }
        ble = b
        if options.noBluetooth {
            Log.info("DEBUG Bluetooth not started (--debug-no-bluetooth)")
        } else if bluetoothNotAskedYet {
            // First launch: show the window (with a line about the coming Bluetooth question) a moment before macOS
            // asks, so the question doesn't appear out of nowhere.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { b.start() }
        } else {
            b.start()
        }

        #if ATA_DEBUG_HOOKS
        if let port = options.signalPort {
            let s = LoopbackSignalServer(engine: e)
            do { try s.start(port: port); signal = s } catch { Log.err("debug signal port \(port): \(error)") }
        }
        #endif

        if let f = options.pairingURIFile {
            let (uri, expires) = e.startPairing()
            pairing = PairingUIState(uri: uri, expiresAt: expires, phase: .waiting)
            do {
                try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data((uri + "\n").utf8).write(to: f, options: .atomic)
                Log.pair("DEBUG pairing URI written to \(f.path)")
            } catch {
                Log.err("cannot write pairing URI file: \(error)")
            }
        }
        if options.showPairingWindow { PairingWindowController.shared.show() }

        // Files can be moved or deleted at any time; keep the list honest without watching every file.
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            MainActor.assumeIsolated { AppModel.shared.pruneRecentFiles() }
        }

        // First launch (nothing paired yet): the menu bar item may be hidden, so show the window with "Pair".
        if devices.isEmpty && options.pairingURIFile == nil {
            DispatchQueue.main.async { MainWindowController.shared.show() }
        }
    }

    func shutdown() {
        ble?.stop()
        #if ATA_DEBUG_HOOKS
        signal?.stop()
        #endif
    }

    // MARK: engine events

    private func handle(_ e: EngineEvent) {
        switch e {
        case .pairingStarted:
            break
        case .pairingExpired:
            if var p = pairing, p.phase == .waiting { p.phase = .expired; pairing = p }
        case .paired(let d):
            let first = devices.isEmpty
            if var p = pairing { p.phase = .success(d.name); pairing = p }
            if first {
                justPairedPhone = d.name
                turnOnOpenAtLoginAfterFirstPairing()
                bringFirewallQuestionForward()
                bringLocalNetworkQuestionForward()
            }
        case .pairingFailed(let reason):
            if var p = pairing, p.phase == .waiting { p.phase = .failed(reason); pairing = p }
        case .devicesChanged:
            devices = store.devices()
        case .sessionStarted(let name):
            connectedPhone = name
        case .transferAccepted(let name, _, _):
            lastError = nil
            receiving = (name, "", 0)
        case .progress(let file, let got, let total):
            receiving = (receiving?.phone ?? connectedPhone ?? "", file, total > 0 ? Double(got) / Double(total) : 1)
        case .fileSaved(let url):
            addRecent(url)
        case .sessionEnded(let s):
            receiving = nil
            connectedPhone = nil
            if s.via == "lan" {
                localNetworkBlocked = false
                if !hadWiFiTransfer { hadWiFiTransfer = true; defaults.set(true, forKey: "hadWiFiTransfer") }
            }
            else if s.lanUnreached && Firewall.isEnabled() {
                Log.info("local network connection looked blocked (firewall is on); showing the firewall hint")
                localNetworkBlocked = true
            }
            if s.announcedFiles > 0 {
                if let err = s.error { lastError = Self.plainError(err) }
                else if s.failedFiles > 0 { lastError = Self.incompleteFiles(s.failedFiles) }
                notifier.transferEnded(s, savedIn: saveDirName)
            }
        }
    }

    /// Engine and phone error strings are technical; users get one plain sentence saying what happened and one
    /// thing to try (TERMS.md). The original text goes to the log only.
    nonisolated static func plainError(_ e: String) -> String {
        Log.info("transfer error shown to the user as plain text; detail: \(e)")
        switch e {
        case "cancelled": return String(localized: "The phone cancelled sending.")
        case "phone disconnected", "phone ended the session before the transfer finished":
            return String(localized: "The phone stopped before finishing. Send again.")
        case "device removed": return String(localized: "Sending stopped because this phone was removed. Pair it again to send.")
        default:
            if e.hasPrefix("timed out") {
                return String(localized: "Sending stopped partway. Move your phone closer to your Mac and send again.")
            }
            return String(localized: "Something went wrong. Send again. If it keeps happening, update ATA on both your phone and your Mac.")
        }
    }

    nonisolated static func incompleteFiles(_ n: Int) -> String {
        n == 1 ? String(localized: "1 file didn't arrive completely. Send it again.")
               : String(localized: "\(n) files didn't arrive completely. Send them again.")
    }

    /// Drops recent-file entries whose file was moved or deleted.
    func pruneRecentFiles() {
        let kept = recentFiles.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard kept != recentFiles else { return }
        recentFiles = kept
        defaults.set(recentFiles.map(\.path), forKey: "recentFiles")
    }

    private func addRecent(_ url: URL) {
        recentFiles.removeAll { $0 == url }
        recentFiles.insert(url, at: 0)
        if recentFiles.count > 8 { recentFiles.removeLast(recentFiles.count - 8) }
        defaults.set(recentFiles.map(\.path), forKey: "recentFiles")
    }

    // MARK: menu actions

    var statusLine: String {
        if let r = receiving {
            let pct = Int((r.fraction * 100).rounded(.down))
            return r.file.isEmpty ? String(localized: "Receiving files from “\(r.phone)”…") : String(localized: "Receiving “\(r.file)” (\(pct)%)")
        }
        if let p = connectedPhone { return String(localized: "“\(p)” is connected") }
        switch bluetooth {
        case .starting:
            return bluetoothNotAskedYet ? String(localized: "Waiting for you to allow Bluetooth…") : String(localized: "Starting…")
        case .off: return String(localized: "Bluetooth is off. Turn it on to receive files.")
        case .unauthorized: return String(localized: "ATA isn't allowed to use Bluetooth yet.")
        case .unsupported: return String(localized: "This Mac's Bluetooth can't be used with ATA.")
        case .other: return String(localized: "Bluetooth isn't available right now. Try again in a moment.")
        case .on: break
        }
        if needsMoveToApplications { return String(localized: "Move ATA to Applications first") }
        if let e = lastError { return e }
        if devices.isEmpty { return String(localized: "No phone paired yet") }
        return String(localized: "Ready. Send from your phone any time.")
    }

    var statusSymbol: String {
        if receiving != nil { return "arrow.down.circle.fill" }
        switch bluetooth {
        case .on: return lastError == nil ? "checkmark.circle" : "exclamationmark.triangle"
        case .starting: return "ellipsis.circle"
        default: return "exclamationmark.triangle"
        }
    }

    /// nil = show the ATA mark; otherwise a status glyph (receiving, or Bluetooth needs attention).
    var menuBarSymbol: String? {
        if receiving != nil { return "arrow.down.circle.fill" }
        if bluetooth == .on || bluetooth == .starting { return nil }
        return "exclamationmark.triangle"
    }

    var saveDirName: String { FileManager.default.displayName(atPath: saveDir.path) }

    var versionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    func checkForUpdates() { NSWorkspace.shared.open(Self.releasesURL) }

    /// FAQ entry explaining the firewall fix, in the UI language.
    static var firewallHelpURL: URL {
        let zh = Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true
        return URL(string: zh ? "https://magiclin99.github.io/ata/zh-tw/faq/#firewall" : "https://magiclin99.github.io/ata/faq/#firewall")!
    }

    func openFirewallHelp() { NSWorkspace.shared.open(Self.firewallHelpURL) }

    /// nil (the default) hides "Support ATA…". Opening it changes nothing in the app.
    let supportURL: URL? = SupportLink.url(in: .main)

    func openSupport() { if let u = supportURL { NSWorkspace.shared.open(u) } }

    /// System Settings → Privacy & Security → Bluetooth (where ATA's permission is switched on).
    func openBluetoothPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!)
    }

    /// System Settings → Bluetooth (to turn Bluetooth on).
    func openBluetoothSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
    }

    /// Tell people about the firewall question until a transfer over the same Wi-Fi has worked once.
    var showFirewallTip: Bool { !hadWiFiTransfer && Firewall.isEnabled() }

    var showInDock: Bool {
        get { ActivationPolicy.showInDock }
        set { objectWillChange.send(); ActivationPolicy.setShowInDock(newValue) }
    }

    /// The welcome window shows a live pairing QR code while nothing is paired.
    func ensureWelcomePairing() {
        guard devices.isEmpty, engine != nil else { return }
        if pairing == nil { beginPairing() }
    }

    func openGetAndroidApp() { NSWorkspace.shared.open(Links.getAndroidApp) }

    /// Shows the app bundle the person actually downloaded (not the temporary copy macOS runs), so they can drag it
    /// to Applications.
    func revealAppForMoving() {
        NSWorkspace.shared.activateFileViewerSelecting([originalAppURL ?? Bundle.main.bundleURL])
    }

    func beginPairing() {
        guard let engine else { return }
        let (uri, expires) = engine.startPairing()
        pairing = PairingUIState(uri: uri, expiresAt: expires, phase: .waiting)
    }

    func endPairing() {
        engine?.cancelPairing()
        pairing = nil
    }

    func remove(_ d: PairedDevice) {
        engine?.removeDevice(phoneId: d.phoneId)
    }

    func reveal(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            recentFiles.removeAll { $0 == url }
            defaults.set(recentFiles.map(\.path), forKey: "recentFiles")
        }
    }

    func clearRecent() {
        recentFiles = []
        defaults.removeObject(forKey: "recentFiles")
    }

    func chooseSaveFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.message = String(localized: "Choose where ATA saves received files")
        panel.prompt = String(localized: "Choose")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = saveDir
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveDir = url
        defaults.set(url.path, forKey: "saveDir")
        engine?.setSaveDir(url)
    }

    func openSaveFolder() { NSWorkspace.shared.open(saveDir) }

    func refreshLaunchAtLogin() {
        if options.fakeLoginItem { return }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Called from the switch: remember that the person decided, so ATA never turns it back on by itself.
    func userSetLaunchAtLogin(_ on: Bool) {
        defaults.set(on, forKey: "openAtLoginUserChoice")
        if options.fakeLoginItem { launchAtLogin = on; return }
        setLaunchAtLogin(on)
    }

    /// JOURNEY: after a restart ATA must be running, or the phone "can't find the Mac". So the first successful
    /// pairing turns on Open at Login, and the success view says so with the switch visible. Never when the person
    /// already chose (on or off), and only for the copy in /Applications (a login item for a copy in Downloads or a
    /// disk image would break when that copy moves).
    private func turnOnOpenAtLoginAfterFirstPairing() {
        guard defaults.object(forKey: "openAtLoginUserChoice") == nil else { return }
        let inApplications = Bundle.main.bundlePath.hasPrefix("/Applications/")
        if options.fakeLoginItem {
            launchAtLogin = true; openAtLoginTurnedOnForYou = true; return
        }
        guard inApplications, SMAppService.mainApp.status != .enabled else { return }
        setLaunchAtLogin(true)
        if launchAtLogin {
            openAtLoginTurnedOnForYou = true
            Log.info("open at login turned on after the first pairing")
        }
    }

    func dismissJustPaired() {
        justPairedPhone = nil
        openAtLoginTurnedOnForYou = false
        endPairing()
    }

    /// The macOS firewall asks "accept incoming network connections?" the first time ATA listens. Left alone, that
    /// happens in the middle of the first transfer, and while it waits the phone falls back to the slow path. So,
    /// right after the first pairing, while the person is looking at the Mac, ATA shows one line about the question
    /// and then listens briefly (nothing connects to it), which makes macOS ask now. The per-transfer listener and
    /// the "firewall is blocking your phone" hint stay as they are.
    func bringFirewallQuestionForward() {
        guard !hadWiFiTransfer, Firewall.isEnabled(), !Firewall.isAllowed(Bundle.main.bundlePath) else { return }
        firewallQuestionComing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.openProbeListener() }
    }

    private var probe: NWListener?
    private func openProbeListener() {
        if options.noSetupProbes { Log.info("DEBUG setup listener skipped"); return }
        guard probe == nil, let l = try? NWListener(using: .tcp, on: .any) else { return }
        l.newConnectionHandler = { $0.cancel() }
        l.stateUpdateHandler = { st in Log.info("setup listener: \(st)") }
        l.start(queue: .main)
        probe = l
        Log.info("setup: listening briefly so macOS asks the firewall question now")
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.probe?.cancel(); self?.probe = nil
        }
    }

    /// macOS 15+ (Apple TN3179): files arriving over the same Wi-Fi are incoming connections, which need no Local
    /// Network permission, but when ATA has to fall back to the internet path while the phone is on the same Wi-Fi
    /// it sends to the phone's local address, which does. macOS would ask then, mid-transfer. TN3179's recommended
    /// way to ask at a chosen moment: connect a UDP socket to a local network address (no traffic is sent). Done
    /// right after the first pairing, after one line explaining the question. Not verifiable on macOS 14.
    func bringLocalNetworkQuestionForward() {
        guard #available(macOS 15, *) else { return }
        guard defaults.object(forKey: "localNetworkAsked") == nil else { return }
        localNetworkQuestionComing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.connectLocalUDP() }
    }

    private var localProbeFD: Int32 = -1
    private func connectLocalUDP() {
        if options.noSetupProbes { return }
        // Any address on our own Wi-Fi/Ethernet network other than ours: ".1" (or ".2" if we are ".1").
        guard let me = lanIPv4Addresses().first?.ip else { return }
        var parts = me.split(separator: ".").map(String.init)
        guard parts.count == 4 else { return }
        parts[3] = parts[3] == "1" ? "2" : "1"
        var sa = sockaddr_in()
        sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sa.sin_family = sa_family_t(AF_INET)
        sa.sin_port = in_port_t(9).bigEndian
        guard inet_pton(AF_INET, parts.joined(separator: "."), &sa.sin_addr) == 1 else { return }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }
        let r = withUnsafePointer(to: &sa) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        Log.info("setup: local network check (connect UDP) result \(r == 0 ? "ok" : String(cString: strerror(errno)))")
        defaults.set(true, forKey: "localNetworkAsked")
        localProbeFD = fd
        // Keep it open for a while: macOS may not show the question for a socket that disappears at once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.localProbeFD >= 0 else { return }
            close(self.localProbeFD); self.localProbeFD = -1
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.err("launch at login: \(error)")
            lastError = String(localized: "Couldn't turn on Open at Login. Move ATA to the Applications folder and try again.")
        }
        refreshLaunchAtLogin()
    }
}
