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

/// Dock / activation policy: ATA stays an agent app (`LSUIElement`, no Dock icon) while it runs in the background,
/// because it is a receiver that is meant to be always on. The menu bar item is not a reliable entry point (a full
/// menu bar or the notch can hide it), so opening ATA again from Finder, Spotlight or Launchpad shows the main
/// window, and while that window is open ATA switches to a regular app (Dock icon, ⌘-Tab) so the window cannot get
/// lost behind others. Closing the window returns it to the background.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let showWindowNotification = Notification.Name("io.github.magiclin99.ata.mac.show-main-window")

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            if Self.handOffToRunningInstance() { return }
            DistributedNotificationCenter.default().addObserver(forName: Self.showWindowNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MainWindowController.shared.show() }
            }
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

    /// Opening ATA while it is already running (double-click in Finder, Spotlight, `open`) lands here.
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
        if case .unauthorized = model.bluetooth {
            Button("Open Bluetooth Privacy Settings…") { model.openBluetoothSettings() }
        }
        if model.localNetworkBlocked {
            Button { model.openFirewallHelp() } label: {
                Label("Local network connection was blocked — check the macOS firewall", systemImage: "exclamationmark.triangle")
            }
        }

        Divider()

        Button("Open ATA Window") { MainWindowController.shared.show() }
        Button("Pair New Device…") { PairingWindowController.shared.show() }
            .keyboardShortcut("n")

        if model.devices.isEmpty {
            Button("No Paired Devices") {}.disabled(true)
        } else {
            Menu("Paired Devices") {
                ForEach(model.devices) { d in
                    Menu {
                        Text("Paired \(d.pairedAt.formatted(date: .abbreviated, time: .omitted))")
                        Divider()
                        Button("Remove “\(d.name)”") { model.remove(d) }
                    } label: {
                        Label(d.name, systemImage: "iphone")
                    }
                }
            }
        }

        Divider()

        if model.recentFiles.isEmpty {
            Button("No Recent Files") {}.disabled(true)
        } else {
            Section("Recent Files") {
                ForEach(model.recentFiles, id: \.self) { url in
                    Button { model.reveal(url) } label: {
                        Label { Text(verbatim: url.lastPathComponent) } icon: { Image(nsImage: fileIcon(url)) }
                    }
                }
                Button("Clear Recent Files") { model.clearRecent() }
            }
        }

        Divider()

        Button("Save to “\(model.saveDirName)”…") { model.chooseSaveFolder() }
        Button("Open Save Folder") { model.openSaveFolder() }
        Toggle("Launch at Login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))

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

// MARK: - Activation policy

/// Regular app (Dock icon) while any ATA window is open, agent app otherwise. See `AppDelegate`.
@MainActor
enum ActivationPolicy {
    static func windowWillShow() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
    }

    static func windowDidClose(_ closing: NSWindow) {
        DispatchQueue.main.async {
            let others = NSApp.windows.contains { $0 !== closing && $0.isVisible && $0.styleMask.contains(.titled) && $0.level == .normal }
            if !others, NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
        }
    }
}

// MARK: - Pairing window

/// AppKit-owned window so nothing opens at launch and the window can be brought to front from a menu bar app.
@MainActor
final class PairingWindowController: NSObject, NSWindowDelegate {
    static let shared = PairingWindowController()
    private var window: NSWindow?

    func show() {
        let model = AppModel.shared
        if model.pairing == nil || model.pairing?.phase != .waiting { model.beginPairing() }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 480),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = String(localized: "Pair New Device")
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
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func header(_ p: PairingUIState) -> some View {
        VStack(spacing: 6) {
            Text("Pair a Phone").font(.title2.weight(.semibold))
            Text("Open ATA on your Android phone and scan this code.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
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
                        Text("Waiting for phone · expires in \(left / 60):\(String(format: "%02d", left % 60))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            case .success(let name):
                Text("Paired with \(name)").font(.headline)
            case .failed(let reason):
                VStack(spacing: 4) {
                    Text("Pairing failed").font(.headline)
                    Text(verbatim: Self.explain(reason)).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            case .expired:
                Text("This code has expired").font(.headline)
            }
            HStack {
                if p.phase != .waiting, !isSuccess(p.phase) {
                    Button("New Code") { model.beginPairing() }
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

    static func explain(_ reason: String) -> String {
        switch reason {
        case "bad_mac": return String(localized: "The phone's response didn't match this code. Scan the code again.")
        case "pairing_expired": return String(localized: "The code was no longer valid.")
        default: return reason
        }
    }
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
