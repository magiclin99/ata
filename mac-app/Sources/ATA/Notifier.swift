import Foundation
import AppKit
import UserNotifications
import ATACore

/// Completion notifications. Permission is requested lazily on the first transfer; if it is denied, nothing is shown.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private var center: UNUserNotificationCenter? {
        // UNUserNotificationCenter requires a real app bundle.
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }
    private var asked = false

    override init() {
        super.init()
        center?.delegate = self
    }

    /// Result first, then where the files are (TERMS.md: a finished transfer reads like a result). Clicking the
    /// notification shows the first file in Finder.
    func transferEnded(_ s: SessionSummary, savedIn folder: String) {
        let n = s.saved.count
        let title: String
        var body: String
        let phone = s.phoneName
        if n > 0 {
            title = n == 1 ? String(localized: "1 file from “\(phone)”") : String(localized: "\(n) files from “\(phone)”")
            var names = ListFormatter.localizedString(byJoining: s.saved.prefix(3).map(\.lastPathComponent))
            if n > 3 { names = String(localized: "\(names) and \(n - 3) more") }
            body = String(localized: "Saved in “\(folder)”: \(names). Click to show in Finder.")
            if s.failedFiles > 0 { body += " " + AppModel.incompleteFiles(s.failedFiles) }
        } else if s.error == "cancelled" {
            title = String(localized: "Sending from “\(phone)” was cancelled")
            body = String(localized: "Nothing was saved. Send again whenever you're ready.")
        } else {
            title = String(localized: "Nothing arrived from “\(phone)”")
            if let e = s.error { body = AppModel.plainError(e) }
            else if s.failedFiles > 0 { body = AppModel.incompleteFiles(s.failedFiles) }
            else { body = String(localized: "Send again from your phone.") }
        }
        post(title: title, body: body, reveal: s.saved.first?.path)
    }

    /// SPEC §7c: ATA could not confirm the Mac went back to its own Wi-Fi after using a phone's hotspot.
    func wifiNotRestored() {
        post(title: String(localized: "Check your Mac's Wi-Fi"), body: AppModel.wifiNotRestoredText, reveal: nil)
    }

    private func post(title: String, body: String, reveal: String?) {
        guard let center else { return }
        let deliver = {
            let c = UNMutableNotificationContent()
            c.title = title
            c.body = body
            if let reveal { c.userInfo = ["reveal": reveal] }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)) { err in
                if let err { Log.info("notification not shown: \(err.localizedDescription)") }
            }
        }
        if asked { deliver(); return }
        asked = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, err in
            Log.info("notification permission: \(granted ? "granted" : "not granted")\(err.map { " (\($0.localizedDescription))" } ?? "")")
            if granted { deliver() }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let p = response.notification.request.content.userInfo["reveal"] as? String {
            let url = URL(fileURLWithPath: p)
            DispatchQueue.main.async {
                if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
        completionHandler()
    }
}
