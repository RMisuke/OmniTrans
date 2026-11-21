import Foundation
import CryptoKit
import os
import Security

// MARK: - Secret Fields

struct SecretFields: Codable, Equatable {
    var apiKey: String       = ""
    var apiSecret: String    = ""
    var customRegion: String = ""

    var isEmpty: Bool { apiKey.isEmpty && apiSecret.isEmpty && customRegion.isEmpty }
}

enum SecretStoreError: LocalizedError {
    case keyGenerationFailed
    case encryptionFailed
    case decryptionFailed

    var errorDescription: String? {
        switch self {
        case .keyGenerationFailed: return "主密钥生成失败"
        case .encryptionFailed:    return "加密失败"
        case .decryptionFailed:    return "解密失败"
        }
    }
}

// MARK: - SecretStore（v2 本地加密存储）

/// 本地加密密钥存储（2026-11 重构，替代系统钥匙串方案）。
///
/// ## 设计（轻量、零弹窗）
/// - **主密钥**：随机 32 字节（`SecRandomCopyBytes`），存 `同目录/.master.key`（0600）。
///   不再依赖 IOPlatformUUID（换主板不再丢密钥），不再访问系统钥匙串（无授权弹窗）。
/// - **密文**：整表 `[UUID: SecretFields]` 编码为 JSON 后 AES-256-GCM 单密文块，
///   存 `secrets.v2.json`（0600）。每次保存生成新 nonce + 原子写；
///   读改写由实例内锁串行化。
/// - **迁移**：旧 v1 `secrets.json`（IOPlatformUUID 派生密钥 + 分格式）首次访问时
///   自动解密 → 用主密钥重加密为 v2 → 删除 v1 文件。一次性、无感。
///   钥匙串中的存量数据**不自动读取**（读取会触发系统弹窗，正是要消灭的行为）。
///
/// ## 安全边界（诚实声明）
/// 主密钥与密文同目录：可防「配置文件被误传/云备份泄漏/其他用户账户/未解锁磁盘」；
/// **不防同账户下的恶意进程**。静态加密依赖 FileVault（见 README）。
final class SecretStore: @unchecked Sendable {
    static let shared = SecretStore(directory: StoragePaths.appSupportDir)

    private static let log_ = OSLog(subsystem: AppLogging.subsystem, category: "Secrets")

    private static let v2FileName = "secrets.v2.json"
    private static let legacyFileName = "secrets.json"
    private static let masterKeyFileName = ".master.key"

    private struct State {
        var cache: [UUID: SecretFields]?
    }
    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let keyLock = OSAllocatedUnfairLock<SymmetricKey?>(initialState: nil)

    private let directory: URL
    private var fileURL: URL { directory.appendingPathComponent(Self.v2FileName) }
    private var legacyFileURL: URL { directory.appendingPathComponent(Self.legacyFileName) }
    private var masterKeyURL: URL { directory.appendingPathComponent(Self.masterKeyFileName) }

    init(directory: URL) {
        self.directory = directory
    }

    // MARK: - Public API

    func batchReadAll() -> [UUID: SecretFields] {
        lock.withLock { state in
            if let cache = state.cache { return cache }
            let loaded = loadFromDisk()
            state.cache = loaded
            return loaded
        }
    }

    func saveFields(_ fields: SecretFields, for providerID: UUID) {
        lock.withLock { state in
            var map = state.cache ?? loadFromDisk()
            if fields.isEmpty {
                map.removeValue(forKey: providerID)
            } else {
                map[providerID] = fields
            }
            state.cache = map
            persist(map)
        }
    }

    func deleteAllFields(for providerID: UUID) {
        lock.withLock { state in
            var map = state.cache ?? loadFromDisk()
            map.removeValue(forKey: providerID)
            state.cache = map
            persist(map)
        }
    }

    static func debugDump() {
        #if DEBUG
        let all = shared.batchReadAll()
        os_log(.debug, log: log_, "═══ Secrets (%d providers) ═══", all.count)
        for (id, f) in all {
            os_log(.debug, log: log_, "  [%{public}@] apiKey=%d chars secret=%d chars region=%{public}@",
                   id.uuidString, f.apiKey.count, f.apiSecret.count, f.customRegion)
        }
        #endif
    }

    // MARK: - Load / Persist（均在 lock 内同步调用，不得再取同锁）

    private func loadFromDisk() -> [UUID: SecretFields] {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            guard let data = try? Data(contentsOf: fileURL),
                  let map = decodeV2(data) else {
                os_log(.error, log: Self.log_, "v2 secrets decrypt failed — 主密钥丢失或文件损坏，按空处理")
                return [:]
            }
            return map
        }
        if FileManager.default.fileExists(atPath: legacyFileURL.path) {
            return migrateLegacyV1() ?? [:]
        }
        return [:]
    }

    private func decodeV2(_ combined: Data) -> [UUID: SecretFields]? {
        guard combined.count >= 28,
              let box = try? AES.GCM.SealedBox(combined: combined),
              let key = try? masterKey(),
              let plain = try? AES.GCM.open(box, using: key),
              let dict = try? JSONDecoder().decode([String: SecretFields].self, from: plain)
        else { return nil }
        var out: [UUID: SecretFields] = [:]
        for (k, v) in dict where UUID(uuidString: k) != nil {
            out[UUID(uuidString: k)!] = v
        }
        return out
    }

    @discardableResult
    private func persist(_ map: [UUID: SecretFields]) -> Bool {
        do {
            let dict = Dictionary(uniqueKeysWithValues: map.map { ($0.key.uuidString, $0.value) })
            let plain = try JSONEncoder().encode(dict)
            let sealed = try AES.GCM.seal(plain, using: masterKey())
            guard let combined = sealed.combined else { throw SecretStoreError.encryptionFailed }
            try ensureDirectory()
            try combined.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch {
            os_log(.error, log: Self.log_, "persist failed: %{public}@", error.localizedDescription)
            return false
        }
    }

    // MARK: - Master Key

    private func masterKey() throws -> SymmetricKey {
        if let k = keyLock.withLock({ $0 }) { return k }

        var key: SymmetricKey
        if let data = try? Data(contentsOf: masterKeyURL), data.count == 32 {
            key = SymmetricKey(data: data)
        } else {
            var bytes = Data(count: 32)
            let status = bytes.withUnsafeMutableBytes { buf in
                SecRandomCopyBytes(kSecRandomDefault, 32, buf.baseAddress!)
            }
            guard status == errSecSuccess else { throw SecretStoreError.keyGenerationFailed }
            try ensureDirectory()
            try bytes.write(to: masterKeyURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: masterKeyURL.path)
            key = SymmetricKey(data: bytes)
            os_log(.info, log: Self.log_, "generated new master key")
        }
        let resolved = key
        keyLock.withLock { $0 = resolved }
        return resolved
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 0700：仅当前用户可进入目录
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    // MARK: - v1 迁移

    private func migrateLegacyV1() -> [UUID: SecretFields]? {
        guard let data = try? Data(contentsOf: legacyFileURL),
              let map = LegacyV1.decode(data) else {
            os_log(.error, log: Self.log_, "legacy v1 secrets undecryptable — skipped")
            return nil
        }
        guard persist(map) else { return map }
        try? FileManager.default.removeItem(at: legacyFileURL)
        os_log(.info, log: Self.log_, "migrated %d secrets from v1 file", map.count)
        return map
    }

    /// v1 旧格式（机器 UUID 派生密钥）——仅供一次性迁移，不得用于新写入。
    enum LegacyV1 {
        static func key() throws -> SymmetricKey {
            guard let seed = platformUUID() else { throw SecretStoreError.keyGenerationFailed }
            let material = SymmetricKey(data: Data(seed.utf8))
            return HKDF<SHA256>.deriveKey(
                inputKeyMaterial: material,
                salt: Data("omnitrans.aes.salt.2026".utf8),
                info: Data("omnitrans-secrets-v1".utf8),
                outputByteCount: 32
            )
        }

        static func encrypt(_ plain: Data) throws -> Data {
            let sealed = try AES.GCM.seal(plain, using: key())
            guard let combined = sealed.combined else { throw SecretStoreError.encryptionFailed }
            return combined
        }

        static func decode(_ combined: Data) -> [UUID: SecretFields]? {
            guard combined.count >= 28,
                  let box = try? AES.GCM.SealedBox(combined: combined),
                  let key = try? key(),
                  let plain = try? AES.GCM.open(box, using: key),
                  let dict = try? JSONDecoder().decode([String: SecretFields].self, from: plain)
            else { return nil }
            var out: [UUID: SecretFields] = [:]
            for (k, v) in dict where UUID(uuidString: k) != nil {
                out[UUID(uuidString: k)!] = v
            }
            return out
        }

        private static func platformUUID() -> String? {
            let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
            defer { IOObjectRelease(s) }
            guard s != 0,
                  let prop = IORegistryEntryCreateCFProperty(s, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            else { return nil }
            return prop as? String
        }
    }
}