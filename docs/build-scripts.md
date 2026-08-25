# OmniTrans 构建脚本修复说明

> 版本: v0.9+ | 工具链: Xcode 27 Beta 3 / Swift 6.4 / macOS SDK 27.0 | 部署目标: macOS 14.0

---

## 1. 脚本清单与职责

| 脚本 | 架构 | 产物 | bundle id |
|---|---|---|---|
| [`build.sh`](../build.sh) | universal（arm64 + x86_64） | `.build/OmniTrans.app` | `com.omnitrans.app` |
| [`build-arm.sh`](../build-arm.sh) | arm64 | `.build/OmniTrans-arm64.app` | `com.omnitrans.arm64` |
| [`build-intel.sh`](../build-intel.sh) | x86_64（Intel） | `.build/OmniTrans-intel.app` | `com.omnitrans.intel` |
| [`scripts/omnitrans-build-common.sh`](../scripts/omnitrans-build-common.sh) | 共享环境（被上面三个脚本 source） | — | — |

产物结构与命名规则保持不变：`Contents/MacOS/OmniTrans` + `Contents/Resources/{icon.icns,menubar.icns}` + `Contents/Info.plist`，ad-hoc 签名，去除 quarantine。

---

## 2. 原问题与修复

### 2.1 工具链硬编码（三个脚本通病）

**问题**：`DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"` 硬编码在
`build.sh` / `build-arm.sh` 中；`build-intel.sh` 完全未设置，直接调用 `swift build`，
在 `xcode-select` 指向 Command Line Tools 时会触发 SwiftPM 构建系统错误
`spec '...' already registered`。

**修复**：新增共享函数 `omni_select_developer_dir()`，按优先级自动选择
`DEVELOPER_DIR`：显式设置 > Xcode-beta > Xcode > `xcode-select -p`（回退 CLT）。
三个脚本统一经 `source scripts/omnitrans-build-common.sh` 调用，兼容 Xcode 路径
变化（如升级为正式版 Xcode.app）与纯 CLT 环境。

### 2.2 SwiftPM 产物路径过时

**问题**：三个脚本硬编码 `BIN=".build/release/OmniTrans"` 或仅含
`.build/apple/Products/Release/OmniTrans`。SwiftPM 在 Xcode 27 / Swift 6.4 下把
release 产物输出到 **`.build/out/Products/Release/OmniTrans`**，旧路径不再命中。

**修复**：新增 `omni_resolve_release_binary()`，按
`.build/out/Products/Release` → `.build/apple/Products/Release` → `.build/release`
顺序探测真实产物；找不到时列出所有候选并退出。产物路径从此与工具链版本无关。

### 2.3 部署目标未显式声明

**问题**：脚本未设置 `MACOSX_DEPLOYMENT_TARGET`，仅依赖 Package.swift。

**修复**：common 统一 `export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"`
（与 Package.swift `platforms: [.macOS(.v14)]` 及 Info.plist `LSMinimumSystemVersion`
保持一致）。实测二进制 `LC_BUILD_VERSION.minos = 14.0`。

### 2.4 构建命令不统一 / 缺构建系统缓存标志

**问题**：`build.sh`/`build-arm.sh` 用 `xcrun swift build` + `--disable-build-manifest-caching`，
`build-intel.sh` 裸用 `swift build`。

**修复**：common 封装 `omni_swift_build_release()`，统一 `xcrun swift build -c release
--disable-build-manifest-caching [--arch ...]`。

### 2.5 Info.plist / 组装逻辑重复且不一致

**问题**：三处重复的 plist/签名/拷贝逻辑；`build-arm.sh` 含阿里云 ATS 例外，其余没有。

**修复**：common 提供 `omni_make_info_plist()`（统一含阿里云 ATS 例外，三个产物一致）
与 `omni_assemble_app()`（拷贝二进制、`strip`、图标、plist、`codesign`、`xattr -cr`）。

### 2.6 输出路径重复前缀

**问题**：`APP_DIR` 已含 `$OMNI_ROOT`，打印 `App: $OMNI_ROOT/$APP_DIR` 产生重复路径。

**修复**：三个脚本打印改为 `App: $APP_DIR`。

---

## 3. 验证结果（本机实测）

环境：Apple Silicon，`Xcode-beta.app`（Swift 6.4，macOS SDK 27.0），
`xcode-select` 指向 CommandLineTools。

| 脚本 | 构建结果 | 二进制 | 部署目标 | bundle id | 签名 |
|---|---|---|---|---|---|
| `build.sh` | ✅ Build complete | universal（arm64 + x86_64） | 14.0 | com.omnitrans.app | adhoc ✅ |
| `build-arm.sh` | ✅ Build complete | arm64 | 14.0 | com.omnitrans.arm64 | adhoc ✅ |
| `build-intel.sh` | ✅ Build complete | x86_64 | 14.0 | com.omnitrans.intel | adhoc ✅ |

- 三个脚本均无构建错误，产物结构、命名、部署目标、签名全部正确。
- 构建日志中的 `warning:` 全部来自**既有源码**的 Swift 6 严格并发告警
  （StrictConcurrency 实验特性下、Swift 5 模式仅告警不报错），与脚本无关；
  本次脚本修复未引入任何新警告。如需彻底消除，需另行处理源码并发隔离
  （属代码质量重构，不在构建脚本范畴）。

---

## 4. 使用说明

```bash
./build.sh          # 通用（universal）
./build-arm.sh      # 仅 arm64
./build-intel.sh    # 仅 x86_64（Intel）
```

- 可覆盖 `MACOSX_DEPLOYMENT_TARGET=15.0 ./build.sh` 调整部署目标。
- 可显式 `DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer ./build.sh` 指定工具链。
- 每次构建会清理 `.build/release .build/out .build/apple` 全量重编（保留原行为）。
