import Foundation

/// Sorts the technical error string of an ended session into the few cases the app explains to the user in plain
/// words (TERMS.md). The app picks the sentence; this only decides which one, so it can be unit tested.
public enum TransferErrorKind: Equatable, Sendable {
    case cancelled
    case phoneStopped
    case deviceRemoved
    case timedOut
    /// The phone and the Mac could not reach each other: not on a network that connects them (different Wi-Fi,
    /// guest network, client isolation). Raised by the Mac's WebRTC receiver ("WebRTC transfer failed: …") or
    /// reported by the phone in `bye` ("no_path").
    case noPath
    case other

    public static func classify(_ error: String) -> TransferErrorKind {
        switch error {
        case "cancelled": return .cancelled
        case "phone disconnected", "phone ended the session before the transfer finished": return .phoneStopped
        case "device removed": return .deviceRemoved
        case "no_path", "hotspot_failed": return .noPath
        default:
            if error.hasPrefix("timed out") { return .timedOut }
            if error.hasPrefix("WebRTC transfer failed:") { return .noPath }
            return .other
        }
    }
}
