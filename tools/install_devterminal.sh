#!/bin/bash
# Installs the Development build as a standalone "Dev Terminal" app that
# coexists with the stock iTerm2: different name, bundle ID and preferences.
# Usage: tools/install_devterminal.sh [--build] [--import-profiles] [destination-dir]
#   --build             Build the Development configuration first.
#   --import-profiles   Copy profiles from stock iTerm2 into Dev Terminal's preferences.
#                       Existing Dev Terminal profiles are kept; the stock default profile
#                       becomes the default. The stock iTerm2 files are only read.
set -euo pipefail

cd "$(dirname "$0")/.."

NAME="Dev Terminal"
BUNDLE_ID="com.dutta14.devterminal"
OLD_NAME="CopilotTerm"
OLD_BUNDLE_ID="com.dutta14.copilotterm"
STOCK_DOMAIN="com.googlecode.iterm2"

BUILD=0
IMPORT_PROFILES=0
DEST_DIR="/Applications"
for arg in "$@"; do
    case "$arg" in
        --build) BUILD=1 ;;
        --import-profiles) IMPORT_PROFILES=1 ;;
        -*) echo "Unknown option: $arg" >&2; exit 2 ;;
        *) DEST_DIR="$arg" ;;
    esac
done

if [ "$BUILD" = 1 ]; then
    tools/build.sh Development
fi

SYMROOT=$(xcodebuild -scheme iTerm2 -showBuildSettings 2>/dev/null | awk -F ' = ' '/^ *SYMROOT/{print $2; exit}')
SRC="$SYMROOT/Development/iTerm2.app"
DEST="$DEST_DIR/$NAME.app"

if [ ! -d "$SRC" ]; then
    echo "No build found at $SRC. Run: $0 --build" >&2
    exit 1
fi

if pgrep -f "$DEST/Contents/MacOS/" >/dev/null 2>&1 ||
   pgrep -f "$DEST_DIR/$OLD_NAME.app/Contents/MacOS/" >/dev/null 2>&1; then
    echo "$NAME (or the old $OLD_NAME) is running. Quit it and try again." >&2
    exit 1
fi

# One-time rename from the old name: carry over preferences and app data, then remove the old app.
OLD_APP="$DEST_DIR/$OLD_NAME.app"
if [ -d "$OLD_APP" ]; then
    if ! defaults read "$BUNDLE_ID" >/dev/null 2>&1 && defaults read "$OLD_BUNDLE_ID" >/dev/null 2>&1; then
        defaults export "$OLD_BUNDLE_ID" - | defaults import "$BUNDLE_ID" -
        echo "Copied preferences from $OLD_BUNDLE_ID"
    fi
    SUPPORT="$HOME/Library/Application Support"
    if [ -d "$SUPPORT/$OLD_NAME" ] && [ ! -e "$SUPPORT/$NAME" ]; then
        mv "$SUPPORT/$OLD_NAME" "$SUPPORT/$NAME"
        echo "Moved $SUPPORT/$OLD_NAME"
    fi
    rm -rf "$OLD_APP"
    echo "Removed $OLD_APP"
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

# Replace the stock icon with the "</>" icon. Dropping CFBundleIconName stops macOS
# from using the stock icon in Assets.car.
ICNS="$(mktemp -d)/AppIcon-DevTerminal.icns"
tools/make_devterminal_icon.sh "$ICNS" >/dev/null
cp "$ICNS" "$DEST/Contents/Resources/AppIcon-DevTerminal.icns"
"$PB" -c "Delete :CFBundleIconName" "$PLIST" 2>/dev/null || true
"$PB" -c "Set :CFBundleIconFile AppIcon-DevTerminal" "$PLIST"

# Editing Info.plist invalidates the signature; re-sign ad hoc.
codesign --force --deep --sign - --preserve-metadata=entitlements "$DEST"
touch "$DEST"

if [ "$IMPORT_PROFILES" = 1 ]; then
    BACKUP="tmp/devterminal-prefs-backup-$(date +%Y%m%d-%H%M%S).plist"
    mkdir -p tmp
    defaults export "$BUNDLE_ID" "$BACKUP" 2>/dev/null || true
    STOCK_PLIST="$(mktemp)"
    defaults export "$STOCK_DOMAIN" "$STOCK_PLIST"
    /usr/bin/python3 - "$STOCK_PLIST" "$BACKUP" "$BUNDLE_ID" <<'PY'
import plistlib, subprocess, sys

stock_path, mine_path, domain = sys.argv[1:4]
stock = plistlib.load(open(stock_path, "rb"))
try:
    mine = plistlib.load(open(mine_path, "rb"))
except (OSError, plistlib.InvalidFileException):
    mine = {}

bookmarks = list(mine.get("New Bookmarks", []))
known = {b.get("Guid") for b in bookmarks}
added = 0
for b in stock.get("New Bookmarks", []):
    if b.get("Guid") not in known:
        bookmarks.append(b)
        added += 1
mine["New Bookmarks"] = bookmarks
if stock.get("Default Bookmark Guid"):
    mine["Default Bookmark Guid"] = stock["Default Bookmark Guid"]

subprocess.run(["defaults", "import", domain, "-"], input=plistlib.dumps(mine), check=True)
print(f"Imported {added} profile(s); {len(bookmarks)} total.")
PY
    rm -f "$STOCK_PLIST"
    echo "Previous Dev Terminal preferences saved to $BACKUP"
fi

echo "Installed $DEST"
