#!/bin/bash
# ============================================================================
# OmniTrans 通用构建脚本（universal：arm64 + x86_64）
# 产物：.build/OmniTrans.app（bundle id: com.omnitrans.app）
#
# 修复要点：
#   - DEVELOPER_DIR 动态检测（Xcode-beta > Xcode > xcode-select），兼容 CLT
#   - 产物路径兼容 Xcode 27/Swift 6.4 的 .build/out/Products/Release 布局
#   - 显式 MACOSX_DEPLOYMENT_TARGET=14.0，与 Package.swift / Info.plist 一致
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"

# 共享构建环境（工具链选择 / 产物路径解析 / Info.plist / 组装 .app）
source "$(dirname "$0")/scripts/omnitrans-build-common.sh"

APP_NAME="OmniTrans.app"
APP_DIR="$OMNI_ROOT/.build/$APP_NAME"

echo "=== Cleaning old build ==="
rm -rf "$APP_DIR" .build/release .build/out .build/apple 2>/dev/null || true

omni_print_env

echo "=== Building OmniTrans (universal: arm64 + x86_64) release ==="
omni_swift_build_release --arch arm64 --arch x86_64

echo "=== Resolving release binary ==="
BIN="$(omni_resolve_release_binary)" || {
    echo "ERROR: release binary not found in any expected SwiftPM path."
    find .build -name "OmniTrans" -type f 2>/dev/null
    exit 1
}
echo "Binary: $BIN"
file "$BIN"

echo "=== Assembling $APP_NAME ==="
omni_assemble_app "$BIN" "$APP_DIR" "com.omnitrans.app"

echo ""
echo "=== Build complete ==="
echo "App: $APP_DIR"
echo "Run: open $APP_DIR"

# Show binary size for verification
if command -v stat &>/dev/null; then
    BIN_SIZE=$(stat -f%z "$APP_DIR/Contents/MacOS/OmniTrans" 2>/dev/null || echo "?")
else
    BIN_SIZE="?"
fi
echo "Binary size: ${BIN_SIZE} bytes"
