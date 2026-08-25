import Foundation
import CryptoKit
import os

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

// MARK: - Secret Storage (Keychain-first, encrypted-file fallback)

/// API 密钥安全存储，双后端（审计 S1）：
///
/// 1. **macOS Keychain（首选）** —— `SecItemAdd/Update/CopyMatching`，每个 provider
///    一条 GenericPassword（service=`com.omnitrans.secrets`，account=provider UUID），
///    由系统 `securityd` 保护，访问受代码签名约束。
/// 2. **加密文件回退** —— 旧方案：AES-256-GCM 加密 `secrets.json`，密钥由机器 UUID
///    派生。注意该方案的密钥材料（IOPlatformUUID）本机任意进程可读，仅具混淆强度；
///    仅在 Keychain 后端不可用时使用（如无签名标识的裸二进制环境）。
///
/// 进程启动后首次访问时做一次 Keychain 可用性探测（写入→读取→删除哨兵条目），
/// 探测通过即锁定 Keychain 后端并自动迁移旧文件数据；否则保持旧文件后端。
enum KeychainManager {

    private static var fileURL: URL { StoragePaths.secretsFile }

    /// Keychain service 标识（全部 provider 共用，以 account 区分）。
    private static let keychainService = "com.omnitrans.secrets"
    /// 迁移完成标记（UserDefaults）。
    private static let migrationDoneKey = "secrets_keychain_migration_done_v2"

    private static let log_ = OSLog(subsystem: AppLogging.subsystem, category: "Keychain")

    // MARK: - Backend Selection (resolved once per process)

    private enum Backend { case keychain, legacyFile }
    private static let backendLock = OSAllocatedUnfairLock<Backend?>(initialState: nil)

    /// 首次调用时探测 Keychain 是否可用（哨兵条目 round-trip），结果缓存于进程生命周期。
    private static func resolveBackend() -> Backend {
        backendLock.withLock { state in
            if let state { return state }

            let probeAccount = "com.omnitrans.keychain-probe"
            let probeData = Data("ok".utf8)
            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: probeAccount,
                kSecValueData as String: probeData,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]

            // 清理可能残留的哨兵条目，保证 round-trip 从干净状态开始
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: probeAccount,
            ] as CFDictionary)
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)

            var backend: Backend = .legacyFile
            if addStatus == errSecSuccess {
                // Round-trip 读验证
                var readQuery = [String: Any]()
                for (k, v) in addQuery { readQuery[k] = v }
                readQuery[kSecReturnData as String] = true
                readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
                var result: AnyObject?
                if SecItemCopyMatching(readQuery as CFDictionary, &result) == errSecSuccess,
                   (result as? Data) == probeData {
                    backend = .keychain
                }
            }

            // 探测完毕，移除哨兵条目
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: probeAccount,
            ] as CFDictionary)

            os_log(.info, log: log_, "secret storage backend resolved: %{public}@",
                   backend == .keychain ? "keychain" : "legacy-file")
            state = backend
            return backend
        }
    }

    // MARK: - Public API

    static func batchReadAll() -> [UUID: KeychainFields] {
        if resolveBackend() == .keychain {
            migrateLegacyFileIfNeeded()
            return readAllFromKeychain()
        }
        return legacyBatchReadAll()
    }

    static func saveFields(_ fields: KeychainFields, for providerID: UUID) {
        if resolveBackend() == .keychain {
            migrateLegacyFileIfNeeded()
            if upsertInKeychain(fields, for: providerID) {
                log("✅ saved \(providerID) → keychain (apiKey=\(fields.apiKey.prefix(6))...)")
                return
            }
            // Keychain 写入失败（罕见）—— 回退到文件后端保证不丢数据
            os_log(.error, log: log_, "keychain upsert failed for %{public}@ — falling back to file", providerID.uuidString)
        }
        legacySaveFields(fields, for: providerID)
        log("✅ saved \(providerID) → file (apiKey=\(fields.apiKey.prefix(6))...)")
    }

    static func deleteAllFields(for providerID: UUID) {
        if resolveBackend() == .keychain {
            migrateLegacyFileIfNeeded()
            deleteFromKeychain(for: providerID)
            log("🗑 deleted \(providerID) from keychain")
            return
        }
        legacyDeleteAllFields(for: providerID)
        log("🗑 deleted \(providerID) from file")
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

    // MARK: - Keychain Backend (SecItem)

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
    }

    private static func readAllFromKeychain() -> [UUID: KeychainFields] {
        var query = baseQuery(account: "") as [String: Any]
        query.removeValue(forKey: kSecAttrAccount as String)
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            if status != errSecItemNotFound {
                os_log(.error, log: log_, "keychain bulk read failed: %d", status)
            }
            return [:]
        }

        var out: [UUID: KeychainFields] = [:]
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let id = UUID(uuidString: account),
                  let data = item[kSecValueData as String] as? Data,
                  let fields = KeychainFields.decode(from: data)
            else { continue }
            out[id] = fields
        }
        os_log(.debug, log: log_, "📖 loaded %d secrets from keychain", out.count)
        return out
    }

    @discardableResult
    private static func upsertInKeychain(_ fields: KeychainFields, for id: UUID) -> Bool {
        guard let data = fields.encode() else { return false }
        let query = baseQuery(account: id.uuidString)
        let update = [kSecValueData as String: data] as [String: Any]

        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    @discardableResult
    private static func deleteFromKeychain(for id: UUID) -> Bool {
        SecItemDelete(baseQuery(account: id.uuidString) as CFDictionary) == errSecSuccess
    }

    // MARK: - Legacy File Migration

    /// 旧 `secrets.json` 存在且未迁移过 → 解密后逐条迁入 Keychain，成功则删除明文残留。
    private static func migrateLegacyFileIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: migrationDoneKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: migrationDoneKey) }

        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let legacy = legacyBatchReadAll()
        guard !legacy.isEmpty else {
            // 无法解密或空文件 —— 直接移除，避免每次启动重复尝试
            try? FileManager.default.removeItem(at: fileURL)
            return
        }

        var migrated = 0
        for (id, fields) in legacy where upsertInKeychain(fields, for: id) {
            migrated += 1
        }
        if migrated == legacy.count {
            try? FileManager.default.removeItem(at: fileURL)
            os_log(.info, log: log_, "migrated %d secrets from legacy file to keychain", migrated)
        } else {
            // 部分失败 —— 保留旧文件以便下次重试（迁移标记已被 defer 置位，
            // 但保留文件意味着数据仍可经 fallback 路径读取，不会丢失）
            UserDefaults.standard.set(false, forKey: migrationDoneKey)
            os_log(.error, log: log_, "migration incomplete (%d/%d) — legacy file kept", migrated, legacy.count)
        }
    }

    // MARK: - Legacy Encrypted-File Backend

    /// P3: 进程级密钥缓存 —— 机器 UUID 不变，派生密钥无需每次重新计算。
    /// `SymmetricKey` 是 `Sendable`，用 `OSAllocatedUnfairLock` 保护静态缓存。
    private static let cachedKeyLock = OSAllocatedUnfairLock(initialState: SymmetricKey?.none)

    private static func deriveKey() throws -> SymmetricKey {
        if let cached = cachedKeyLock.withLock({ $0 }) { return cached }
        guard let seed = platformSerial() else {
            throw KeychainError.keyDerivationFailed("IOPlatformUUID unavailable")
        }
        let material = SymmetricKey(data: Data(seed.utf8))
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: material,
            salt: Data("omnitrans.aes.salt.2026".utf8),
            info: Data("omnitrans-secrets-v1".utf8),
            outputByteCount: 32
        )
        cachedKeyLock.withLock { $0 = key }
        return key
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

    private static func loadRawDict() throws -> [String: KeychainFields] {
        let encrypted = try Data(contentsOf: fileURL)
        let plain = try decrypt(encrypted)
        guard let dict = try? JSONDecoder().decode([String: KeychainFields].self, from: plain) else {
            return [:]
        }
        return dict
    }

    /// 写入加密文件。审计 S2：显式收紧 POSIX 权限为 0600（owner-only 读写），
    /// 防止同机其它用户账户读取。
    private static func saveRawDict(_ dict: [String: KeychainFields]) {
        do {
            let plain = try JSONEncoder().encode(dict)
            let encrypted = try encrypt(plain)
            try encrypted.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            log("❌ save failed: \(error.localizedDescription)")
        }
    }

    private static func legacyBatchReadAll() -> [UUID: KeychainFields] {
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

    private static func legacySaveFields(_ fields: KeychainFields, for providerID: UUID) {
        var all = (try? loadRawDict()) ?? [:]
        all[providerID.uuidString] = fields
        saveRawDict(all)
    }

    private static func legacyDeleteAllFields(for providerID: UUID) {
        var all = (try? loadRawDict()) ?? [:]
        all.removeValue(forKey: providerID.uuidString)
        saveRawDict(all)
    }

    /// M8: print → OSLog（debug 级别，release 不持久化；subsystem 统一）。
    private static func log(_ msg: String) {
        os_log(.debug, log: log_, "%{public}@", msg)
    }
}
