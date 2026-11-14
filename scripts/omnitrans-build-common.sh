#!/bin/bash
# ============================================================================
# OmniTrans 共享构建环境（供 build.sh source）
#
# 职责：
#   1. 自动选择开发者目录（兼容 Xcode 路径变化 + Command Line Tools 环境）
#   2. 统一部署目标（MACOSX_DEPLOYMENT_TARGET，与 Package.swift platforms 一致）
#   3. 解析 SwiftPM release 产物路径（兼容 Xcode 27/Swift 6.4 等新旧布局）
#   4. 封装统一 Swift 构建命令（始终走 xcrun + DEVELOPER_DIR）
#   5. 生成最小 Info.plist（含阿里云 ATS 例外）
#   6. 组装 .app（拷贝二进制、strip、图标、Hardened Runtime 签名、去 quarantine）
#
# 被 source 后立即执行 omni_select_developer_dir。
# ============================================================================

set -euo pipefail

# ── 项目根目录（common 位于 scripts/ 下）──
OMNI_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$OMNI_ROOT"

# ── 1. 部署目标（默认 15.0，与 Package.swift platforms [.macOS(.v15)] 一致）──
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-15.0}"

# ── 2. 工具链选择 ──
# 优先级：显式 DEVELOPER_DIR > Xcode-beta > Xcode > xcode-select 默认（可能是 CLT）。
# 当 Command Line Tools 与 Xcode 27 beta 的 SwiftPM 组合触发 "spec already
# registered" 构建系统错误时，完整 Xcode 优先可自动规避。
omni_select_developer_dir() {
    if [ -n "${DEVELOPER_DIR:-}" ] && [ -d "$DEVELOPER_DIR" ]; then
        return 0
    fi
    local candidate
    for candidate in "/Applications/Xcode-beta.app/Contents/Developer" \
                     "/Applications/Xcode.app/Contents/Developer"; do
        if [ -d "$candidate" ]; then
            export DEVELOPER_DIR="$candidate"
            return 0
        fi
    done
    # 回退：尊重系统 xcode-select（可能是 CommandLineTools）
    local sel
    sel="$(xcode-select -p 2>/dev/null || true)"
    if [ -n "$sel" ] && [ -d "$sel" ]; then
        export DEVELOPER_DIR="$sel"
    fi
}

# ── 3. 环境信息输出 ──
omni_print_env() {
    echo "=== Build environment ==="
    echo "OMNI_ROOT:     $OMNI_ROOT"
    echo "DEVELOPER_DIR: ${DEVELOPER_DIR:-<unset>}"
    echo "DEPLOYMENT:    $MACOSX_DEPLOYMENT_TARGET"
    echo "Swift:"
    xcrun swift --version 2>&1 | head -2
    echo "macOS SDK:"
    xcrun --sdk macosx --show-sdk-path 2>&1
    echo ""
}

# ── 4. SwiftPM release 产物路径解析 ──
# SwiftPM 产物根随工具链版本变化：
#   Xcode 27 / Swift 6.4+ -> .build/out/Products/Release
#   Xcode 26 / Swift 6.2+ -> .build/apple/Products/Release
#   旧版                  -> .build/release
omni_resolve_release_binary() {
    local candidates=(
        "$OMNI_ROOT/.build/out/Products/Release/OmniTrans"
        "$OMNI_ROOT/.build/apple/Products/Release/OmniTrans"
        "$OMNI_ROOT/.build/release/OmniTrans"
    )
    local c
    for c in "${candidates[@]}"; do
        if [ -f "$c" ]; then
            echo "$c"
            return 0
        fi
    done
    return 1
}

# ── 5. 统一 Swift 构建命令（release）──
# 追加参数：--arch arm64 / --arch x86_64 / --arch arm64 --arch x86_64
omni_swift_build_release() {
    xcrun swift build \
        -c release \
        --disable-build-manifest-caching \
        "$@"
}

# ── 6. 最小 Info.plist（含阿里云 ATS 例外）──
omni_make_info_plist() {
    local app_dir="$1" bundle_id="$2" version="${3:-0.7.0}"
    local minos="${MACOSX_DEPLOYMENT_TARGET:-15.0}"
    cat > "$app_dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>OmniTrans</string>
    <key>CFBundleIdentifier</key><string>${bundle_id}</string>
    <key>CFBundleName</key><string>OmniTrans</string>
    <key>CFBundleDisplayName</key><string>OmniTrans</string>
    <key>CFBundleVersion</key><string>${version}</string>
    <key>CFBundleShortVersionString</key><string>${version}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>${minos}</string>
    <key>CFBundleIconFile</key><string>icon.icns</string>
    <key>CFBundleIconName</key><string>icon</string>
    <key>LSUIElement</key><true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSExceptionDomains</key>
        <dict>
            <key>mt.cn-hangzhou.aliyuncs.com</key>
            <dict><key>NSExceptionAllowsInsecureHTTPLoads</key><true/><key>NSIncludesSubdomains</key><true/></dict>
            <key>mt.aliyuncs.com</key>
            <dict><key>NSExceptionAllowsInsecureHTTPLoads</key><true/><key>NSIncludesSubdomains</key><true/></dict>
            <key>aliyuncs.com</key>
            <dict><key>NSExceptionAllowsInsecureHTTPLoads</key><true/><key>NSIncludesSubdomains</key><true/></dict>
        </dict>
    </dict>
</dict></plist>
PLIST
}

# ── 7. 组装 .app（保留原有目录结构与命名：Contents/MacOS/OmniTrans + Resources/icons）──
#    签名策略：
#      - --options runtime：启用 Hardened Runtime（macOS 公证强制要求）
#      - --entitlements：加载 Resource/entitlements.plist（ANE/Translation 框架权限）
#      - --sign -：ad-hoc 签名（本地开发/测试）；正式分发需替换为 Developer ID 证书
omni_assemble_app() {
    local bin="$1" app_dir="$2" bundle_id="$3" version="${4:-0.7.0}"
    mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
    cp "$bin" "$app_dir/Contents/MacOS/OmniTrans"

    # ── 激进 strip ──
    # -x: 移除所有非全局符号（比 -u 更激进）
    # -S: 移除调试符号
    # -u: 保留局部符号（已被 -x 覆盖，兼容保留）
    strip -x -S "$app_dir/Contents/MacOS/OmniTrans" 2>/dev/null || \
    strip -u -r "$app_dir/Contents/MacOS/OmniTrans" 2>/dev/null || true

    cp "$OMNI_ROOT/Resource/icon/icon.icns" "$app_dir/Contents/Resources/icon.icns"
    cp "$OMNI_ROOT/Resource/icon/menubar.icns" "$app_dir/Contents/Resources/menubar.icns"
    omni_make_info_plist "$app_dir" "$bundle_id" "$version"

    # ── Hardened Runtime 签名 ──
    # 单次签名整个 bundle，启用 Hardened Runtime + entitlements
    local entitlements="$OMNI_ROOT/Resource/entitlements.plist"
    local sign_args=(--force --deep --options runtime --sign -)
    if [ -f "$entitlements" ]; then
        sign_args+=(--entitlements "$entitlements")
    fi
    codesign "${sign_args[@]}" "$app_dir" 2>&1

    xattr -cr "$app_dir" 2>/dev/null || true
}

# source 时立即选择工具链
omni_select_developer_dir
