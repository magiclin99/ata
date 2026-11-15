import SwiftUI
import AppKit
import ATACore

@main
struct ATAApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            // Normally the ATA mark (template image from the brand assets); a status glyph only while receiving or
            // when something needs attention. SF Symbols are used here only as interface glyphs, never as the icon.
            Group {
                if let symbol = model.menuBarSymbol { Image(systemName: symbol) } else { Image(nsImage: MenuBarIcon.image) }
            }
            .accessibilityLabel(Text(verbatim: "ATA"))
        }
        .menuBarExtraStyle(.menu)
    }
}

/// App lifecycle. The Dock icon policy is in `ActivationPolicy`. Opening ATA again (Dock icon, Finder, Spotlight,
/// Launchpad) shows the main window, because the menu bar item can be hidden behind the camera notch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let showWindowNotification = Notification.Name("io.github.magiclin99.ata.mac.show-main-window")

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            if Self.handOffToRunningInstance() { return }
            DistributedNotificationCenter.default().addObserver(forName: Self.showWindowNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MainWindowController.shared.show() }
            }
            ActivationPolicy.applyAtLaunch()
            AppModel.shared.start()
            Self.quitOnSIGTERM()
        }
    }

    /// `install.sh` (and `kill`) ask ATA to quit with SIGTERM; treat it like Quit so shutdown runs.
    private static var sigterm: DispatchSourceSignal?
    @MainActor private static func quitOnSIGTERM() {
        signal(SIGTERM, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        s.setEventHandler { Log.info("SIGTERM received"); NSApp.terminate(nil) }
        s.resume()
        sigterm = s
    }

    /// Opening ATA while it is already running (Dock click, double-click in Finder, Spotlight, `open`) lands here.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { MainWindowController.shared.show() }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.shutdown() }
        Log.info("ATA quitting")
    }

    /// A second copy (another path, or `open -n`) must not start a second BLE peripheral. It asks the running one to
    /// show its window and quits.
    @MainActor private static func handOffToRunningInstance() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        guard let other = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first(where: { $0.processIdentifier != me && !$0.isTerminated }) else { return false }
        Log.info("ATA is already running (pid \(other.processIdentifier)); showing its window and quitting")
        DistributedNotificationCenter.default().postNotificationName(showWindowNotification, object: nil, userInfo: nil,
                                                                     deliverImmediately: true)
        other.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
        return true
    }
}

// MARK: - Menu

struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Button {} label: { Label(model.statusLine, systemImage: model.statusSymbol) }
            .disabled(true)
        switch model.bluetooth {
        case .unauthorized:
            Button("Allow Bluetooth for ATA…") { model.openBluetoothPrivacySettings() }
        case .off:
            Button("Open Bluetooth Settings…") { model.openBluetoothSettings() }
        default:
            EmptyView()
        }
        if model.localNetworkBlocked {
            Button { model.openFirewallHelp() } label: {
                Label("Your Mac's firewall is blocking your phone. How to Fix…", systemImage: "exclamationmark.triangle")
            }
        }

        Divider()

        Button("Open ATA Window") { MainWindowController.shared.show() }
        Button("Pair a Phone…") { PairingWindowController.shared.show() }
            .keyboardShortcut("n")

        if !model.devices.isEmpty {
            Menu("Paired Phones") {
                ForEach(model.devices) { d in
                    Menu {
                        Text("Paired on \(d.pairedAt.formatted(date: .abbreviated, time: .omitted))")
                        Divider()
                        Button("Remove “\(d.name)”") { model.remove(d) }
                    } label: {
                        Label(d.name, systemImage: "iphone")
                    }
                }
            }
        }

        Divider()

        if !model.recentFiles.isEmpty {
            Section("Recently Received — Click to Show in Finder") {
                ForEach(model.recentFiles, id: \.self) { url in
                    Button { model.reveal(url) } label: {
                        Label { Text(verbatim: url.lastPathComponent) } icon: { Image(nsImage: fileIcon(url)) }
                    }
                }
            }
            Divider()
        }

        Button("Save to “\(model.saveDirName)”…") { model.chooseSaveFolder() }
        Button("Open Save Folder") { model.openSaveFolder() }
        Toggle("Open at Login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))

        Divider()

        Button("Check for Updates…") { model.checkForUpdates() }
        if model.supportURL != nil {
            Button("Support ATA…") { model.openSupport() }
        }
        Button("Quit ATA") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
            .onAppear { model.pruneRecentFiles() }
    }

    private func fileIcon(_ url: URL) -> NSImage {
        let img = NSWorkspace.shared.icon(forFile: url.path)
        img.size = NSSize(width: 16, height: 16)
        return img
    }
}

enum MenuBarIcon {
    /// Resources/MenuBarIcon.png (+ @2x), drawn from the one-colour brand mark; template so macOS tints it.
    static let image: NSImage = {
        let img = NSImage(named: "MenuBarIcon") ?? NSImage(size: NSSize(width: 18, height: 18))
        img.isTemplate = true
        img.size = NSSize(width: 18, height: 18)
        return img
    }()
}

// MARK: - Dock icon

/// Dock icon policy. ATA's audience is non-technical, and the menu bar item can be hidden behind the camera notch,
/// so by default ATA shows a normal Dock icon: people can see that it is running and click it to get the window back.
/// "Show ATA in the Dock" (main window → Settings) can turn that off, after which ATA lives in the menu bar and only
/// shows a Dock icon while one of its windows is open (so the window can't get lost behind others).
@MainActor
enum ActivationPolicy {
    static let showInDockKey = "showInDock"
    static var showInDock: Bool { UserDefaults.standard.object(forKey: showInDockKey) as? Bool ?? true }

    /// At launch (Info.plist keeps LSUIElement, so nothing flashes in the Dock when the setting is off).
    static func applyAtLaunch() {
        if showInDock { NSApp.setActivationPolicy(.regular) }
    }

    static func setShowInDock(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: showInDockKey)
        if on { NSApp.setActivationPolicy(.regular) }
        else if !anyWindowVisible(except: nil) { NSApp.setActivationPolicy(.accessory) }
    }

    static func windowWillShow() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
    }

    static func windowDidClose(_ closing: NSWindow) {
        DispatchQueue.main.async {
            if !showInDock, !anyWindowVisible(except: closing), NSApp.activationPolicy() != .accessory {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    private static func anyWindowVisible(except w: NSWindow?) -> Bool {
        NSApp.windows.contains { $0 !== w && $0.isVisible && $0.styleMask.contains(.titled) && $0.level == .normal }
    }
}

// MARK: - Pairing window

/// AppKit-owned window so it can be brought to front from a menu bar app.
@MainActor
final class PairingWindowController: NSObject, NSWindowDelegate {
    static let shared = PairingWindowController()
    private var window: NSWindow?

    func show() {
        let model = AppModel.shared
        if model.pairing == nil || model.pairing?.phase != .waiting { model.beginPairing() }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 520),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = String(localized: "Pair a Phone")
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: PairingView(model: model, close: { [weak self] in self?.window?.performClose(nil) }))
            w.delegate = self
            w.center()
            window = w
        }
        ActivationPolicy.windowWillShow()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        AppModel.shared.endPairing()
        if let w = window { ActivationPolicy.windowDidClose(w) }
    }
}

struct PairingView: View {
    @ObservedObject var model: AppModel
    var close: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            if let p = model.pairing {
                header(p)
                qr(p)
                footer(p)
            } else {
                ProgressView().frame(height: 300)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 34)
        .padding(.bottom, 22)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func header(_ p: PairingUIState) -> some View {
        VStack(spacing: 6) {
            Text("Pair a Phone").font(.title2.weight(.semibold))
            if case .success = p.phase {
                EmptyView()
            } else {
                Text("On your phone, open ATA, tap “Pair with a Mac”, and scan this QR code.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func qr(_ p: PairingUIState) -> some View {
        let dimmed = p.phase != .waiting
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            if let img = QRCode.image(for: p.uri) {
                Image(nsImage: img)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(14)
                    .opacity(dimmed ? 0.12 : 1)
                    .accessibilityLabel(Text("Pairing QR code"))
            }
            overlay(p.phase)
        }
        .frame(width: 236, height: 236)
        .animation(.easeInOut(duration: 0.2), value: p.phase)
    }

    @ViewBuilder private func overlay(_ phase: PairingUIState.Phase) -> some View {
        switch phase {
        case .waiting: EmptyView()
        case .success:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 72)).foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill").font(.system(size: 64)).foregroundStyle(.red)
        case .expired:
            Image(systemName: "clock.badge.exclamationmark").font(.system(size: 60)).foregroundStyle(.orange)
        }
    }

    @ViewBuilder private func footer(_ p: PairingUIState) -> some View {
        VStack(spacing: 14) {
            switch p.phase {
            case .waiting:
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let left = max(0, Int(p.expiresAt.timeIntervalSince(ctx.date).rounded(.up)))
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for your phone… This QR code works for \(left / 60):\(String(format: "%02d", left % 60)) more.")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            case .success(let name):
                VStack(spacing: 8) {
                    Text("Paired with “\(name)”").font(.headline)
                    Text("Now share photos or files on your phone and choose ATA. They'll arrive on this Mac.")
                        .font(.callout).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.showFirewallTip {
                        Text("If your Mac asks whether ATA may accept incoming network connections, click “Allow” so your phone can deliver files.")
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            case .failed:
                VStack(spacing: 4) {
                    Text("Pairing didn't work").font(.headline)
                    Text("Show a new QR code and scan it again with your phone.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            case .expired:
                VStack(spacing: 4) {
                    Text("This QR code no longer works").font(.headline)
                    Text("Show a new QR code and scan it again with your phone.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            HStack {
                if p.phase != .waiting, !isSuccess(p.phase) {
                    Button("Show a New QR Code") { model.beginPairing() }
                        .keyboardShortcut(.defaultAction)
                }
                Spacer()
                Button(isSuccess(p.phase) ? "Done" : "Cancel") { close() }
                    .keyboardShortcut(isSuccess(p.phase) ? .defaultAction : .cancelAction)
            }
            .controlSize(.large)
        }
        .frame(minHeight: 84, alignment: .top)
    }

    private func isSuccess(_ p: PairingUIState.Phase) -> Bool { if case .success = p { return true }; return false }
}

enum QRCode {
    static func image(for text: String) -> NSImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(text.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = f.outputImage else { return nil }
        let scaled = out.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}
