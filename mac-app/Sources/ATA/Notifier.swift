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

    func transferEnded(_ s: SessionSummary) {
        let n = s.saved.count
        let title: String
        var body: String
        let phone = s.phoneName
        if n > 0 {
            title = n == 1 ? String(localized: "Received 1 file from \(phone)") : String(localized: "Received \(n) files from \(phone)")
            body = ListFormatter.localizedString(byJoining: s.saved.prefix(3).map(\.lastPathComponent))
            if n > 3 { body = String(localized: "\(body) and \(n - 3) more") }
            if s.failedFiles > 0 { body = String(localized: "\(body) — \(s.failedFiles) failed") }
        } else {
            title = String(localized: "Transfer from \(phone) failed")
            if let e = s.error { body = AppModel.localizedEngineError(e) }
            else if s.failedFiles > 0 { body = String(localized: "\(s.failedFiles) file(s) failed verification") }
            else { body = String(localized: "No files were received") }
        }
        post(title: title, body: body, reveal: s.saved.first?.path)
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
