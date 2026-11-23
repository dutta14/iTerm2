#!/bin/bash
# Installs the Development build as a standalone "CopilotTerm" app that
# coexists with the stock iTerm2: different name, bundle ID and preferences.
# Usage: tools/install_copilotterm.sh [--build] [destination-dir]
set -euo pipefail

cd "$(dirname "$0")/.."

NAME="CopilotTerm"
BUNDLE_ID="com.dutta14.copilotterm"

if [ "${1:-}" = "--build" ]; then
    tools/build.sh Development
    shift
fi
DEST_DIR="${1:-/Applications}"

SYMROOT=$(xcodebuild -scheme iTerm2 -showBuildSettings 2>/dev/null | awk -F ' = ' '/^ *SYMROOT/{print $2; exit}')
SRC="$SYMROOT/Development/iTerm2.app"
DEST="$DEST_DIR/$NAME.app"

if [ ! -d "$SRC" ]; then
    echo "No build found at $SRC. Run: $0 --build" >&2
    exit 1
fi

if pgrep -f "$DEST/Contents/MacOS/" >/dev/null 2>&1; then
    echo "$NAME is running. Quit it and try again." >&2
    exit 1
fi

rm -rf "$DEST"
ditto "$SRC" "$DEST"

PLIST="$DEST/Contents/Info.plist"
PB=/usr/libexec/PlistBuddy
"$PB" -c "Set :CFBundleIdentifier $BUNDLE_ID" "$PLIST"
"$PB" -c "Set :CFBundleName $NAME" "$PLIST"
"$PB" -c "Add :CFBundleDisplayName string $NAME" "$PLIST" 2>/dev/null ||
    "$PB" -c "Set :CFBundleDisplayName $NAME" "$PLIST"
# This is a local fork; never offer upstream iTerm2 updates.
for key in SUFeedURL SUFeedURLForTesting SUFeedURLForFinal; do
    "$PB" -c "Delete :$key" "$PLIST" 2>/dev/null || true
done
"$PB" -c "Add :SUEnableAutomaticChecks bool false" "$PLIST" 2>/dev/null ||
    "$PB" -c "Set :SUEnableAutomaticChecks false" "$PLIST"

# Editing Info.plist invalidates the signature; re-sign ad hoc.
codesign --force --deep --sign - --preserve-metadata=entitlements "$DEST"
touch "$DEST"

echo "Installed $DEST"
