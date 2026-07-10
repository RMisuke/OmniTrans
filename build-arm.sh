#!/bin/bash
set -e

cd "$(dirname "$0")"

# ──────────────────────────────────────────────
#  Toolchain: force Xcode-beta for Xcode 27 Beta 3
#  (avoids "spec already registered" errors from
#   the standalone CLT SwiftBuild.framework)
# ──────────────────────────────────────────────
export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"

echo "=== Build environment ==="
echo "DEVELOPER_DIR: $DEVELOPER_DIR"
echo "Swift:"
xcrun swift --version 2>&1 | head -2
echo ""

echo "=== Cleaning old build ==="
rm -rf .build/OmniTrans-arm64.app .build/release .build/out 2>/dev/null || true

echo "=== Building OmniTrans (arm64) release ==="
xcrun swift build \
    -c release \
    --arch arm64 \
    --disable-build-manifest-caching \
    2>&1

# Binary output path (SwiftPM single-arch)
BIN=".build/release/OmniTrans"
APP_DIR=".build/OmniTrans-arm64.app"

if [ ! -f "$BIN" ]; then
    echo "ERROR: Binary not found at $BIN"
    echo "Searching for built binary..."
    find .build -name "OmniTrans" -type f 2>/dev/null
    exit 1
fi

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN" "$APP_DIR/Contents/MacOS/OmniTrans"

echo "=== Optimizing & Stripping Binary ==="
strip -u -r "$APP_DIR/Contents/MacOS/OmniTrans"

# Copy app icon (about page)
cp "Resource/icon/icon.icns" "$APP_DIR/Contents/Resources/icon.icns"
# Copy menu bar icon
cp "Resource/icon/menubar.icns" "$APP_DIR/Contents/Resources/menubar.icns"

# Minimal Info.plist
cat > "$APP_DIR/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>OmniTrans</string>
    <key>CFBundleIdentifier</key><string>com.omnitrans.arm64</string>
    <key>CFBundleName</key><string>OmniTrans</string>
    <key>CFBundleDisplayName</key><string>OmniTrans</string>
    <key>CFBundleVersion</key><string>0.6</string>
    <key>CFBundleShortVersionString</key><string>0.6</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>CFBundleIconFile</key><string>icon.icns</string>
    <key>LSUIElement</key><true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSExceptionDomains</key>
        <dict>
            <key>mt.cn-hangzhou.aliyuncs.com</key>
            <dict>
                <key>NSExceptionAllowsInsecureHTTPLoads</key>
                <true/>
                <key>NSIncludesSubdomains</key>
                <true/>
            </dict>
            <key>mt.aliyuncs.com</key>
            <dict>
                <key>NSExceptionAllowsInsecureHTTPLoads</key>
                <true/>
                <key>NSIncludesSubdomains</key>
                <true/>
            </dict>
            <key>aliyuncs.com</key>
            <dict>
                <key>NSExceptionAllowsInsecureHTTPLoads</key>
                <true/>
                <key>NSIncludesSubdomains</key>
                <true/>
            </dict>
        </dict>
    </dict>
</dict></plist>
PLIST

echo ""

# Ad-hoc code signing — prevents "app is damaged" on other Macs
echo "=== Signing app (ad-hoc) ==="
codesign --force --deep --sign - "$APP_DIR" 2>&1

# Remove quarantine attribute added by browsers / email
xattr -cr "$APP_DIR" 2>/dev/null || true

echo ""
echo "=== Build complete ==="
echo "App: $(pwd)/$APP_DIR"
echo "Run: open $(pwd)/$APP_DIR"

# Show binary size for verification
if command -v stat &>/dev/null; then
    BIN_SIZE=$(stat -f%z "$APP_DIR/Contents/MacOS/OmniTrans" 2>/dev/null || echo "?")
else
    BIN_SIZE="?"
fi
echo "Binary size: ${BIN_SIZE} bytes"
