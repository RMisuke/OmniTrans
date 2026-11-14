#!/bin/bash
# ============================================================================
# OmniTrans 构建脚本（Universal: arm64 + x86_64）
#
# 产物：.build/OmniTrans.app（bundle id: com.omnitrans.app）
#
# 功能：
#   - 自动检测 Xcode / Xcode-beta / CLT 工具链
#   - 构建 universal binary（arm64 + x86_64）
#   - Hardened Runtime 签名 + entitlements
#   - Git 版本戳记（tag 或 commit hash）
#   - 增量构建（默认不清理，--clean 强制清理）
#   - 构建计时 + 产物体积报告
#
# 用法：
#   ./build.sh              # 增量构建 universal release
#   ./build.sh --debug      # 构建 debug（跳过 strip + LTO）
#   ./build.sh --clean      # 清理后构建
#   ./build.sh --release N  # 指定版本号（默认从 git tag 读取）
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"

# 共享构建环境（工具链选择 / 产物路径解析 / Info.plist / 组装 .app）
source "$(dirname "$0")/scripts/omnitrans-build-common.sh"

APP_NAME="OmniTrans.app"
APP_DIR="$OMNI_ROOT/.build/$APP_NAME"
BUILD_CONFIG="release"
APP_VERSION=""

# ── 解析命令行参数 ──
for arg in "$@"; do
    case "$arg" in
        --debug)  BUILD_CONFIG="debug" ;;
        --clean)  rm -rf "$APP_DIR" .build/release .build/debug .build/out .build/apple 2>/dev/null || true ;;
        --release) APP_VERSION_NEXT=1 ;;  # 下一个参数是版本号
        --help|-h)
            echo "用法: $0 [--debug] [--clean] [--release N] [--help]"
            echo "  --debug       构建 debug 版本（跳过 strip + LTO）"
            echo "  --clean       清理旧产物后构建"
            echo "  --release N   指定版本号（默认从 git tag 读取）"
            echo "  --help        显示此帮助"
            exit 0
            ;;
        *)
            if [ "${APP_VERSION_NEXT:-0}" = "1" ]; then
                APP_VERSION="$arg"
                unset APP_VERSION_NEXT
            fi
            ;;
    esac
done

# ── Git 版本戳记 ──
# 优先级：--release 参数 > git tag > fallback 0.7
omni_resolve_version() {
    if [ -n "$APP_VERSION" ]; then
        echo "$APP_VERSION"
        return
    fi
    # 尝试从最近的 git tag 读取版本号
    local tag
    tag=$(git describe --tags --abbrev=0 2>/dev/null || true)
    if [ -n "$tag" ]; then
        # 去掉 v 前缀（v1.0 → 1.0）
        echo "${tag#v}"
        return
    fi
    # fallback
    echo "0.7.0"
}

VERSION=$(omni_resolve_version)
echo "=== Version: $VERSION ==="

# ── 构建计时 ──
BUILD_START=$(date +%s)

# 仅在 --clean 时清理（保留增量构建能力）
# --clean 参数已在上方解析时执行了清理

omni_print_env

echo "=== Building OmniTrans (universal: arm64 + x86_64) $BUILD_CONFIG ==="
if [ "$BUILD_CONFIG" = "debug" ]; then
    xcrun swift build --disable-build-manifest-caching --arch arm64 --arch x86_64
else
    omni_swift_build_release --arch arm64 --arch x86_64
fi

BUILD_END=$(date +%s)
BUILD_ELAPSED=$(( BUILD_END - BUILD_START ))

echo "=== Resolving release binary ==="
BIN="$(omni_resolve_release_binary)" || {
    echo "ERROR: release binary not found in any expected SwiftPM path."
    find .build -name "OmniTrans" -type f 2>/dev/null
    exit 1
}
echo "Binary: $BIN"
file "$BIN"

echo "=== Assembling $APP_NAME ==="
omni_assemble_app "$BIN" "$APP_DIR" "com.omnitrans.app" "$VERSION"

# ── 清理中间产物（.dSYM 等）──
find "$OMNI_ROOT/.build" -name "*.dSYM" -type d -exec rm -rf {} + 2>/dev/null || true

echo ""
echo "=== Build complete ==="
echo "Version:    $VERSION"
echo "App:        $APP_DIR"
echo "Run:        open $APP_DIR"
echo "Build time: ${BUILD_ELAPSED}s"

# ── 产物体积报告 ──
echo ""
echo "=== Bundle size ==="
TOTAL_SIZE=$(du -sh "$APP_DIR" 2>/dev/null | cut -f1)
BIN_SIZE=$(stat -f%z "$APP_DIR/Contents/MacOS/OmniTrans" 2>/dev/null || echo "?")
ICON1_SIZE=$(stat -f%z "$APP_DIR/Contents/Resources/icon.icns" 2>/dev/null || echo "?")
ICON2_SIZE=$(stat -f%z "$APP_DIR/Contents/Resources/menubar.icns" 2>/dev/null || echo "?")
echo "Total:       $TOTAL_SIZE"
echo "Binary:      $(( BIN_SIZE / 1024 ))KB"
echo "icon.icns:   $(( ICON1_SIZE / 1024 ))KB"
echo "menubar.icns: $(( ICON2_SIZE / 1024 ))KB"

# ── 签名信息 ──
echo ""
echo "=== Signing info ==="
codesign -dvv "$APP_DIR" 2>&1 | grep -E "^(Authority|Identifier|TeamIdentifier|Runtime|Entitlements|Flags)" || true
