import SwiftUI
import AppKit
import ATACore

/// The main window: the entry point that does not depend on the menu bar item (which macOS can hide when the menu
/// bar is full). Shown on re-open / second launch, on first launch while nothing is paired, and from the menu.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    static let shared = MainWindowController()
    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        AppModel.shared.pruneRecentFiles()
        AppModel.shared.refreshLaunchAtLogin()
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 820),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "ATA"
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("ATAMainWindow")
            w.contentMinSize = NSSize(width: 420, height: 460)
            w.contentView = NSHostingView(rootView: MainView(model: AppModel.shared))
            w.delegate = self
            if !w.setFrameUsingName("ATAMainWindow") { w.center() }
            window = w
        }
        AppModel.shared.ensureWelcomePairing()
        ActivationPolicy.windowWillShow()
        window?.makeKeyAndOrderFront(nil)
        Log.info("main window shown")
    }

    func windowWillClose(_ notification: Notification) {
        // Don't leave a pairing QR code valid while nobody is looking at it.
        if !PairingWindowController.shared.isVisible, AppModel.shared.pairing?.phase == .waiting { AppModel.shared.endPairing() }
        if AppModel.shared.justPairedPhone != nil { AppModel.shared.dismissJustPaired() }
        if let w = window { ActivationPolicy.windowDidClose(w) }
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var confirmRemove: PairedDevice?

    var body: some View {
        if model.needsMoveToApplications { moveToApplications } else { main }
    }

    /// Opened from the disk image or a download: one plain sentence, a button that shows ATA in Finder, Quit.
    private var moveToApplications: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            Text("Move ATA to Applications first").font(.title2.weight(.semibold))
            Text("Drag ATA into your Applications folder, then open it from there.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Quit ATA") { NSApp.terminate(nil) }
                Button("Show ATA in Finder") { model.revealAppForMoving() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(32)
        .frame(minWidth: 440, minHeight: 300)
    }

    private var main: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: "ATA").font(.title2.weight(.semibold))
                        Label(model.statusLine, systemImage: model.statusSymbol)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                bluetoothNotice
                if model.localNetworkBlocked {
                    HStack(alignment: .firstTextBaseline) {
                        Label("Your Mac's firewall is blocking your phone, so sending is slower.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("How to Fix…") { model.openFirewallHelp() }
                    }
                }
            }

            if let name = model.justPairedPhone {
                justPaired(name)
            } else if model.devices.isEmpty {
                welcome
            }

            if !model.recentFiles.isEmpty || !model.devices.isEmpty {
                Section {
                    if model.recentFiles.isEmpty {
                        Text("Nothing received yet. On your phone, share a photo or file and choose ATA.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.recentFiles, id: \.self) { url in
                            HStack {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
                                Text(verbatim: url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button("Show in Finder") { model.reveal(url) }
                            }
                        }
                    }
                } header: {
                    Text("Recently Received")
                } footer: {
                    HStack {
                        Text("Files are saved in “\(model.saveDirName)”.")
                        Spacer()
                        Button("Open Save Folder") { model.openSaveFolder() }
                        if !model.recentFiles.isEmpty {
                            Button("Clear List") { model.clearRecent() }
                        }
                    }
                    .font(.callout).foregroundStyle(.secondary)
                }
            }

            if !model.devices.isEmpty {
                Section("Paired Phones") {
                    ForEach(model.devices) { d in
                        HStack {
                            Label { Text(verbatim: d.name) } icon: { Image(systemName: "iphone") }
                            Spacer()
                            Text("Paired on \(d.pairedAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.callout).foregroundStyle(.secondary)
                            Button("Remove") { confirmRemove = d }
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Pair a Phone…") { PairingWindowController.shared.show() }
                            .keyboardShortcut("n")
                    }
                }
            }

            Section("Settings") {
                LabeledContent {
                    Button("Change…") { model.chooseSaveFolder() }
                } label: {
                    HStack(spacing: 6) {
                        Text("Save received files in")
                        Image(nsImage: NSWorkspace.shared.icon(forFile: model.saveDir.path)).resizable().frame(width: 16, height: 16)
                        Text(verbatim: model.saveDirName).foregroundStyle(.secondary)
                    }
                    .help(Text(verbatim: model.saveDir.path(percentEncoded: false)))
                }
                Toggle("Open at Login", isOn: Binding(get: { model.launchAtLogin }, set: { model.userSetLaunchAtLogin($0) }))
                Toggle(isOn: Binding(get: { model.showInDock }, set: { model.showInDock = $0 })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show ATA in the Dock")
                        Text("If you turn this off, ATA is only in the menu bar at the top of the screen.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                HStack {
                    Text("Version \(model.versionString)").foregroundStyle(.secondary)
                    Spacer()
                    if model.supportURL != nil {
                        Button("Support ATA…") { model.openSupport() }
                    }
                    Button("Check for Updates…") { model.checkForUpdates() }
                    Button("Quit ATA") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 440, minHeight: 460)
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } })) {
            Button("Remove", role: .destructive) { if let d = confirmRemove { model.remove(d) }; confirmRemove = nil }
            Button("Cancel", role: .cancel) { confirmRemove = nil }
        } message: {
            Text("To send from this phone again, you'll need to pair it again.")
        }
    }

    /// First launch (nothing paired): what ATA does, the pairing QR code right away (no button to find), a separate
    /// QR code for getting the Android app, and how to get this window back.
    private var welcome: some View {
        Section {
            VStack(spacing: 14) {
                VStack(spacing: 6) {
                    Text("Welcome to ATA").font(.title2.weight(.semibold))
                    Text("ATA lets you send photos and files from your Android phone to this Mac.")
                        .multilineTextAlignment(.center)
                }
                Text("On your phone, open ATA, tap “Pair with a Mac”, and scan this QR code.")
                    .font(.headline).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let p = model.pairing {
                    PairingQR(p: p, size: 220)
                    PairingStatus(model: model, p: p)
                } else {
                    ProgressView().frame(height: 220)
                }
                GetAndroidAppBox(model: model)
                Text("ATA keeps running in the background, even after you close this window. To see this window again, open ATA again, or click its icon in the Dock.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .onAppear { model.ensureWelcomePairing() }
        }
    }

    /// Right after the first pairing from the welcome: the result and the next steps, until "Done".
    private func justPaired(_ name: String) -> some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(.green)
                PairedNextSteps(model: model, name: name)
                Button("Done") { model.dismissJustPaired() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder private var bluetoothNotice: some View {
        if model.bluetoothNotAskedYet {
            Text("Your Mac will ask whether ATA can use Bluetooth. Click “Allow” so your phone can find this Mac. Without it, ATA can't receive files.")
                .fixedSize(horizontal: false, vertical: true)
        } else {
            switch model.bluetooth {
            case .unauthorized:
                VStack(alignment: .leading, spacing: 6) {
                    Text("To receive files, ATA needs Bluetooth. Open System Settings → Privacy & Security → Bluetooth, and turn on ATA.")
                        .fixedSize(horizontal: false, vertical: true)
                    HStack { Spacer(); Button("Open Bluetooth Permissions…") { model.openBluetoothPrivacySettings() } }
                }
            case .off:
                HStack {
                    Text("Turn on Bluetooth so your phone can find this Mac.")
                    Spacer()
                    Button("Open Bluetooth Settings…") { model.openBluetoothSettings() }
                }
            default:
                EmptyView()
            }
        }
    }

    private var confirmTitle: String {
        guard let d = confirmRemove else { return "" }
        return String(localized: "Remove “\(d.name)”?")
    }
}
