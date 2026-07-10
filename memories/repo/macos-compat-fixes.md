# macOS 兼容性修复记录 (v0.9)

## HotkeyManager 合并单事件处理器

**问题**: `register()`/`registerOCR()`/`registerReplace()` 各自调用 `InstallEventHandler()`，
只有最后一个 handler 生效，前两个被覆盖。

**修复**: 
- 新增模块级 `sharedHandlerRef: OSAllocatedUnfairLock<EventHandlerRef?>`，
  在模块初始化时一次性安装 `InstallEventHandler`
- C 回调 `unifiedHotkeyCallback` 改为使用 `HotkeyManager.shared` 直接访问，
  不再使用 `Unmanaged.fromOpaque(userData)`
- `unregister()`/`unregisterOCR()`/`unregisterReplace()` 只调用 
  `UnregisterEventHotKey`，不再调用 `RemoveEventHandler`
- 所有 `register()`/`registerOCR()`/`registerReplace()` 使用新的
  `registerHotKey(key:mods:id:ref:)` 辅助方法
- 增加 OSLog `logger` 提供 `log stream` 诊断

## SystemTranslationEngine 超时和诊断增强

**问题**:
- 3 秒超时对冷启动 ANE 模型加载不充足
- 无日志导致翻译失败难以排查

**修复**:
- `availabilityTimeout` 从 3s → 15s
- `translateTimeout` 新增 15s 常量
- 新增 `transLogger` (os_log) 记录：语言包查询开始/完成/耗时, 翻译开始/完成/耗时/失败/超时
- 新增 `translateTimedOutMessage` 用户友好提示信息
- 新增 `warmUp()` 静态方法 (fire-and-forget) 在应用启动时预热 Translation 框架
- `ResumeGate` actor 保持 Swift 6 并发安全

## 关键原则
- 所有 C 回调中通过 `HotkeyManager.shared` 直接引用，不使用 `userData` 指针
- 所有 `@available(macOS 26.0, *)` 保持声明，`MacOSNativeEngineAdapter` 中已有 `if #available` 运行时检测
- `VNDisableANE=1` 尚未处理为条件设置 — 后续需要在 OCR 诊断完成后再决定是否禁用 ANE
