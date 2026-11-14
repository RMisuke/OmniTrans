import XCTest
@testable import OmniTrans

// MARK: - 审计 S3 回归：Keychain 迁移判定

/// 全部成功才标记 done 并删旧文件；部分失败必须 done=false 保留文件以便重试。
/// 旧实现 defer 无条件置 true，覆盖失败分支的 set(false) → 永不重试、密钥静默丢失。
final class KeychainMigrationTests: XCTestCase {

    func testFullMigrationMarksDoneAndDeletesFile() {
        let outcome = KeychainManager.migrationOutcome(migrated: 3, total: 3)
        XCTAssertTrue(outcome.deleteFile)
        XCTAssertTrue(outcome.done)
    }

    func testPartialMigrationKeepsFileForRetry() {
        let outcome = KeychainManager.migrationOutcome(migrated: 1, total: 3)
        XCTAssertFalse(outcome.deleteFile)
        XCTAssertFalse(outcome.done)
    }

    func testZeroMigrationKeepsFileForRetry() {
        let outcome = KeychainManager.migrationOutcome(migrated: 0, total: 2)
        XCTAssertFalse(outcome.deleteFile)
        XCTAssertFalse(outcome.done)
    }
}