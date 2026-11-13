#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_ROOT="$ROOT/dist"
APP_BUNDLE="$OUTPUT_ROOT/PhoneBackup.app"
TRIPLE="arm64-apple-macosx14.0"

if [[ -L "$OUTPUT_ROOT" || -L "$APP_BUNDLE" ]]; then
    echo "Refusing to build through a symlinked output path." >&2
    exit 1
fi

swift build --scratch-path "$ROOT/.build" --configuration release \
    --triple "$TRIPLE" --product PhoneBackupApp
BIN_PATH="$(swift build --scratch-path "$ROOT/.build" --configuration release \
    --triple "$TRIPLE" --product PhoneBackupApp --show-bin-path)"
EXECUTABLE="$BIN_PATH/PhoneBackupApp"
if [[ ! -x "$EXECUTABLE" ]]; then
    echo "SwiftPM did not produce an executable at the expected path." >&2
    exit 1
fi

mkdir -p "$OUTPUT_ROOT"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
ICON_WORK="$(mktemp -d "${TMPDIR:-/tmp}/phonebackup-icon.XXXXXX")"
trap 'rm -rf "$ICON_WORK"' EXIT
swift "$ROOT/macos/GenerateAppIcon.swift" "$ICON_WORK/PhoneBackup.iconset"
iconutil -c icns "$ICON_WORK/PhoneBackup.iconset" -o "$APP_BUNDLE/Contents/Resources/PhoneBackup.icns"
install -m 755 "$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/PhoneBackupApp"
install -m 644 "$ROOT/macos/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"
BUILD_REVISION="development"
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    BUILD_REVISION="$(git -C "$ROOT" rev-parse --short HEAD)"
    if ! git -C "$ROOT" diff --quiet HEAD; then BUILD_REVISION="$BUILD_REVISION-modified"; fi
fi
/usr/libexec/PlistBuddy -c "Add :PhoneBackupBuild string $BUILD_REVISION" "$APP_BUNDLE/Contents/Info.plist"

plutil -lint "$APP_BUNDLE/Contents/Info.plist"
codesign --force --deep --sign - "$APP_BUNDLE"
# Launch Services must be able to traverse the app bundle directory.
chmod 755 "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"
echo "Built and verified: $APP_BUNDLE"
