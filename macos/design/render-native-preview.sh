#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PREVIEW_SCRATCH="${TMPDIR:-/tmp}/androdo-native-preview-build"
OUTPUT="${1:?Usage: render-native-preview.sh OUTPUT.png [--dark] [--compact] [--collapsed] [--first-use] [--backups] [--long-name] [--scope] [--files] [--result] [--restore] [--restore-review] [--progress] [--progress-planning] [--progress-failure] [--progress-window-check] [--progress-window-done] [--phone-handoff]}"
shift
swift build --package-path "$ROOT/macos/design/NativePreview" --scratch-path "$PREVIEW_SCRATCH" --product AndrodoNativePreview
PREVIEW_BIN="$(swift build --package-path "$ROOT/macos/design/NativePreview" --scratch-path "$PREVIEW_SCRATCH" --show-bin-path)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/androdo-native-preview.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
BUNDLE="$WORK/AndrodoNativePreview.app"
mkdir -p "$BUNDLE/Contents/MacOS"
install -m 755 "$PREVIEW_BIN/AndrodoNativePreview" "$BUNDLE/Contents/MacOS/AndrodoNativePreview"
cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AndrodoNativePreview</string>
<key>CFBundleIdentifier</key><string>app.borosorus.Androdo.NativePreview</string>
<key>CFBundleName</key><string>Androdo Fictional Preview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
# Each fixture owns its AppKit restoration state as well as its isolated model preferences.
PREVIEW_RUN_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier app.borosorus.Androdo.NativePreview.$PREVIEW_RUN_ID" "$BUNDLE/Contents/Info.plist"
codesign --force --sign - "$BUNDLE"
chmod 755 "$BUNDLE"
open -W -n "$BUNDLE" --args --output "$WORK/capture.png" "$@"
if [[ ! -s "$WORK/capture.png" ]]; then
    if [[ -f "$WORK/failure.txt" ]]; then cat "$WORK/failure.txt" >&2; fi
    exit 1
fi
cp "$WORK/capture.png" "$OUTPUT"
