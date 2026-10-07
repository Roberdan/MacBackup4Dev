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

echo "🧪 Running MacBackup4Dev Tests..."
mkdir -p build

declare -a SOURCES=()
declare -a TESTS=()

while IFS= read -r file; do
    SOURCES+=("$file")
done < <(find Sources -name "*.swift" -type f ! -path "Sources/App/main.swift")

while IFS= read -r file; do
    TESTS+=("$file")
done < <(find Tests -name "*.swift" -type f)

if [ ${#TESTS[@]} -eq 0 ]; then
    echo "No test files found in Tests/"
    exit 1
fi

echo "  Compiling tests..."
swiftc \
    -target arm64-apple-macos14.0 \
    -framework Cocoa \
    -framework UserNotifications \
    -framework IOKit \
    -o build/MacBackup4DevTests \
    "${SOURCES[@]}" "${TESTS[@]}"

echo "  ✅ Compilation successful"
echo ""
echo "  Running tests..."
./build/MacBackup4DevTests
