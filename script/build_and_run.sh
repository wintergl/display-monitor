#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
MODE="${1:---run-dev}"
CONFIGURATION=debug
LAUNCH=0
case "$MODE" in
  --build-only) ;;
  --release-build-only) CONFIGURATION=release ;;
  --run-dev|run) LAUNCH=1 ;;
  --help|-h)
    echo "Usage: $0 [--build-only|--release-build-only|--run-dev]"
    echo "Builds dist/Display Monitor.app with ad hoc signing by default. Never installs or stops another app."
    exit 0 ;;
  *) echo "Unknown mode: $MODE" >&2; exit 2 ;;
esac
APP="$ROOT_DIR/dist/Display Monitor.app"
SIGN_IDENTITY="${DISPLAY_MONITOR_SIGN_IDENTITY:--}"
running_pids() {
  local result status
  if result="$(pgrep -x DisplayMonitor)"; then
    printf '%s\n' "$result"
  else
    status=$?
    if [[ "$status" != 1 ]]; then
      echo "Cannot inspect running apps (pgrep exit $status)." >&2
      return "$status"
    fi
  fi
}
# Never replace a staged executable that may own a recording or input lease.
PIDS="$(running_pids)"
for PID in $PIDS; do
  EXECUTABLE="$(ps -p "$PID" -o comm=)" || { echo "Cannot inspect process; try again after quitting the app." >&2; exit 1; }
  if [[ "$EXECUTABLE" == "$APP/Contents/MacOS/DisplayMonitor" || "$LAUNCH" == 1 ]]; then
    echo "Display Monitor is running. Quit it normally before building this copy or launching another." >&2
    exit 1
  fi
done
swift build -c "$CONFIGURATION" --product DisplayMonitor
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
mkdir -p "$ROOT_DIR/dist"
STAGE="$(mktemp -d "$ROOT_DIR/dist/.app-staging.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
BUNDLE="$STAGE/Display Monitor.app"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN_DIR/DisplayMonitor" "$BUNDLE/Contents/MacOS/DisplayMonitor"
cp "$ROOT_DIR/Resources/DisplayMonitor.icns" "$BUNDLE/Contents/Resources/"
cp "$ROOT_DIR/Sources/DisplayMonitor/Resources/capture-concurrency-matrix-v1.json" "$BUNDLE/Contents/Resources/"
if [[ -d "$BIN_DIR/DisplayMonitor_DisplayMonitor.bundle" ]]; then
  cp -R "$BIN_DIR/DisplayMonitor_DisplayMonitor.bundle" "$BUNDLE/Contents/Resources/"
fi
cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DisplayMonitor</string>
<key>CFBundleIdentifier</key><string>com.hanshuai.DisplayMonitor</string>
<key>CFBundleName</key><string>Display Monitor</string>
<key>CFBundleDisplayName</key><string>Display Monitor</string>
<key>CFBundleIconFile</key><string>DisplayMonitor.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.1</string>
<key>CFBundleVersion</key><string>59</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSScreenCaptureUsageDescription</key><string>Display Monitor needs screen recording access for display preview, screenshots, and region recording.</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSApplicationSupportsSecureRestorableState</key><true/>
</dict></plist>
PLIST
if [[ "$SIGN_IDENTITY" == - ]]; then
  codesign --force --sign - "$BUNDLE"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$BUNDLE"
fi
plutil -lint "$BUNDLE/Contents/Info.plist"
codesign --verify --deep --strict "$BUNDLE"
# Check again in case someone opened the previous staged copy during compilation.
PIDS="$(running_pids)"
for PID in $PIDS; do
  EXECUTABLE="$(ps -p "$PID" -o comm=)" || exit 1
  if [[ "$EXECUTABLE" == "$APP/Contents/MacOS/DisplayMonitor" ]]; then
    echo "The staged app was opened during compilation. Quit it normally and rebuild." >&2; exit 1
  fi
done
if [[ -L "$APP" ]]; then echo "Refusing to replace a symlink: $APP" >&2; exit 1; fi
rm -rf "$APP"
mv "$BUNDLE" "$APP"
echo "Built: $APP"
if [[ "$LAUNCH" == 1 ]]; then
  PIDS="$(running_pids)"
  if [[ -n "$PIDS" ]]; then echo "Another copy started; open the built app after quitting it." >&2; exit 1; fi
  /usr/bin/open "$APP"
fi
