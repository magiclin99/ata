import Foundation
import Security
import SystemConfiguration

// MARK: - Identity (SPEC §2)

public enum DeviceIdentity {
    static let defaultsKey = "deviceId"

    /// Loads the 16-byte deviceId from UserDefaults, generating it on first launch.
    public static func loadOrCreate(defaults: UserDefaults = .standard) -> Data {
        if let s = defaults.string(forKey: defaultsKey), let d = Hex.decode(s), d.count == 16 { return d }
        let d = randomBytes(16)
        defaults.set(Hex.encode(d), forKey: defaultsKey)
        return d
    }

    public static func computerName() -> String {
        if let n = SCDynamicStoreCopyComputerName(nil, nil) as String?, !n.isEmpty { return n }
        return ProcessInfo.processInfo.hostName
    }
}

// MARK: - Pairing offer (the QR code)

public struct PairingOffer {
    public static let lifetime: TimeInterval = 5 * 60

    public let k: Data
    public let createdAt: Date
    public let expiresAt: Date
    public var used = false

    public init(k: Data = randomBytes(32), now: Date = Date(), lifetime: TimeInterval = PairingOffer.lifetime) {
        self.k = k
        createdAt = now
        expiresAt = now.addingTimeInterval(lifetime)
    }

    public func isValid(at now: Date = Date()) -> Bool { !used && now < expiresAt }

    /// `ata://pair?v=2&id=<macId hex>&name=<URL-encoded name>&k=<base64url, no padding>`
    public func uri(macId: Data, macName: String) -> String {
        "ata://pair?v=2&id=\(Hex.encode(macId))&name=\(Self.percentEncode(macName))&k=\(Base64URL.encode(k))"
    }

    /// RFC 3986 percent-encoding of UTF-8 bytes; only unreserved characters (A–Z a–z 0–9 - . _ ~) stay literal,
    /// so a space is %20 (never '+').
    public static func percentEncode(_ s: String) -> String {
        var allowed = CharacterSet()
        allowed.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    public struct Parsed { public let macId: Data; public let name: String; public let k: Data }

    /// Parser used by the fake phone and tests.
    public static func parse(_ uri: String) -> Parsed? {
        guard let c = URLComponents(string: uri.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme == "ata", c.host == "pair" else { return nil }
        var q: [String: String] = [:]
        for item in c.queryItems ?? [] { q[item.name] = item.value ?? "" }
        guard q["v"] == "2", let id = q["id"].flatMap(Hex.decode), id.count == 16,
              let k = q["k"].flatMap(Base64URL.decode), k.count == 32 else { return nil }
        return Parsed(macId: id, name: q["name"] ?? "", k: k)
    }
}

// MARK: - Pairing store

public struct PairedDevice: Equatable, Identifiable {
    public var id: String { phoneId }
    public let phoneId: String      // 32 lowercase hex chars
    public var name: String
    public var pairedAt: Date

    public init(phoneId: String, name: String, pairedAt: Date) {
        self.phoneId = phoneId; self.name = name; self.pairedAt = pairedAt
    }
}

public protocol PairingStore: AnyObject {
    func devices() -> [PairedDevice]
    func key(for phoneId: String) -> Data?
    func save(_ device: PairedDevice, key: Data) throws
    func rename(phoneId: String, to name: String)
    func remove(phoneId: String)
}

public final class MemoryPairingStore: PairingStore {
    private var entries: [String: (PairedDevice, Data)] = [:]
    private let lock = NSLock()
    public init() {}
    public func devices() -> [PairedDevice] {
        lock.lock(); defer { lock.unlock() }
        return entries.values.map(\.0).sorted { $0.pairedAt < $1.pairedAt }
    }
    public func key(for phoneId: String) -> Data? { lock.lock(); defer { lock.unlock() }; return entries[phoneId]?.1 }
    public func save(_ device: PairedDevice, key: Data) throws { lock.lock(); defer { lock.unlock() }; entries[device.phoneId] = (device, key) }
    public func rename(phoneId: String, to name: String) {
        lock.lock(); defer { lock.unlock() }
        if var e = entries[phoneId] { e.0.name = name; entries[phoneId] = e }
    }
    public func remove(phoneId: String) { lock.lock(); defer { lock.unlock() }; entries[phoneId] = nil }
}

// MARK: - File store

/// Pairing keys in `~/Library/Application Support/io.github.magiclin99.ata.mac/pairings.json`.
///
/// Why not the Keychain: login-keychain items created by an app without an Apple Team ID are partitioned by the
/// exact build's cdhash, so every update would ask the user for their login password once per paired phone. ATA is
/// signed with a self-signed certificate (no Team ID), so the keys live in a file instead, protected by file
/// permissions: directory 0700, file 0600, readable by this user account only. A key only lets a nearby, already
/// paired phone send files to this Mac.
///
/// Format: `{"version":1,"devices":[{"phoneId","name","pairedAt" (seconds since 1970),"key" (base64)}]}`.
/// Writes are atomic (temp file created 0600 in the same directory, fsync, rename). Keys are never logged.
public final class FilePairingStore: PairingStore {
    public let url: URL
    private let lock = NSLock()
    private var entries: [String: (device: PairedDevice, key: Data)] = [:]

    public static func defaultURL(bundleId: String = "io.github.magiclin99.ata.mac") -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(bundleId, isDirectory: true).appendingPathComponent("pairings.json")
    }

    public init(url: URL = FilePairingStore.defaultURL()) {
        self.url = url
        load()
        // On every launch too, so a folder created by an older build (or restored) gets the flag.
        if FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) { excludeFromBackup() }
    }

    /// Pairing keys are per-Mac secrets: keep the folder out of Time Machine and other backups that honour
    /// the flag (a restored Mac simply pairs again).
    private func excludeFromBackup() {
        var dir = url.deletingLastPathComponent()
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        do { try dir.setResourceValues(v) } catch { Log.err("pairing store: cannot exclude folder from backup: \(error)") }
    }

    /// Whether the store's folder carries the "exclude from backup" flag (for tests and diagnostics).
    public var isExcludedFromBackup: Bool {
        var dir = url.deletingLastPathComponent()
        dir.removeAllCachedResourceValues()
        return (try? dir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup ?? false) ?? false
    }

    /// True when the file already exists (used to run the one-time Keychain import only on first use).
    public var fileExists: Bool { FileManager.default.fileExists(atPath: url.path) }

    private struct Entry: Codable { var phoneId: String; var name: String; var pairedAt: Double; var key: String }
    private struct FileFormat: Codable { var version: Int; var devices: [Entry] }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        guard let f = try? JSONDecoder().decode(FileFormat.self, from: data), f.version == 1 else {
            // Keep the unreadable file for inspection instead of silently overwriting it on the next save.
            let aside = url.appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: url, to: aside)
            Log.err("pairing store: \(url.lastPathComponent) is not readable; moved aside to \(aside.lastPathComponent)")
            return
        }
        for e in f.devices {
            guard let id = Hex.decode(e.phoneId), id.count == 16, let k = Data(base64Encoded: e.key), k.count == 32 else {
                Log.err("pairing store: skipping a malformed entry"); continue
            }
            let pid = Hex.encode(id)
            entries[pid] = (PairedDevice(phoneId: pid, name: e.name, pairedAt: Date(timeIntervalSince1970: e.pairedAt)), k)
        }
    }

    /// Caller holds `lock`.
    private func persist() throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        _ = chmod(dir.path, 0o700)
        excludeFromBackup()
        let f = FileFormat(version: 1, devices: entries.values.sorted { $0.device.pairedAt < $1.device.pairedAt }.map {
            Entry(phoneId: $0.device.phoneId, name: $0.device.name, pairedAt: $0.device.pairedAt.timeIntervalSince1970,
                  key: $0.key.base64EncodedString())
        })
        let enc = JSONEncoder()
        // No "\/" escaping, so base64 keys appear in the file verbatim, as documented.
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try enc.encode(f)

        let tmp = dir.appendingPathComponent(".pairings-\(Hex.encode(randomBytes(6))).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var ok = data.withUnsafeBytes { buf -> Bool in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
        ok = ok && fsync(fd) == 0
        close(fd)
        guard ok, Darwin.rename(tmp.path, url.path) == 0 else {
            let err = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            unlink(tmp.path)
            throw err
        }
    }

    public func devices() -> [PairedDevice] {
        lock.lock(); defer { lock.unlock() }
        return entries.values.map(\.device).sorted { $0.pairedAt < $1.pairedAt }
    }

    public func key(for phoneId: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return entries[phoneId.lowercased()]?.key
    }

    public func save(_ device: PairedDevice, key: Data) throws {
        lock.lock(); defer { lock.unlock() }
        let old = entries[device.phoneId]
        entries[device.phoneId] = (device, key)
        do { try persist() } catch {
            entries[device.phoneId] = old
            Log.err("pairing store: save failed: \(error)")
            throw error
        }
    }

    public func rename(phoneId: String, to name: String) {
        lock.lock(); defer { lock.unlock() }
        guard var e = entries[phoneId] else { return }
        e.device.name = name
        entries[phoneId] = e
        do { try persist() } catch { Log.err("pairing store: rename failed: \(error)") }
    }

    public func remove(phoneId: String) {
        lock.lock(); defer { lock.unlock() }
        guard entries.removeValue(forKey: phoneId) != nil else { return }
        do { try persist() } catch { Log.err("pairing store: remove failed: \(error)") }
    }

    /// Adds pairings that are not in the store yet (one-time import from the Keychain). Returns how many were added.
    @discardableResult
    public func importPairings(_ items: [(PairedDevice, Data)]) -> Int {
        lock.lock(); defer { lock.unlock() }
        var added = 0
        for (d, k) in items where entries[d.phoneId] == nil && k.count == 32 {
            entries[d.phoneId] = (d, k); added += 1
        }
        if added > 0 || !FileManager.default.fileExists(atPath: url.path) {
            do { try persist() } catch { Log.err("pairing store: import failed: \(error)") }
        }
        return added
    }
}

// MARK: - One-time Keychain import

/// Builds before 1.0 kept pairing keys as login-keychain generic passwords (service `<bundle id>.pairing`,
/// account = phoneId hex, label = phone name). This reads them once **without ever showing a prompt**: items whose
/// access list doesn't let this exact build read them silently are skipped (the phone has to pair again). Items that
/// were imported are then deleted from the Keychain.
public enum KeychainPairingImport {
    public static let services = ["io.github.magiclin99.ata.mac.pairing", "com.ata.mac.pairing"]

    public static func run(into store: FilePairingStore) {
        var found: [(PairedDevice, Data, String)] = []
        var skipped = 0
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(true) }
        for service in services {
            for d in list(service: service) {
                if let k = readKey(service: service, account: d.phoneId), k.count == 32 { found.append((d, k, service)) }
                else { skipped += 1 }
            }
        }
        let added = store.importPairings(found.map { ($0.0, $0.1) })
        for (d, _, service) in found { delete(service: service, account: d.phoneId) }
        if added > 0 || skipped > 0 {
            Log.info("pairing store: imported \(added) pairing(s) from the Keychain; \(skipped) could not be read without a prompt and were ignored")
        }
    }

    private static func list(service: String) -> [PairedDevice] {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecMatchLimit as String: kSecMatchLimitAll, kSecReturnAttributes as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { a in
            guard let acct = a[kSecAttrAccount as String] as? String, let id = Hex.decode(acct), id.count == 16 else { return nil }
            return PairedDevice(phoneId: Hex.encode(id), name: (a[kSecAttrLabel as String] as? String) ?? "Android phone",
                                pairedAt: (a[kSecAttrCreationDate as String] as? Date) ?? Date())
        }
    }

    private static func readKey(service: String, account: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecMatchLimit as String: kSecMatchLimitOne,
                                kSecReturnData as String: true,
                                kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    private static func delete(service: String, account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        let st = SecItemDelete(q as CFDictionary)
        if st != errSecSuccess && st != errSecItemNotFound { Log.info("pairing store: old Keychain item not deleted (\(st))") }
    }
}
