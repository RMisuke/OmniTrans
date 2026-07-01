import Foundation
import CryptoKit

// MARK: - Keychain Fields

struct KeychainFields: Codable {
    var apiKey: String       = ""
    var apiSecret: String    = ""
    var customRegion: String = ""

    var isEmpty: Bool { apiKey.isEmpty && apiSecret.isEmpty && customRegion.isEmpty }
    func encode() -> Data? { try? JSONEncoder().encode(self) }
    static func decode(from data: Data) -> KeychainFields? {
        try? JSONDecoder().decode(KeychainFields.self, from: data)
    }
}

// MARK: - Secure File Storage

/// File-based encrypted secret storage at `~/Library/Application Support/OmniTrans/secrets.json`.
/// AES-256-GCM encryption keyed to the machine UUID so secrets are tied to this Mac.
/// No entitlements required — works with ad-hoc signed SwiftPM apps.
enum KeychainManager {

    private static let fileName = "secrets.json"
    private static var storageDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("OmniTrans")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static var fileURL: URL { storageDir.appendingPathComponent(fileName) }

    // MARK: - Crypto

    private static func deriveKey() -> SymmetricKey {
        let seed = platformSerial() ?? "omnitrans-fallback-uid"
        let material = SymmetricKey(data: Data(seed.utf8))
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: material,
            salt: Data("omnitrans.aes.salt.2026".utf8),
            info: Data("omnitrans-secrets-v1".utf8),
            outputByteCount: 32
        )
    }

    private static func platformSerial() -> String? {
        let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(s) }
        guard s != 0,
              let prop = IORegistryEntryCreateCFProperty(s, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        else { return nil }
        return prop as? String
    }

    private static func encrypt(_ plain: Data) -> Data? {
        let key = deriveKey()
        let nonce = AES.GCM.Nonce()
        guard let sealed = try? AES.GCM.seal(plain, using: key, nonce: nonce) else { return nil }
        return sealed.combined  // nonce(12) + cipher + tag(16)
    }

    private static func decrypt(_ combined: Data) -> Data? {
        guard combined.count >= 28 else { return nil }
        let key = deriveKey()
        let nonceData = combined.prefix(12)
        let tagData   = combined.suffix(16)
        let cipherData = combined.dropFirst(12).dropLast(16)
        guard let nonce = try? AES.GCM.Nonce(data: nonceData),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: cipherData, tag: tagData),
              let plain = try? AES.GCM.open(box, using: key)
        else { return nil }
        return plain
    }

    // MARK: - Raw I/O

    private static func loadRawDict() -> [String: KeychainFields]? {
        guard let encrypted = try? Data(contentsOf: fileURL),
              let plain = decrypt(encrypted),
              let dict = try? JSONDecoder().decode([String: KeychainFields].self, from: plain)
        else { return nil }
        return dict
    }

    private static func saveRawDict(_ dict: [String: KeychainFields]) {
        guard let plain = try? JSONEncoder().encode(dict),
              let encrypted = encrypt(plain)
        else { log("❌ encode/encrypt failed"); return }
        do {
            try encrypted.write(to: fileURL, options: .atomic)
        } catch {
            log("❌ file write failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Public API

    static func batchReadAll() -> [UUID: KeychainFields] {
        guard let raw = loadRawDict() else {
            log("no saved secrets (or decrypt failed)")
            return [:]
        }
        var result: [UUID: KeychainFields] = [:]
        for (key, fields) in raw {
            if let uuid = UUID(uuidString: key) { result[uuid] = fields }
        }
        log("📖 loaded \(result.count) secrets")
        return result
    }

    static func saveFields(_ fields: KeychainFields, for providerID: UUID) {
        var all = loadRawDict() ?? [:]
        all[providerID.uuidString] = fields
        saveRawDict(all)
        log("✅ saved \(providerID) → apiKey=\(fields.apiKey.prefix(6))...")
    }

    static func deleteAllFields(for providerID: UUID) {
        var all = loadRawDict() ?? [:]
        all.removeValue(forKey: providerID.uuidString)
        saveRawDict(all)
        log("🗑 deleted \(providerID)")
    }

    static func debugDump() {
        let all = batchReadAll()
        log("═══ Secrets (\(all.count) providers) ═══")
        for (id, f) in all {
            log("  [\(id)] apiKey=\(f.apiKey.prefix(8))... secret=\(f.apiSecret.prefix(8))...")
        }
        log("════════════════════════════════")
    }

    private static func log(_ msg: String) { print("[Secrets] \(msg)") }
}
