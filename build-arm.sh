#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "=== Cleaning old build ==="
rm -rf .build/OmniTrans-arm64.app .build/release/OmniTrans .build/release/OmniTrans.dSYM 2>/dev/null || true

echo "=== Building OmniTrans (arm64) with WMO ==="
swift build -c release \
    --arch arm64 \
    -Xswiftc -whole-module-optimization \
    -Xswiftc -O \
    2>&1

BIN=".build/release/OmniTrans"
APP_DIR=".build/OmniTrans-arm64.app"
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
    <key>CFBundleVersion</key><string>0.5</string>
    <key>CFBundleShortVersionString</key><string>0.5</string>
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
BIN_SIZE=$(stat -f%z "$APP_DIR/Contents/MacOS/OmniTrans" 2>/dev/null || stat -c%s "$APP_DIR/Contents/MacOS/OmniTrans" 2>/dev/null || echo "?")
echo "Binary size: ${BIN_SIZE} bytes"
