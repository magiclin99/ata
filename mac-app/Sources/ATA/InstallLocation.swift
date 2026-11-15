import Foundation

/// Where ATA is running from. A non-technical person may open ATA straight from the disk image window, or from
/// Downloads; macOS then runs it from a read-only disk image or a temporary "translocated" copy, which disappears
/// when the disk image is ejected or the Mac restarts, so pairing and "open at login" would break.
enum InstallLocation {
    enum Problem: String {
        case translocated = "a translocated copy (opened from a download)"
        case diskImage = "a read-only volume (the disk image)"
    }

    /// nil when the location is fine.
    static func problem(bundleURL: URL = Bundle.main.bundleURL) -> Problem? {
        if bundleURL.path.contains("/AppTranslocation/") { return .translocated }
        let ro = (try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        if ro { return .diskImage }
        return nil
    }

    /// For a translocated copy, the original bundle (via the Security framework's SecTranslocate API, looked up at
    /// run time); otherwise the bundle itself.
    static func originalURL(bundleURL: URL = Bundle.main.bundleURL) -> URL? {
        guard bundleURL.path.contains("/AppTranslocation/") else { return bundleURL }
        typealias Fn = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard let h = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let sym = dlsym(h, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        let fn = unsafeBitCast(sym, to: Fn.self)
        return fn(bundleURL as CFURL, nil)?.takeRetainedValue() as URL?
    }
}
