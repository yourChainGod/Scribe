#!/usr/bin/env bash
# Build a distributable .dmg containing Scribe.app.
# Depends on Scripts/build_app.sh; will (re)build the .app first.
#
# Usage:
#   ./Scripts/build_dmg.sh                    # auto version from Info.plist
#   ./Scripts/build_dmg.sh 0.2.0              # explicit version
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/build/Scribe.app"
DMG_DIR="$ROOT/build"
STAGE_DIR="$(mktemp -d -t scribe-dmg-stage)"

cd "$ROOT"

echo "==> Building Scribe.app (release)"
bash "$ROOT/Scripts/build_app.sh" release

[[ -d "$APP_DIR" ]] || { echo "Scribe.app not found at $APP_DIR"; exit 1; }

# Pull version from Info.plist unless caller supplied one.
if [[ $# -ge 1 ]]; then
    VERSION="$1"
else
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
                 "$APP_DIR/Contents/Info.plist" 2>/dev/null || echo "0.0.0")
fi

DMG_NAME="Scribe-${VERSION}.dmg"
DMG_PATH="$DMG_DIR/$DMG_NAME"
VOL_NAME="Scribe ${VERSION}"

echo "==> Staging at $STAGE_DIR"
cp -R "$APP_DIR" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

# Drop a tiny note so users see something other than icons in the DMG window.
cat > "$STAGE_DIR/INSTALL.txt" <<TXT
Scribe ${VERSION}

Drag Scribe.app onto the Applications shortcut to install.

First launch: macOS may show "Scribe.app cannot be opened because the
developer cannot be verified" because the app is unsigned. Right-click
the app and choose Open, then confirm. This is a one-time prompt.

Source code: https://github.com/yourChainGod/Scribe
TXT

rm -f "$DMG_PATH"

echo "==> Creating $DMG_PATH"
hdiutil create \
    -volname "$VOL_NAME" \
    -srcfolder "$STAGE_DIR" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    "$DMG_PATH" >/dev/null

rm -rf "$STAGE_DIR"

SIZE=$(du -h "$DMG_PATH" | cut -f1)
echo "==> Done: $DMG_PATH ($SIZE)"
echo "    Volume name: $VOL_NAME"
echo
echo "    Verify with:  hdiutil verify '$DMG_PATH'"
echo "    Mount test:   open '$DMG_PATH'"
