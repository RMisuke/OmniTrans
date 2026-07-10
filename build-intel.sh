#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "=== Cleaning old build ==="
rm -rf .build/OmniTrans-intel.app .build/release/OmniTrans .build/release/OmniTrans.dSYM 2>/dev/null || true
echo "=== Building OmniTrans (x86_64, Intel) release ==="
swift build -c release --arch x86_64 2>&1

BIN=".build/release/OmniTrans"
APP_DIR=".build/OmniTrans-intel.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN" "$APP_DIR/Contents/MacOS/OmniTrans"
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
    <key>CFBundleIdentifier</key><string>com.omnitrans.intel</string>
    <key>CFBundleName</key><string>OmniTrans</string>
    <key>CFBundleDisplayName</key><string>OmniTrans</string>
    <key>CFBundleVersion</key><string>0.6</string>
    <key>CFBundleShortVersionString</key><string>0.6</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>CFBundleIconFile</key><string>icon.icns</string>
    <key>LSUIElement</key><true/>
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
