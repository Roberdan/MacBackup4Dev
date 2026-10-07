#!/bin/bash
set -euo pipefail

# MacBackup4Dev — In-place installer
# Updates /Applications/MacBackup4Dev.app WITHOUT removing it,
# so macOS FDA (Full Disk Access) permission is preserved.

APP_NAME="MacBackup4Dev"
INSTALL_PATH="/Applications/$APP_NAME.app"
BUILD_PATH="build/$APP_NAME.app"

# Build first.
# build-pkg.sh, not build.sh: it builds the app once and *also* emits the .pkg and
# .app.zip we sync to the backup disk below. Those exist so the app is recoverable
# from the backup itself, and when install.sh merely copied "the newest .pkg lying
# around" they silently went stale — the recovery artifact on the disk sat at 1.0.0
# for five months while the installed app moved on. The only moment we can be sure
# they match is the moment we build them.
./build-pkg.sh

if [ ! -d "$BUILD_PATH" ]; then
    echo "❌ Build failed — no .app found"
    exit 1
fi

# Kill running instance
PID=$(pgrep -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true)
if [ -n "$PID" ]; then
    echo "  Chiudo $APP_NAME..."
    kill "$PID" 2>/dev/null || true
    sleep 1
fi

if [ -d "$INSTALL_PATH" ]; then
    # UPDATE in-place: only replace Contents, keep .app wrapper
    echo "  Aggiornamento in-place..."
    rsync -a --delete "$BUILD_PATH/Contents/" "$INSTALL_PATH/Contents/"
else
    # First install: copy whole .app
    echo "  Prima installazione..."
    cp -R "$BUILD_PATH" "$INSTALL_PATH"
fi

echo "  ✅ Installato: $INSTALL_PATH"

# Sync .app + .pkg to backup disk so the app is recoverable from the backup itself
BACKUP_DEST_DIR=$(awk -F'"' '/^path *=/{print $2}' ~/.config/macbackup4dev/config.toml 2>/dev/null || true)
if [ -n "$BACKUP_DEST_DIR" ] && [ -d "$BACKUP_DEST_DIR" ]; then
    echo "  Aggiorno disco di backup: $BACKUP_DEST_DIR..."
    rsync -a --delete "$BUILD_PATH/Contents/" "$BACKUP_DEST_DIR/$APP_NAME.app/Contents/"
    echo "  ✅ .app aggiornata sul disco di backup"
    # Copy the .pkg for THIS build, and drop any older one so the disk never offers
    # two installers with no way to tell which matches the .app next to it.
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
        "$BUILD_PATH/Contents/Info.plist" 2>/dev/null || true)
    PKG="${APP_NAME}-${VERSION}-arm64.pkg"
    if [ -n "$VERSION" ] && [ -f "$PKG" ]; then
        find "$BACKUP_DEST_DIR" -maxdepth 1 -name "${APP_NAME}-*.pkg" ! -name "$(basename "$PKG")" -delete
        cp "$PKG" "$BACKUP_DEST_DIR/"
        echo "  ✅ $(basename "$PKG") copiato sul disco di backup"
    else
        echo "  ⚠️  .pkg v$VERSION non trovato, disco senza installer di recovery"
    fi
else
    echo "  ⚠️  Disco di backup non montato, skip sync"
fi

# Relaunch
echo "  Avvio $APP_NAME..."
open "$INSTALL_PATH"

echo ""
echo "🎉 Installazione completata!"
echo "   I permessi FDA sono preservati."
