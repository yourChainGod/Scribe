#!/usr/bin/env bash
# Build Scribe.app bundle from the SwiftPM executable.
# Usage: ./Scripts/build_app.sh [release|debug]
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/.build"
APP_DIR="${SCRIBE_APP_DIR:-$ROOT/build/Scribe.app}"

cd "$ROOT"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

ARCH="$(uname -m)"
case "$ARCH" in
    arm64)  TRIPLE="arm64-apple-macosx" ;;
    x86_64) TRIPLE="x86_64-apple-macosx" ;;
    *)      echo "Unsupported arch: $ARCH"; exit 1 ;;
esac

BIN="$BUILD_DIR/$TRIPLE/$CONFIG/Scribe"
[[ -x "$BIN" ]] || { echo "Binary not found: $BIN"; exit 1; }

echo "==> Constructing $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN" "$APP_DIR/Contents/MacOS/Scribe"

# Copy SwiftPM's resource bundle alongside the binary so Bundle.module
# can locate Resources/ contents (currently the .lproj catalogues for
# i18n). SwiftPM emits this as `<Module>_<Module>.bundle` next to the
# binary; we mirror it into Contents/Resources so the .app is a
# self-contained, double-clickable artefact.
#
# Additionally promote the .lproj catalogues to the main Contents/
# Resources level. Bundle.main's preferredLocalizations is computed
# against THIS directory, not the nested Scribe_Scribe.bundle —
# without these copies, AppleLanguages='zh-Hans' silently falls back
# to en because macOS sees the main bundle as ".lproj-less" and
# treats it as English-only. The Bundle.module nested copy still
# serves SwiftUI's actual string lookups.
SWIFT_BUNDLE="$BUILD_DIR/$TRIPLE/$CONFIG/Scribe_Scribe.bundle"
if [[ -d "$SWIFT_BUNDLE" ]]; then
    echo "==> Copying Scribe_Scribe.bundle (nested resources)"
    cp -R "$SWIFT_BUNDLE" "$APP_DIR/Contents/Resources/"

    echo "==> Promoting .lproj catalogues to main bundle Resources"
    for LP in "$SWIFT_BUNDLE"/*.lproj; do
        [[ -d "$LP" ]] || continue
        # SwiftPM lower-cases regional subtags (zh-Hans -> zh-hans);
        # restore the canonical Apple form on the main-bundle copy
        # so NSBundle's locale matcher accepts it.
        BASE=$(basename "$LP")
        case "$BASE" in
            zh-hans.lproj) DEST="zh-Hans.lproj" ;;
            zh-hant.lproj) DEST="zh-Hant.lproj" ;;
            *)             DEST="$BASE" ;;
        esac
        cp -R "$LP" "$APP_DIR/Contents/Resources/$DEST"
    done
fi

# Generate .icns from icon.svg.
# Three render paths in priority order:
#   1. AppKit's NSImage(contentsOf:) — system-native SVG via CoreSVG.
#      Always available on macOS 13+. We invoke it through the small
#      Swift script in Scripts/render_icon.swift so we get every
#      .iconset size (16 / 32 / 128 / 256 / 512 at 1x and 2x) in one
#      pass. This is the path we expect to take on a normal dev
#      machine.
#   2. rsvg-convert — `brew install librsvg`. Falls back to this if
#      the AppKit script is missing for any reason.
#   3. qlmanage — Quick Look thumbnail. Last-resort, low-fidelity;
#      kept so the build doesn't fail outright on stripped systems.
ICON_SVG="$ROOT/Resources/icon.svg"
ICONSET="$ROOT/Resources/AppIcon.iconset"
ICON_SCRIPT="$ROOT/Scripts/render_icon.swift"

if [[ -f "$ICON_SVG" ]]; then
    rm -rf "$ICONSET"
    if [[ -f "$ICON_SCRIPT" ]]; then
        echo "==> Rendering .icns via AppKit (Scripts/render_icon.swift)"
        swift "$ICON_SCRIPT" "$ICON_SVG" "$ICONSET" >/dev/null
        iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
    elif command -v rsvg-convert &>/dev/null; then
        echo "==> Rendering .icns via rsvg-convert"
        mkdir -p "$ICONSET"
        for size in 16 32 128 256 512; do
            rsvg-convert -w $size -h $size "$ICON_SVG" -o "$ICONSET/icon_${size}x${size}.png"
            rsvg-convert -w $((size*2)) -h $((size*2)) "$ICON_SVG" -o "$ICONSET/icon_${size}x${size}@2x.png"
        done
        iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
    else
        echo "==> Rendering .icns via qlmanage (no AppKit script or rsvg-convert; expect lower fidelity)"
        mkdir -p "$ICONSET"
        qlmanage -t -s 1024 -o /tmp "$ICON_SVG" >/dev/null 2>&1 || true
        SRC_PNG="/tmp/icon.svg.png"
        if [[ -f "$SRC_PNG" ]]; then
            for size in 16 32 128 256 512; do
                sips -z $size $size "$SRC_PNG" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
                sips -z $((size*2)) $((size*2)) "$SRC_PNG" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
            done
            iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
        else
            echo "(warning) Could not render SVG to PNG; .app will use generic icon."
        fi
    fi
fi

# Info.plist
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Scribe</string>
    <key>CFBundleDisplayName</key>
    <string>Scribe</string>
    <key>CFBundleExecutable</key>
    <string>Scribe</string>
    <key>CFBundleIdentifier</key>
    <string>org.scribe.editor</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <!-- Phase 27: declare every locale we ship a .lproj for. macOS
         intersects this list with the user's AppleLanguages
         preference to pick the runtime locale; an empty / omitted
         list falls back to development region (English) which is
         why explicit declaration is required even when the .lproj
         directories already exist on disk. -->
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>zh-Hans</string>
    </array>
    <!-- Must stay in lockstep with Package.swift's `.macOS(.v14)` —
         otherwise the bundle silently lets Sonoma-only SwiftUI APIs
         (onKeyPress, onChange(of:_:_)) crash at launch on Ventura. -->
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <true/>
    <key>NSSupportsSuddenTermination</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Text Document</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.plain-text</string>
                <string>public.source-code</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

echo "==> Done: $APP_DIR"
echo "Run with: open '$APP_DIR'"
