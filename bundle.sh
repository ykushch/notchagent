#!/bin/bash
# Package NotchApp into a proper .app bundle with a stable identity, then ad-hoc
# sign it so macOS TCC (Accessibility) can track it. Global hotkeys (⌥Y/⌥N/⌥+arrows)
# require Accessibility, which will NOT work when running the bare `swift run`
# executable from .build/ — macOS needs a signed .app with a stable bundle id.
#
# Usage: VERSION=1.2.3 ./bundle.sh [release|debug]   (defaults: 0.1, release)
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
VERSION="${VERSION:-0.1}"
APP="NotchApp"
BUNDLE_ID="dev.notchagent.NotchApp"
OUT="build/${APP}.app"
GIT_REVISION="$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BUILD_NUMBER="$(date -u +%Y%m%d%H%M%S)"
SOURCE_PATH="$(pwd)"
case "$CONFIG" in
    release|debug) ;;
    *) echo "usage: VERSION=1.2.3 ./bundle.sh [release|debug]" >&2; exit 2 ;;
esac
if [[ ! "$VERSION" =~ ^[0-9]+([.][0-9]+)*$ ]]; then
    echo "VERSION must be numeric components separated by dots (for example, 1.2.3)" >&2
    exit 2
fi
INCLUDE_SOURCE_PATH="${INCLUDE_SOURCE_PATH:-}"
if [[ -z "$INCLUDE_SOURCE_PATH" ]]; then
    if [[ "$CONFIG" == "release" ]]; then INCLUDE_SOURCE_PATH="false"; else INCLUDE_SOURCE_PATH="true"; fi
fi
if [[ -n "$(git status --porcelain --untracked-files=normal 2>/dev/null)" ]]; then
    GIT_DIRTY="true"
    GIT_SUFFIX="-dirty"
else
    GIT_DIRTY="false"
    GIT_SUFFIX=""
fi

echo "Building ($CONFIG)"
swift build -c "$CONFIG" --product "$APP"
VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" \
    ./scripts/build-screensaver.sh "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/${APP}"

echo "Assembling $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/${APP}"
# App icon: regenerate with `swift scripts/generate-app-icon.swift`.
cp Assets/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"
cp -R build/NotchAgent.saver "$OUT/Contents/Resources/"
# Keep the SwiftPM target resource bundle in the standard signed resource area.
# HerdrBrandMark also checks beside the executable for the `swift run` layout.
RESOURCE_BUNDLE="$(dirname "$BIN")/NotchAgent_NotchApp.bundle"
if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
    echo "Missing SwiftPM resource bundle: $RESOURCE_BUNDLE" >&2
    exit 1
fi
cp -R "$RESOURCE_BUNDLE" "$OUT/Contents/Resources/"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                <string>${APP}</string>
    <key>CFBundleDisplayName</key>         <string>Notch Agent</string>
    <key>CFBundleIdentifier</key>          <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>             <string>${BUILD_NUMBER}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleExecutable</key>          <string>${APP}</string>
    <key>CFBundleIconFile</key>            <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>      <string>14.0</string>
    <!-- Accessory app: no Dock icon, non-activating (matches setActivationPolicy(.accessory)). -->
    <key>LSUIElement</key>                 <true/>
    <key>NSHighResolutionCapable</key>     <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Notch Agent uses System Events to start your selected screen saver when you press its configured shortcut.</string>
</dict>
</plist>
PLIST

# Keep enough provenance in the signed bundle to distinguish two checkouts with
# the same bundle identifier. This is intentionally visible in the menu too.
plutil -insert NotchAgentGitRevision -string "$GIT_REVISION" "$OUT/Contents/Info.plist"
plutil -insert NotchAgentGitDirty -bool "$GIT_DIRTY" "$OUT/Contents/Info.plist"
plutil -insert NotchAgentBuildDate -string "$BUILD_DATE" "$OUT/Contents/Info.plist"
if [[ "$INCLUDE_SOURCE_PATH" == "true" ]]; then
    plutil -insert NotchAgentSourcePath -string "$SOURCE_PATH" "$OUT/Contents/Info.plist"
fi

# Ad-hoc code signing gives the bundle a stable identity for TCC across runs.
# (A real Developer ID cert would be needed for distribution; ad-hoc is fine for
# personal use — the Accessibility grant sticks to this signed bundle.)
echo "Ad-hoc signing"
codesign --force --deep --sign - "$OUT"

if [[ "$CONFIG" == "release" ]]; then
    ARCHIVE="build/${APP}-${VERSION}.zip"
    rm -f "$ARCHIVE"
    ditto -c -k --keepParent "$OUT" "$ARCHIVE"
    echo "Archive: $ARCHIVE"
fi

echo "Done: $OUT"
echo "Build: ${GIT_REVISION}${GIT_SUFFIX} at $BUILD_DATE"
if [[ "$INCLUDE_SOURCE_PATH" == "true" ]]; then
    echo "Source: $SOURCE_PATH"
fi
echo
echo "Launch it (NOT 'swift run') so Accessibility can track it:"
echo "  open $OUT"
echo
echo "Optional agent shortcuts: grant Accessibility to 'Notch Agent'."
echo "The screen-saver shortcut uses Automation → System Events and does not require Accessibility."
