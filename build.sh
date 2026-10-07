#!/bin/bash
set -euo pipefail

# The Command Line Tools ship without the SwiftUI macro plugins (@State fails with
# "plugin for module 'SwiftUIMacros' not found"). Use the full Xcode when it is there.
# Xcode may live anywhere (e.g. /Applications/Dev/Xcode.app): ask Spotlight as a fallback.
if [ -z "${DEVELOPER_DIR:-}" ] && [[ "$(xcode-select -p 2>/dev/null)" == *CommandLineTools* ]]; then
    XCODE_APP=""
    for candidate in /Applications/Xcode.app /Applications/Xcode-beta.app \
        $(mdfind 'kMDItemCFBundleIdentifier == "com.apple.dt.Xcode"' 2>/dev/null); do
        if [ -d "$candidate/Contents/Developer" ]; then XCODE_APP="$candidate"; break; fi
    done
    if [ -n "$XCODE_APP" ]; then export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"; fi
fi

APP_NAME="RustyMacBackup"
VERSION="${VERSION:-3.3.0}"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
BINARY="$BUILD_DIR/$APP_NAME"
SWIFT_FILES=$(find Sources -name "*.swift" -type f)
MACOS_TARGET="arm64-apple-macos14.0"

# Signing identity -- Developer ID for distribution outside App Store
# Falls back to ad-hoc if Developer ID not available
# Find a Developer ID certificate for distribution (any team)
# Override with: CODESIGN_IDENTITY="your cert" ./build.sh
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$CODESIGN_IDENTITY"
    SIGN_LABEL="custom ($SIGN_IDENTITY)"
elif DEVID_HASH=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | awk '{print $2}'); [ -n "$DEVID_HASH" ]; then
    SIGN_IDENTITY="$DEVID_HASH"
    SIGN_LABEL="Developer ID (Gatekeeper OK on any Mac)"
else
    SIGN_IDENTITY="-"
    SIGN_LABEL="ad-hoc (right-click > Open on new Mac)"
fi

echo "Building $APP_NAME v$VERSION..."

mkdir -p "$BUILD_DIR"

echo "  Compiling..."
swiftc \
    -O \
    -target "$MACOS_TARGET" \
    -framework Cocoa \
    -framework SwiftUI \
    -framework UserNotifications \
    -framework IOKit \
    -o "$BINARY" \
    $SWIFT_FILES

echo "  Bundling..."
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
# Stamp version into Info.plist
cp Sources/App/Info.plist "$APP_BUNDLE/Contents/"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP_BUNDLE/Contents/Info.plist"
if [ -d "Resources/icons" ]; then
    cp Resources/icons/*.png "$APP_BUNDLE/Contents/Resources/" 2>/dev/null || true
fi
if [ -f "Resources/AppIcon.icns" ]; then
    cp Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/"
fi

echo "  Signing with: $SIGN_IDENTITY"
codesign --force --deep --options runtime \
    --sign "$SIGN_IDENTITY" \
    --identifier "com.roberdan.rusty-mac-backup" \
    "$APP_BUNDLE"

echo ""
echo "Build complete: $APP_BUNDLE"
echo "CLI: $($BINARY version 2>/dev/null || echo 'N/A')"
echo "Signed: $SIGN_LABEL"
