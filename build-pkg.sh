#!/bin/bash
set -euo pipefail

# Single source of truth: build.sh. Duplicating the literal here is how the two
# drift, and a .pkg labelled with the wrong version is worse than no .pkg.
VERSION="${VERSION:-$(sed -n 's/^VERSION="${VERSION:-\(.*\)}"$/\1/p' "$(dirname "$0")/build.sh")}"
APP_NAME="RustyMacBackup"
PKG_ID="com.roberdan.rusty-mac-backup"

echo "📦 Building $APP_NAME v$VERSION installer..."

# Step 1: Build the app (VERSION is passed through env)
VERSION="$VERSION" ./build.sh

# Step 2: Create .app.zip for auto-update (in-place, no admin required)
echo "  Creating .app.zip…"
ditto -c -k --keepParent "build/$APP_NAME.app" "$APP_NAME-$VERSION.app.zip"
echo "  ✅ $APP_NAME-$VERSION.app.zip ($(du -sh "$APP_NAME-$VERSION.app.zip" | cut -f1))"

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
APP="/Applications/RustyMacBackup.app"
BIN="$APP/Contents/MacOS/RustyMacBackup"
CONSOLE_USER=$(stat -f%Su /dev/console)
if [ -n "$CONSOLE_USER" ] && [ "$CONSOLE_USER" != "root" ] && [ "$CONSOLE_USER" != "loginwindow" ]; then
    USER_ID=$(id -u "$CONSOLE_USER")
    chown -R "$CONSOLE_USER":admin "$APP"
    # The menu-bar app runs with no arguments; a running backup ("… backup") is left alone.
    for pid in $(pgrep -U "$USER_ID" -fx "$BIN"); do kill "$pid" 2>/dev/null; done
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
