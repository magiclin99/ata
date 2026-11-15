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

    private let options = LaunchOptions.parse()
    private let defaults = UserDefaults.standard
    private let store = FilePairingStore()
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
        b.start()

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
            if s.via == "lan" { localNetworkBlocked = false }
            else if s.lanUnreached && Firewall.isEnabled() {
                Log.info("local network connection looked blocked (firewall is on); showing the firewall hint")
                localNetworkBlocked = true
            }
            if s.announcedFiles > 0 {
                if let err = s.error { lastError = Self.localizedEngineError(err) }
                else if s.failedFiles > 0 { lastError = String(localized: "\(s.failedFiles) file(s) failed verification") }
                notifier.transferEnded(s)
            }
        }
    }

    /// Engine errors are English protocol-level strings; translate the ones ATA itself produces. Text that came
    /// from the phone (a `bye` error) is shown as is.
    nonisolated static func localizedEngineError(_ e: String) -> String {
        if e == "phone disconnected" { return String(localized: "The phone disconnected before the transfer finished") }
        if e == "device removed" { return String(localized: "The device was removed") }
        if e == "BLE message failed to decrypt" { return String(localized: "A Bluetooth message could not be decrypted") }
        if e == "phone reported failure" { return String(localized: "The phone reported a failure") }
        if e == "phone ended the session before the transfer finished" {
            return String(localized: "The phone ended the session before the transfer finished")
        }
        if e.hasPrefix("timed out") { return String(localized: "The transfer timed out") }
        if let r = e.range(of: "transfer failed: ") {
            return String(localized: "Transfer failed: \(String(e[r.upperBound...]))")
        }
        return e
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
            return r.file.isEmpty ? String(localized: "Receiving from \(r.phone)…") : String(localized: "Receiving “\(r.file)” \(pct)%")
        }
        if let p = connectedPhone { return String(localized: "Connected to \(p)") }
        switch bluetooth {
        case .starting:
            return CBManager.authorization == .notDetermined ? String(localized: "Waiting for Bluetooth permission…") : String(localized: "Starting…")
        case .off: return String(localized: "Bluetooth is off")
        case .unauthorized: return String(localized: "Bluetooth access not allowed")
        case .unsupported: return String(localized: "Bluetooth LE not supported")
        case .other(let s): return String(localized: "Bluetooth: \(s)")
        case .on: break
        }
        if let e = lastError { return String(localized: "Error: \(e)") }
        return String(localized: "Ready")
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
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
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

    func openBluetoothSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!)
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
            lastError = String(localized: "Launch at login: \(error.localizedDescription)")
        }
        refreshLaunchAtLogin()
    }
}
