import XCTest
@testable import OmniTrans

// MARK: - P1-A：词典重构回归

final class DictionaryRefactorTests: XCTestCase {

    private func makeEntry() -> DictionaryEntry {
        DictionaryEntry(
            isWord: true, word: "hello", phonetic: "/həˈloʊ/",
            phoneticVariants: [.init(type: "BrE", value: "/həˈləʊ/")],
            definitions: [.init(pos: "int.", posLabel: nil, senseNumber: 1, labels: nil, meaning: "你好")],
            examples: [.init(en: "Hello, world", zh: "你好，世界")],
            inflections: []
        )
    }

    /// prompt 输出 `is_word`，解码必须识别（旧实现只认 isWord 靠 ?? true 掩盖）。
    func testParseSnakeCaseIsWord() throws {
        let json = #"{"is_word": false, "definitions": [{"pos": "—", "meaning": "未收录"}]}"#
        let entry = try XCTUnwrap(DictionaryEntry.parse(from: json, word: "x"))
        XCTAssertFalse(entry.isWord)
        XCTAssertEqual(entry.definitions.first?.meaning, "未收录")
    }

    func testParseCamelCaseIsWord() throws {
        let json = #"{"isWord": true, "definitions": [{"pos": "n.", "meaning": "问候"}]}"#
        let entry = try XCTUnwrap(DictionaryEntry.parse(from: json, word: "hello"))
        XCTAssertTrue(entry.isWord)
    }

    /// markdown 代码围栏包裹的 JSON 应被净化后解析。
    func testParseMarkdownFencedJSON() throws {
        let json = "```json\n{\"is_word\": true, \"definitions\": [{\"pos\": \"n.\", \"meaning\": \"问候\"}]}\n```"
        let entry = try XCTUnwrap(DictionaryEntry.parse(from: json, word: "hello"))
        XCTAssertEqual(entry.definitions.count, 1)
    }

    /// 复制/朗读完整词条（P1-A D8）。
    func testPlainTextIncludesAllFields() {
        let text = makeEntry().plainText
        XCTAssertTrue(text.contains("hello"))
        XCTAssertTrue(text.contains("/həˈloʊ/"))
        XCTAssertTrue(text.contains("你好"))
        XCTAssertTrue(text.contains("Hello, world"))
    }

    /// 历史统一存 entry JSON，召回解码必须往返一致（P1-A D7）。
    func testHistoryJSONRoundTrip() throws {
        let entry = makeEntry()
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(DictionaryEntry.self, from: data)
        XCTAssertEqual(decoded, entry)
    }
}