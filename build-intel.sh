#!/bin/bash
# ============================================================================
# OmniTrans x86_64 (Intel) 专用构建脚本
# 产物：.build/OmniTrans-intel.app（bundle id: com.omnitrans.intel）
#
# 修复要点：
#   - 原脚本直接调用 `swift build`（未设 DEVELOPER_DIR），在 CLT 环境下会触发
#     "spec already registered" 构建系统错误；改为经共享环境统一走 xcrun
#   - 产物路径兼容 Xcode 27/Swift 6.4 的 .build/out/Products/Release 布局
#   - 显式 MACOSX_DEPLOYMENT_TARGET=14.0
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"

# 共享构建环境（工具链选择 / 产物路径解析 / Info.plist / 组装 .app）
source "$(dirname "$0")/scripts/omnitrans-build-common.sh"

APP_DIR="$OMNI_ROOT/.build/OmniTrans-intel.app"

echo "=== Cleaning old build ==="
rm -rf "$APP_DIR" .build/release .build/out .build/apple 2>/dev/null || true

omni_print_env

echo "=== Building OmniTrans (x86_64, Intel) release ==="
omni_swift_build_release --arch x86_64

echo "=== Resolving release binary ==="
BIN="$(omni_resolve_release_binary)" || {
    echo "ERROR: release binary not found in any expected SwiftPM path."
    find .build -name "OmniTrans" -type f 2>/dev/null
    exit 1
}
echo "Binary: $BIN"
file "$BIN"

echo "=== Assembling app ==="
omni_assemble_app "$BIN" "$APP_DIR" "com.omnitrans.intel"

echo ""
echo "=== Build complete ==="
echo "App: $APP_DIR"
echo "Run: open $APP_DIR"

if command -v stat &>/dev/null; then
    BIN_SIZE=$(stat -f%z "$APP_DIR/Contents/MacOS/OmniTrans" 2>/dev/null || echo "?")
else
    BIN_SIZE="?"
fi
echo "Binary size: ${BIN_SIZE} bytes"
