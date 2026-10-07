#!/bin/bash
set -euo pipefail

# Single source of truth: build.sh. Duplicating the literal here is how the two
# drift, and a .pkg labelled with the wrong version is worse than no .pkg.
VERSION="${VERSION:-$(sed -n 's/^VERSION="${VERSION:-\(.*\)}"$/\1/p' "$(dirname "$0")/build.sh")}"
APP_NAME="MacBackup4Dev"
LEGACY_NAME="RustyMacBackup"
PKG_ID="com.roberdan.rusty-mac-backup"

echo "📦 Building $APP_NAME v$VERSION installer..."

# Step 1: Build the app (VERSION is passed through env)
VERSION="$VERSION" ./build.sh

# Step 2: Create .app.zip for auto-update (in-place, no admin required)
echo "  Creating .app.zip…"
ditto -c -k --keepParent "build/$APP_NAME.app" "$APP_NAME-$VERSION.app.zip"
echo "  ✅ $APP_NAME-$VERSION.app.zip ($(du -sh "$APP_NAME-$VERSION.app.zip" | cut -f1))"

# Bridge for 3.x updaters: they download "RustyMacBackup-<v>.app.zip" and expect a
# "RustyMacBackup.app" inside. Same signed app, old folder name; on first launch the app
# renames itself to MacBackup4Dev.app (AutoUpdater.relocateFromLegacyName).
BRIDGE_DIR=$(mktemp -d)
ditto "build/$APP_NAME.app" "$BRIDGE_DIR/$LEGACY_NAME.app"
ditto -c -k --keepParent "$BRIDGE_DIR/$LEGACY_NAME.app" "$LEGACY_NAME-$VERSION.app.zip"
rm -rf "$BRIDGE_DIR"
echo "  ✅ $LEGACY_NAME-$VERSION.app.zip (ponte per gli aggiornamenti dalla 3.x)"

# Step 3: Create staging directory for .pkg
PKG_ROOT=$(mktemp -d)
SCRIPTS_DIR=$(mktemp -d)
trap "rm -rf $PKG_ROOT $SCRIPTS_DIR" EXIT

mkdir -p "$PKG_ROOT/Applications"
cp -R "build/$APP_NAME.app" "$PKG_ROOT/Applications/"

# Step 4: postinstall — hand the app to the logged-in user (so automatic updates can
# replace it without a password, like Sparkle expects) and restart only the menu-bar app.
cat > "$SCRIPTS_DIR/postinstall" << 'POSTINSTALL'
#!/bin/bash
APP="/Applications/MacBackup4Dev.app"
BIN="$APP/Contents/MacOS/MacBackup4Dev"
LEGACY_APP="/Applications/RustyMacBackup.app"
CONSOLE_USER=$(stat -f%Su /dev/console)
if [ -n "$CONSOLE_USER" ] && [ "$CONSOLE_USER" != "root" ] && [ "$CONSOLE_USER" != "loginwindow" ]; then
    USER_ID=$(id -u "$CONSOLE_USER")
    chown -R "$CONSOLE_USER":admin "$APP"
    # The menu-bar app runs with no arguments; a running backup ("… backup") is left alone.
    for pid in $(pgrep -U "$USER_ID" -fx "$BIN"); do kill "$pid" 2>/dev/null; done
    # 4.0 rename: the 3.x app (same bundle id) goes away, after its menu-bar process.
    if [ -d "$LEGACY_APP" ] && [ "$(defaults read "$LEGACY_APP/Contents/Info" CFBundleIdentifier 2>/dev/null)" = "com.roberdan.rusty-mac-backup" ]; then
        for pid in $(pgrep -U "$USER_ID" -fx "$LEGACY_APP/Contents/MacOS/RustyMacBackup"); do kill "$pid" 2>/dev/null; done
        rm -rf "$LEGACY_APP"
    fi
    sleep 1
    launchctl asuser "$USER_ID" sudo -u "$CONSOLE_USER" /usr/bin/open "$APP" 2>/dev/null || true
fi
exit 0
POSTINSTALL
chmod +x "$SCRIPTS_DIR/postinstall"

# Step 5: Build .pkg
pkgbuild \
    --root "$PKG_ROOT" \
    --identifier "$PKG_ID" \
    --version "$VERSION" \
    --install-location "/" \
    --scripts "$SCRIPTS_DIR" \
    "$APP_NAME-$VERSION-arm64.pkg"

echo ""
echo "🎉 Artifacts:"
echo "   $APP_NAME-$VERSION-arm64.pkg  (first install — requires admin)"
echo "   $APP_NAME-$VERSION.app.zip    (auto-update — no admin needed)"
echo "   $LEGACY_NAME-$VERSION.app.zip   (auto-update bridge for 3.x)"
