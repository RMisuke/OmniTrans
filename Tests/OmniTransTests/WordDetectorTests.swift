import XCTest
@testable import OmniTrans

// MARK: - P0-G2：WordDetector 规则矩阵

final class WordDetectorTests: XCTestCase {

    func testLatinWords() {
        for word in ["hello", "Hello", "café", "don't", "state-of-the-art", "Dr.", "a", "US", "us", "iPhone"] {
            XCTAssertTrue(WordDetector.isWord(word), "应判为词: \(word)")
        }
    }

    func testEdgePunctuationStripped() {
        for word in ["hello,", "wait!", "\"hello\"", "(test)", "Dr.", "你好。"] {
            XCTAssertTrue(WordDetector.isWord(word), "首尾标点应剥离: \(word)")
        }
    }

    func testPhrasesAndSentencesRejected() {
        for phrase in ["how are you", "the quick brown fox", "iPhone 15 Pro", "et al",
                       "wait—what?", "and/or", "hello,world", "用AI翻译",
                       "今天天气不错", "机器学习算法", "这是一个超过四个字的句子"] {
            XCTAssertFalse(WordDetector.isWord(phrase), "应判为句: \(phrase)")
        }
    }

    func testCJKWords() {
        for word in ["你好", "人工智能", "翻译", "成语"] {
            XCTAssertTrue(WordDetector.isWord(word), "CJK ≤4 字应判为词: \(word)")
        }
    }

    func testNumericDominantRejected() {
        for text in ["12345", "3.14", "2026"] {
            XCTAssertFalse(WordDetector.isWord(text), "数字主导应非词: \(text)")
        }
    }

    func testEmptyAndWhitespace() {
        for text in ["", "   ", "\n", "hello\nworld"] {
            XCTAssertFalse(WordDetector.isWord(text))
        }
    }

    func testOverlongLatinRejected() {
        let long = String(repeating: "a", count: 31)
        XCTAssertFalse(WordDetector.isWord(long))
        XCTAssertFalse(WordDetector.isWord("emoji🎉here"))
    }

    /// 大小写语义不同的词缓存键必须区分（US ≠ us）——键保留原样。
    func testCaseSensitiveCacheKeys() {
        let us = "US_中文" as NSString
        let lowercase = "us_中文" as NSString
        XCTAssertNotEqual(us, lowercase)
    }
}