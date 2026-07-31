#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
case "$CONFIG" in
    release) OPTIMIZATION="-O" ;;
    debug) OPTIMIZATION="-Onone" ;;
    *) echo "usage: $0 [release|debug]" >&2; exit 2 ;;
esac

SDK="$(xcrun --sdk macosx --show-sdk-path)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
OUTPUT="$ROOT/build/NotchAgent.saver"
EXECUTABLE="$OUTPUT/Contents/MacOS/NotchAgentScreenSaver"
SOURCES=(
    "$ROOT/Sources/ScreenSaveKit/ScreenSaveConfiguration.swift"
    "$ROOT/Sources/ScreenSaveKit/ScreenSaveSnapshot.swift"
    "$ROOT/Sources/ScreenSaveKit/ScreenSaveGridLayout.swift"
    "$ROOT/Sources/ScreenSaveKit/ScreenSaveStatusView.swift"
    "$ROOT/Sources/ScreenSaveKit/ClassicScreenSaveStyle.swift"
    "$ROOT/Sources/ScreenSaveKit/AuroraScreenSaveStyle.swift"
    "$ROOT/Sources/ScreenSaveKit/WallpaperScreenSaveStyle.swift"
    "$ROOT/Sources/NotchScreenSaver/NotchAgentScreenSaverView.swift"
)

build_arch() {
    local arch="$1"
    xcrun swiftc \
        -parse-as-library \
        -emit-library \
        -swift-version 6 \
        "$OPTIMIZATION" \
        "${SOURCES[@]}" \
        -module-name NotchAgentScreenSaver \
        -target "$arch-apple-macosx14.0" \
        -sdk "$SDK" \
        -framework ScreenSaver \
        -framework AppKit \
        -framework SwiftUI \
        -Xlinker -bundle \
        -o "$TMP/NotchAgentScreenSaver-$arch"
}

build_arch arm64
build_arch x86_64

rm -rf "$OUTPUT"
mkdir -p "$OUTPUT/Contents/MacOS" "$OUTPUT/Contents/Resources"
lipo -create \
    "$TMP/NotchAgentScreenSaver-arm64" \
    "$TMP/NotchAgentScreenSaver-x86_64" \
    -output "$EXECUTABLE"
cp "$ROOT/Sources/NotchScreenSaver/Info.plist" "$OUTPUT/Contents/Info.plist"

VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M%S)}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
    "$OUTPUT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" \
    "$OUTPUT/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$OUTPUT"

echo "$OUTPUT"
