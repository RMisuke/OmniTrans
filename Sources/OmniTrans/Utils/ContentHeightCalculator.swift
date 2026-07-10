import Cocoa
import SwiftUI

// MARK: - Line Count Cache

/// NSCache 的 Sendable 包装器。
/// NSCache 是 Apple 官方线程安全的，但 Swift 6 无法推断其 Sendable 合规性。
final class LineCountCache: @unchecked Sendable {
    private let cache = NSCache<NSString, NSNumber>()

    func object(forKey key: NSString) -> NSNumber? { cache.object(forKey: key) }
    func setObject(_ obj: NSNumber, forKey key: NSString) { cache.setObject(obj, forKey: key) }
    func removeAllObjects() { cache.removeAllObjects() }
    var countLimit: Int {
        get { cache.countLimit }
        set { cache.countLimit = newValue }
    }
}

// MARK: - ContentHeightCalculator

/// 文本内容高度计算器 — 将高度计算逻辑从 `FloatingPanelContent` 中抽离。
///
/// `@MainActor` 保证 `NSCache`（非 Sendable）只在主线程访问，
/// 且所有方法均从 `FloatingPanelContent`（主线程上下文）调用。
@MainActor
///
/// ## 设计目标
/// - **可测试**：所有高度计算为纯函数，可单独验证每个分支。
/// - **命名常量**：消除 `12 + 34`、`1.15` 等魔法数字。
/// - **精确测量**：使用 `NSParagraphStyle` 替代经验系数。
/// - **缓存**：`lineCount` 带 `NSCache`，流式场景避免重复 `boundingRect`。
struct ContentHeightCalculator {

    // MARK: - Named Layout Constants

    /// 译文/词典卡片纵向内边距总和 = `.padding(AppTheme.spaceMD)` 上下共计。
    static let cardVerticalPadding: CGFloat = AppTheme.spaceMD * 2  // 34

    /// 译文/词典卡片底部额外余量（卡片下方到底部栏顶部的空间）。
    static let cardBottomMargin: CGFloat = 12

    /// 译文内容总固定余量 = 卡片内边距 + 底部余量。
    static let contentFixedMargin: CGFloat = cardVerticalPadding + cardBottomMargin  // 46

    /// 流式翻译时领先的行数（窗口始终比文本多显示 1 行）。
    static let streamingLeadLines: Int = 1

    /// 翻译完成时额外展示的行数。
    static let translationExtraLines: Int = 1

    // MARK: - Dependencies

    let bodyFontSize: CGFloat
    let layoutWidth: CGFloat
    let minHeight: CGFloat
    let maxHeight: CGFloat
    let chromeHeight: CGFloat

    // MARK: - Cache

    /// 行数计算结果缓存，避免流式场景下高频重复 `boundingRect`。
    /// key: `"\(text.hashValue)-\(layoutWidth)"`, value: 行数。
    private static let lineCountCache = LineCountCache()

    /// 缓存上限，防止长文本场景下无限膨胀。
    private static let cacheLimit = 200

    // MARK: - Font Metrics

    /// 正文单行高度（基于 `bodyFontSize` 的系统字体度量）。
    var lineHeight: CGFloat {
        let font = NSFont.systemFont(ofSize: bodyFontSize)
        return ceil(font.ascender + abs(font.descender) + font.leading)
    }

    // MARK: - Text Measurement

    /// 使用 `NSParagraphStyle` + `NSAttributedString` **精确**测量文本高度。
    ///
    /// 相比直接用 `lineCount * lh`，此方法：
    /// - 计入 `lineSpacing` 段落间距
    /// - 处理 Unicode 字符的 typographic 变体
    /// - 消除经验系数依赖（旧代码 `* 1.15`）
    ///
    /// - Parameters:
    ///   - text: 要测量的文本
    ///   - lineSpacing: 段落行间距，默认 4pt
    /// - Returns: 文本在 `layoutWidth` 下渲染的实际高度
    func accurateTextHeight(for text: String, lineSpacing: CGFloat = 4) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = lineSpacing
        let font = NSFont.systemFont(ofSize: bodyFontSize)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: ps
        ]
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: layoutWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs,
            context: nil
        )
        return rect.height
    }

    /// 带缓存的文本行数计算。
    ///
    /// - 使用 `NSCache` 在流式翻译期间缓存计算结果
    /// - 缓存 key 为文本 hash + 布局宽度，冲突概率极低
    /// - 缓存上限 200 条，防止长文本膨胀
    ///
    /// - Parameter text: 要计算行数的文本
    /// - Returns: 文本在 `layoutWidth` 下的行数
    func lineCount(for text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let key = "\(text.hashValue)-\(layoutWidth)" as NSString
        if let cached = Self.lineCountCache.object(forKey: key) {
            return cached.intValue
        }
        let h = accurateTextHeight(for: text)
        let lh = lineHeight
        let count = max(1, Int(ceil(h / lh)))

        // 缓存上限保护
        if Self.lineCountCache.countLimit < Self.cacheLimit {
            Self.lineCountCache.countLimit = Self.cacheLimit
        }
        Self.lineCountCache.setObject(NSNumber(value: count), forKey: key)
        return count
    }

    /// 清除行数缓存（当字号/宽度变化时调用）。
    static func clearCache() {
        lineCountCache.removeAllObjects()
    }

    // MARK: - Height Calculations

    /// **流式翻译中** — 窗口高度 = chrome + 固定余量 + (当前行数 + 1) × 行高。
    ///
    /// 窗口始终领先文本 1 行，给用户视觉预览空间。
    func streamingTargetHeight(currentText: String) -> CGFloat {
        let cur = lineCount(for: currentText)
        let lead = max(1, cur + Self.streamingLeadLines)
        let contentH = CGFloat(lead) * lineHeight + Self.contentFixedMargin
        return clamp(chromeHeight + contentH)
    }

    /// **翻译完成** — 窗口高度 = chrome + 固定余量 + (最终行数 + 1) × 行高。
    func translationTargetHeight(text: String) -> CGFloat {
        let lines = lineCount(for: text)
        let displayLines = max(1, lines + Self.translationExtraLines)
        let contentH = CGFloat(displayLines) * lineHeight + Self.contentFixedMargin
        return clamp(chromeHeight + contentH)
    }

    /// **词典模式** — 逐段精确测量词条/定义/例句，无需经验系数。
    func dictionaryTargetHeight(
        entry: DictionaryEntry,
        fromCache: Bool,
        modelName: String
    ) -> CGFloat {
        let lh = lineHeight
        var contentH: CGFloat = lh * 1.5  // 词条标题 + 音标

        // 定义段落：使用 accurateTextHeight 测量，无系数
        let defsText = entry.definitions.map(\.meaning).joined(separator: "\n")
        if !defsText.isEmpty {
            contentH += accurateTextHeight(for: defsText)
        }

        // 例句段落：使用 accurateTextHeight 测量，无系数
        let exText = entry.examples.map { "\($0.en) \($0.zh)" }.joined(separator: "\n")
        if !exText.isEmpty {
            contentH += accurateTextHeight(for: exText)
        }

        // 缓存来源信息行
        if fromCache && !modelName.isEmpty {
            contentH += lh * 1.5
        }

        // 底部固定余量
        contentH += Self.contentFixedMargin + lh

        return clamp(chromeHeight + contentH)
    }

    /// **历史/错误/空状态** — 恢复到动态模式默认最小高度。
    var defaultTargetHeight: CGFloat {
        return minHeight
    }

    // MARK: - Helpers

    private func clamp(_ value: CGFloat) -> CGFloat {
        max(minHeight, min(maxHeight, value))
    }
}


