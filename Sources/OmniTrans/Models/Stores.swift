import Foundation
import SwiftUI
import Observation
import Combine

// MARK: - Translation Session Store

/// 高频流式状态 — 隔离到专用 @Observable store，
/// 使 SwiftUI 字段级观察仅触发渲染翻译文本的视图局部 body 重算。
///
/// 仅需配置/供应商的视图应观察 `ConfigurationStore` 或 `AppState`。
@Observable
final class TranslationSessionStore {
    var translatedText: String = ""
    var isTranslating: Bool = false
    var streamingFinished: Bool = false
    var inputText: String = ""
    var showSuccessPulse: Bool = false
    var errorMessage: String? = nil
    var showErrorShake: Bool = false
    var showErrorPulse: Bool = false
    var isDictionaryMode: Bool = false
    var dictionaryEntry: DictionaryEntry? = nil
    var detectedIsWord: Bool = false
    var showPermissionHint: Bool = false
    var isFromLocalCache: Bool = false
    var cachedModelName: String = ""
    var cacheTimestamp: String = ""

    /// 最后一次成功解析的词典 JSON 字符串。
    /// 用于菜单栏 `TranslationView` 的「硬锁定」回退 —— 当流式尾帧
    /// 将 `translatedText` 覆盖为空/非 JSON 内容时，视图回退到此缓存值，
    /// 确保词典布局不会坍缩为空白区域。
    var lastValidDictionaryJson: String? = nil
}

// MARK: - Configuration Store

/// 设置型计算属性的缓存层。直接读写 UserDefaults，
/// 通过内存缓存消除翻译链路中的高频磁盘 I/O。
///
/// ## 性能设计
/// - 首次读取时从 UserDefaults 加载并缓存
/// - 写入时同步更新缓存 + UserDefaults
/// - 监听 `UserDefaults.didChangeNotification` 自动失效缓存
///   （其他进程/扩展修改设置时保持一致）
@Observable
final class ConfigurationStore {

    // MARK: - Cached Backing Properties

    private var _isContextAwareEnabled: Bool?
    private var _contextIntensity: Int?
    private var _isCacheEnabled: Bool?
    private var _isDictCacheEnabled: Bool?

    // MARK: - UserDefaults Keys

    private enum Key {
        static let contextAware   = "is_context_aware"
        static let contextIntensity = "context_intensity"
        static let cacheEnabled   = "cache_enabled"
        static let dictCacheEnabled = "dict_cache_enabled"
    }

    // MARK: - Cache Invalidation

    /// 使所有缓存失效（外部 UserDefaults 变更时调用）。
    func invalidateCache() {
        _isContextAwareEnabled = nil
        _contextIntensity = nil
        _isCacheEnabled = nil
        _isDictCacheEnabled = nil
    }

    // MARK: - Context Aware

    /// 上下文感知翻译开关。启用后，应用会在 LLM prompt 中注入
    /// 双向滑动窗口上下文，提升代词消解、术语一致性和语气连贯性。
    var isContextAwareEnabled: Bool {
        get {
            if let cached = _isContextAwareEnabled { return cached }
            let value = UserDefaults.standard.bool(forKey: Key.contextAware)
            _isContextAwareEnabled = value
            return value
        }
        set {
            _isContextAwareEnabled = newValue
            UserDefaults.standard.set(newValue, forKey: Key.contextAware)
        }
    }

    /// 上下文强度等级 (0–4)。控制滑动窗口捕获半径：
    ///   0 → 100, 1 → 200, 2 → 300 (默认), 3 → 400, 4 → 500 字符。
    /// 更高等级提升术语准确度但增加 Token 消耗。
    var contextIntensity: Int {
        get {
            if let cached = _contextIntensity { return cached }
            let value = UserDefaults.standard.integer(forKey: Key.contextIntensity)
            _contextIntensity = value
            return value
        }
        set {
            let clamped = max(0, min(4, newValue))
            _contextIntensity = clamped
            UserDefaults.standard.set(clamped, forKey: Key.contextIntensity)
        }
    }

    // MARK: - Cache Toggles

    /// 翻译缓存开关。关闭后每次翻译请求绕过内存缓存，直接访问网络/引擎。
    var isCacheEnabled: Bool {
        get {
            if let cached = _isCacheEnabled { return cached }
            let value = UserDefaults.standard.bool(forKey: Key.cacheEnabled)
            _isCacheEnabled = value
            return value
        }
        set {
            _isCacheEnabled = newValue
            UserDefaults.standard.set(newValue, forKey: Key.cacheEnabled)
        }
    }

    /// 本地词典缓存开关。启用后词典查询优先检查 SQLite 数据库，
    /// 仅在未命中时调用 LLM API。条目写入后永久保留。
    var isDictCacheEnabled: Bool {
        get {
            if let cached = _isDictCacheEnabled { return cached }
            let value = UserDefaults.standard.bool(forKey: Key.dictCacheEnabled)
            _isDictCacheEnabled = value
            return value
        }
        set {
            _isDictCacheEnabled = newValue
            UserDefaults.standard.set(newValue, forKey: Key.dictCacheEnabled)
        }
    }

    // MARK: - Derived Properties

    /// 上下文捕获字符上限，由 `contextIntensity` 派生。
    /// 委托 `ContextAwareService` —— intensity→字符映射的唯一来源。
    var contextCharLimit: Int {
        ContextAwareService.contextCharLimit
    }

    // MARK: - Defaults Registration

    /// 注册所有默认值（仅需在 App 启动时调用一次）。
    /// `register(defaults:)` 仅设置从未写入过的值，重复调用无害但浪费。
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.contextAware:     true,
            Key.contextIntensity: 2,
            Key.cacheEnabled:     true,
            Key.dictCacheEnabled: true,
            "hotkeys_enabled":    true,
        ])
    }
}

// MARK: - Legacy Aliases

/// 保留类型别名以兼容现有 `@Observable` 用法。
typealias UIStateStore = TranslationSessionStore
