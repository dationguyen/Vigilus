#!/bin/bash
# Builds Vigilus.app — a menu bar app to enable/disable sleep on macOS.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Vigilus"
APP_BUNDLE="build/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"

echo "==> Cleaning previous build"
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}"

echo "==> Compiling Swift sources (universal binary)"
swiftc -O \
    -target arm64-apple-macos13.0 \
    -o "${MACOS_DIR}/${APP_NAME}" \
    Sources/*.swift

echo "==> Writing Info.plist"
cat > "${CONTENTS}/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Vigilus</string>
    <key>CFBundleDisplayName</key>
    <string>Vigilus</string>
    <key>CFBundleIdentifier</key>
    <string>local.vigilus</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>Vigilus</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> Ad-hoc code signing"
codesign --force --deep --sign - "${APP_BUNDLE}" 2>/dev/null || echo "   (codesign skipped)"

echo ""
echo "✅ Built ${APP_BUNDLE}"
echo "   Run it:    open ${APP_BUNDLE}"
echo "   Install:   cp -r ${APP_BUNDLE} /Applications/"
