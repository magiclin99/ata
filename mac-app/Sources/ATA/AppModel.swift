import Foundation
import AppKit
import ServiceManagement
import CoreBluetooth
import ATACore

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
            if var p = pairing { p.phase = .success(d.name); pairing = p }
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

    func beginPairing() {
        let (uri, expires) = engine.startPairing()
        pairing = PairingUIState(uri: uri, expiresAt: expires, phase: .waiting)
    }

    func endPairing() {
        engine.cancelPairing()
        pairing = nil
    }

    func remove(_ d: PairedDevice) {
        engine.removeDevice(phoneId: d.phoneId)
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
        engine.setSaveDir(url)
    }

    func openSaveFolder() { NSWorkspace.shared.open(saveDir) }

    func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
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
