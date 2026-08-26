import XCTest
@testable import OmniTrans

/// 覆盖「竞速仲裁记忆」：连续英文胜出切换单轨、mixed 胜出立即回退竞速。
final class RacePolicyMemoryTests: XCTestCase {

    func testStartsInRaceMode() async {
        let policy = RacePolicyMemory()
        let solo = await policy.shouldRunEnglishSolo
        XCTAssertFalse(solo, "初始必须处于竞速模式")
    }

    func testConsecutiveEnglishWinsTriggerSoloMode() async {
        let policy = RacePolicyMemory()
        await policy.record(winner: .english)
        await policy.record(winner: .english)
        var solo = await policy.shouldRunEnglishSolo
        XCTAssertFalse(solo, "未达阈值仍应竞速")

        await policy.record(winner: .english)
        solo = await policy.shouldRunEnglishSolo
        XCTAssertTrue(solo, "连续 3 次 en 胜出后应切换单轨")
    }

    func testMixedWinImmediatelyResetsSoloMode() async {
        let policy = RacePolicyMemory()
        for _ in 0..<5 { await policy.record(winner: .english) }
        var solo = await policy.shouldRunEnglishSolo
        XCTAssertTrue(solo)

        await policy.record(winner: .mixed)
        solo = await policy.shouldRunEnglishSolo
        XCTAssertFalse(solo, "任何一次 mixed 胜出都应回到竞速模式")
    }

    func testReset() async {
        let policy = RacePolicyMemory()
        for _ in 0..<3 { await policy.record(winner: .english) }
        await policy.reset()
        let solo = await policy.shouldRunEnglishSolo
        XCTAssertFalse(solo)
    }

    func testLanguageTrackConfiguration() {
        XCTAssertEqual(LanguageTrack.english.languages, ["en-US"])
        XCTAssertEqual(LanguageTrack.mixed.languages, ["zh-Hans", "en-US"])
        // 语言列表刻意最小化：混排轨道不超过两种语言
        XCTAssertLessThanOrEqual(LanguageTrack.mixed.languages.count, 2)
    }
}
