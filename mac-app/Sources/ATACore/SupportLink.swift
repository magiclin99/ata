import Foundation

/// Reserved "Support ATA…" entry (voluntary support, off until a URL is configured).
/// The URL comes from the `ATASupportURL` Info.plist string, empty by default. Only a well-formed https URL with a
/// host enables the entry; anything else (missing, empty, whitespace, other schemes, garbage) hides it.
/// Supporting never unlocks or changes anything in the app.
public enum SupportLink {
    public static let infoPlistKey = "ATASupportURL"

    public static func url(from value: Any?) -> URL? {
        guard let raw = value as? String else { return nil }
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(where: { $0.isWhitespace }),
              let c = URLComponents(string: s), c.scheme?.lowercased() == "https",
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil,
              let url = c.url else { return nil }
        return url
    }

    public static func url(in bundle: Bundle) -> URL? { url(from: bundle.object(forInfoDictionaryKey: infoPlistKey)) }
}
