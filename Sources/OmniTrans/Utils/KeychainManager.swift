import Foundation
import CryptoKit

// MARK: - Keychain Errors

enum KeychainError: LocalizedError {
    case keyDerivationFailed(String)
    case encryptionFailed
    case decryptionFailed
    case ioError(String)

    var errorDescription: String? {
        switch self {
        case .keyDerivationFailed(let detail): return "密钥派生失败: \(detail)"
        case .encryptionFailed:                return "加密失败"
        case .decryptionFailed:                return "解密失败"
        case .ioError(let detail):             return "文件 I/O 错误: \(detail)"
        }
    }
}

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

    private static var fileURL: URL { StoragePaths.secretsFile }

    // MARK: - Crypto

    private static func deriveKey() throws -> SymmetricKey {
        guard let seed = platformSerial() else {
            throw KeychainError.keyDerivationFailed("IOPlatformUUID unavailable")
        }
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

    private static func encrypt(_ plain: Data) throws -> Data {
        let key = try deriveKey()
        let nonce = AES.GCM.Nonce()
        guard let sealed = try? AES.GCM.seal(plain, using: key, nonce: nonce) else {
            throw KeychainError.encryptionFailed
        }
        guard let combined = sealed.combined else { throw KeychainError.encryptionFailed }
        return combined  // nonce(12) + cipher + tag(16)
    }

    private static func decrypt(_ combined: Data) throws -> Data {
        guard combined.count >= 28 else { throw KeychainError.decryptionFailed }
        let key = try deriveKey()
        let nonceData = combined.prefix(12)
        let tagData   = combined.suffix(16)
        let cipherData = combined.dropFirst(12).dropLast(16)
        guard let nonce = try? AES.GCM.Nonce(data: nonceData),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: cipherData, tag: tagData),
              let plain = try? AES.GCM.open(box, using: key)
        else { throw KeychainError.decryptionFailed }
        return plain
    }

    // MARK: - Raw I/O

    private static func loadRawDict() throws -> [String: KeychainFields] {
        let encrypted = try Data(contentsOf: fileURL)
        let plain = try decrypt(encrypted)
        guard let dict = try? JSONDecoder().decode([String: KeychainFields].self, from: plain) else {
            return [:]
        }
        return dict
    }

    private static func saveRawDict(_ dict: [String: KeychainFields]) {
        do {
            let plain = try JSONEncoder().encode(dict)
            let encrypted = try encrypt(plain)
            try encrypted.write(to: fileURL, options: .atomic)
        } catch {
            log("❌ save failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Public API

    static func batchReadAll() -> [UUID: KeychainFields] {
        guard let raw = try? loadRawDict() else {
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
        var all = (try? loadRawDict()) ?? [:]
        all[providerID.uuidString] = fields
        saveRawDict(all)
        log("✅ saved \(providerID) → apiKey=\(fields.apiKey.prefix(6))...")
    }

    static func deleteAllFields(for providerID: UUID) {
        var all = (try? loadRawDict()) ?? [:]
        all.removeValue(forKey: providerID.uuidString)
        saveRawDict(all)
        log("🗑 deleted \(providerID)")
    }

    static func debugDump() {
        #if DEBUG
        let all = batchReadAll()
        log("═══ Secrets (\(all.count) providers) ═══")
        for (id, f) in all {
            log("  [\(id)] apiKey=\(f.apiKey.prefix(8))... secret=\(f.apiSecret.prefix(8))...")
        }
        log("════════════════════════════════")
        #endif
    }

    private static func log(_ msg: String) { print("[Secrets] \(msg)") }
}
