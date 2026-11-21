import XCTest
@testable import OmniTrans

// MARK: - SecretStore v2 本地加密存储

final class SecretStoreTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecretStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func permissions(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? nil
    }

    func testRoundTrip() {
        let store = SecretStore(directory: dir)
        let id = UUID()
        store.saveFields(.init(apiKey: "sk-1", apiSecret: "", customRegion: "cn"), for: id)

        let loaded = store.batchReadAll()
        XCTAssertEqual(loaded[id]?.apiKey, "sk-1")
        XCTAssertEqual(loaded[id]?.customRegion, "cn")
    }

    func testPersistenceAcrossInstances() {
        let id = UUID()
        SecretStore(directory: dir).saveFields(.init(apiKey: "sk-2"), for: id)

        let loaded = SecretStore(directory: dir).batchReadAll()
        XCTAssertEqual(loaded[id]?.apiKey, "sk-2")
    }

    func testDeleteAndEmptySave() {
        let store = SecretStore(directory: dir)
        let a = UUID(), b = UUID()
        store.saveFields(.init(apiKey: "a"), for: a)
        store.saveFields(.init(apiKey: "b"), for: b)

        store.deleteAllFields(for: a)
        store.saveFields(.init(), for: b)   // 空字段等同删除

        XCTAssertTrue(store.batchReadAll().isEmpty)
    }

    /// 主密钥与密文文件均为 0600，主密钥 32 字节（README 安全边界的前提）。
    func testFilePermissionsAndKeySize() throws {
        let store = SecretStore(directory: dir)
        store.saveFields(.init(apiKey: "x"), for: UUID())

        let keyURL = dir.appendingPathComponent(".master.key")
        let v2URL = dir.appendingPathComponent("secrets.v2.json")
        XCTAssertEqual(try Data(contentsOf: keyURL).count, 32)
        XCTAssertEqual(permissions(keyURL), 0o600)
        XCTAssertEqual(permissions(v2URL), 0o600)
    }

    /// 密文损坏/主密钥丢失 → 返回空表，不崩溃、不弹窗。
    func testCorruptCiphertextReturnsEmpty() throws {
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: dir.appendingPathComponent("secrets.v2.json"))
        XCTAssertTrue(SecretStore(directory: dir).batchReadAll().isEmpty)
    }

    /// 主密钥被替换 → 无法解密旧密文 → 按空处理。
    func testWrongMasterKeyReturnsEmpty() throws {
        let id = UUID()
        SecretStore(directory: dir).saveFields(.init(apiKey: "sk"), for: id)

        var random = Data(count: 32)
        _ = random.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        try random.write(to: dir.appendingPathComponent(".master.key"))

        XCTAssertTrue(SecretStore(directory: dir).batchReadAll().isEmpty)
    }

    /// v1（机器 UUID 派生密钥）自动迁移到 v2：数据保留、旧文件删除。
    func testLegacyV1Migration() throws {
        let id = UUID()
        let map: [String: SecretFields] = [id.uuidString: .init(apiKey: "old-key", customRegion: "cn")]
        let plain = try JSONEncoder().encode(map)
        let legacyData = try SecretStore.LegacyV1.encrypt(plain)
        try legacyData.write(to: dir.appendingPathComponent("secrets.json"))

        let store = SecretStore(directory: dir)
        let loaded = store.batchReadAll()
        XCTAssertEqual(loaded[id]?.apiKey, "old-key")
        XCTAssertEqual(loaded[id]?.customRegion, "cn")

        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("secrets.json").path))
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("secrets.v2.json").path))
    }

    /// v1 文件无法解密（换机器/损坏）→ 返回空，不阻塞启动。
    func testUndecryptableLegacyV1IsIgnored() throws {
        try Data(repeating: 0xAA, count: 64).write(to: dir.appendingPathComponent("secrets.json"))
        XCTAssertTrue(SecretStore(directory: dir).batchReadAll().isEmpty)
    }
}