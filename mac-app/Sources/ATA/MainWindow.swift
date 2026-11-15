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
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 700),
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
        ActivationPolicy.windowWillShow()
        window?.makeKeyAndOrderFront(nil)
        Log.info("main window shown")
    }

    func windowWillClose(_ notification: Notification) {
        if let w = window { ActivationPolicy.windowDidClose(w) }
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var confirmRemove: PairedDevice?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: "ATA").font(.title2.weight(.semibold))
                        Label(model.statusLine, systemImage: model.statusSymbol)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if case .unauthorized = model.bluetooth {
                    Button("Open Bluetooth Privacy Settings…") { model.openBluetoothSettings() }
                }
            } footer: {
                Text("ATA keeps running in the background after you close this window. To open it again, open ATA from the Applications folder or use the ATA icon in the menu bar.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Paired Devices") {
                if model.devices.isEmpty {
                    Text("No paired devices yet. Pair your Android phone to start receiving files.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.devices) { d in
                        HStack {
                            Label { Text(verbatim: d.name) } icon: { Image(systemName: "iphone") }
                            Spacer()
                            Text("Paired \(d.pairedAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.callout).foregroundStyle(.secondary)
                            Button("Remove") { confirmRemove = d }
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Pair New Device…") { PairingWindowController.shared.show() }
                        .keyboardShortcut("n")
                }
            }

            Section("Recent Files") {
                if model.recentFiles.isEmpty {
                    Text("No recent files").foregroundStyle(.secondary)
                } else {
                    ForEach(model.recentFiles, id: \.self) { url in
                        Button { model.reveal(url) } label: {
                            HStack {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
                                Text(verbatim: url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(Text("Show in Finder"))
                    }
                    HStack {
                        Spacer()
                        Button("Clear Recent Files") { model.clearRecent() }
                    }
                }
            }

            Section("Settings") {
                LabeledContent {
                    HStack {
                        Button("Change…") { model.chooseSaveFolder() }
                        Button("Open") { model.openSaveFolder() }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Save folder")
                        Text(verbatim: model.saveDir.path(percentEncoded: false))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Toggle("Launch at Login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
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
        .frame(minWidth: 420, minHeight: 460)
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } })) {
            Button("Remove", role: .destructive) { if let d = confirmRemove { model.remove(d) }; confirmRemove = nil }
            Button("Cancel", role: .cancel) { confirmRemove = nil }
        } message: {
            Text("The phone will have to be paired again before it can send files to this Mac.")
        }
    }

    private var confirmTitle: String {
        guard let d = confirmRemove else { return "" }
        return String(localized: "Remove “\(d.name)”?")
    }
}
