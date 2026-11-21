import XCTest
@testable import OmniTrans

// MARK: - P1：流式解析纯函数

final class SSEParserTests: XCTestCase {

    private func payload(_ line: String) -> String? {
        SSELineParser.jsonPayload(fromSSELine: line).flatMap { String(data: $0, encoding: .utf8) }
    }

    func testStandardDataLine() {
        XCTAssertEqual(payload(#"data: {"a":1}"#), #"{"a":1}"#)
    }

    /// 兼容无空格的 `data:{…}`（旧实现丢块）。
    func testNoSpaceDataLine() {
        XCTAssertEqual(payload(#"data:{"a":1}"#), #"{"a":1}"#)
    }

    func testDoneMarkerFiltered() {
        XCTAssertNil(payload("data: [DONE]"))
    }

    func testEventLineIgnored() {
        XCTAssertNil(payload("event: message_start"))
    }

    func testEmptyPayloadIgnored() {
        XCTAssertNil(payload("data: "))
        XCTAssertNil(payload("data:"))
    }
}

// MARK: - P1：双源合并纯函数

final class DictionaryMergeTests: XCTestCase {

    private func aiEntry(phonetic: String = "", inflections: [DictionaryEntry.Inflection] = []) -> DictionaryEntry {
        DictionaryEntry(
            isWord: true, word: "hello", phonetic: phonetic, phoneticVariants: nil,
            definitions: [.init(pos: "int.", posLabel: nil, senseNumber: nil, labels: nil, meaning: "你好")],
            examples: [], inflections: inflections
        )
    }

    private func nativeEntry() -> DictionaryEntry {
        DictionaryEntry(
            isWord: true, word: "hello", phonetic: "/həˈloʊ/",
            phoneticVariants: [.init(type: "BrE", value: "/həˈləʊ/")],
            definitions: [.init(pos: "—", posLabel: nil, senseNumber: nil, labels: nil, meaning: "系统释义")],
            examples: [],
            inflections: [.init(form: "hellos", label: "复数")]
        )
    }

    func testNativeMissingReturnsAIUnchanged() {
        let ai = aiEntry()
        let missing = DictionaryEntry.empty(for: "hello")
        XCTAssertEqual(AppState.merged(ai: ai, native: missing), ai)
    }

    func testNativeFillsPhoneticAndInflections() {
        let merged = AppState.merged(ai: aiEntry(), native: nativeEntry())
        XCTAssertEqual(merged.phonetic, "/həˈloʊ/")
        XCTAssertEqual(merged.phoneticVariants?.first?.type, "BrE")
        XCTAssertEqual(merged.inflections.first?.form, "hellos")
        // 释义以 AI 为准
        XCTAssertEqual(merged.definitions.first?.meaning, "你好")
    }

    func testAIValuesWinWhenPresent() {
        let merged = AppState.merged(ai: aiEntry(phonetic: "/AI/"), native: nativeEntry())
        XCTAssertEqual(merged.phonetic, "/AI/")
    }
}

// MARK: - P1：WordDetector 归一化边界

final class WordDetectorNormalizationTests: XCTestCase {

    /// NFD 组合字符（café 分解形式）应判为词。
    func testNFDCombiningCharacter() {
        XCTAssertTrue(WordDetector.isWord("cafe\u{301}"))
    }

    /// 弯引号 don’t（U+2019）应判为词。
    func testCurlyApostrophe() {
        XCTAssertTrue(WordDetector.isWord("don’t"))
    }

    /// CJK 扩展 B 区汉字不应被归类为拉丁（混合判定）。
    func testCJKExtensionBCharacter() {
        XCTAssertTrue(WordDetector.isWord("\u{20000}"))
    }
}