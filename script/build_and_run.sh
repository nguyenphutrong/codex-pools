#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="CodexManager"
BUNDLE_ID="com.nguyenphutrong.CodexManager"
MIN_SYSTEM_VERSION="13.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON_SOURCE="$ROOT_DIR/CodexManager/Resources/AppIcon.png"
APP_ICON_FILE="$APP_NAME.icns"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

build_app_icon() {
  if [[ ! -f "$APP_ICON_SOURCE" ]]; then
    echo "missing app icon at $APP_ICON_SOURCE" >&2
    exit 1
  fi

  local iconset_root iconset
  iconset_root="$(mktemp -d "${TMPDIR:-/tmp}/$APP_NAME-iconset.XXXXXX")"
  iconset="$iconset_root/$APP_NAME.iconset"
  mkdir -p "$iconset"

  local entries=(
    "16 1 icon_16x16.png"
    "16 2 icon_16x16@2x.png"
    "32 1 icon_32x32.png"
    "32 2 icon_32x32@2x.png"
    "128 1 icon_128x128.png"
    "128 2 icon_128x128@2x.png"
    "256 1 icon_256x256.png"
    "256 2 icon_256x256@2x.png"
    "512 1 icon_512x512.png"
    "512 2 icon_512x512@2x.png"
  )

  local entry size scale filename pixels
  for entry in "${entries[@]}"; do
    read -r size scale filename <<<"$entry"
    pixels=$((size * scale))
    /usr/bin/sips -z "$pixels" "$pixels" "$APP_ICON_SOURCE" --out "$iconset/$filename" >/dev/null
  done

  /usr/bin/iconutil -c icns "$iconset" -o "$APP_RESOURCES/$APP_ICON_FILE"
  rm -rf "$iconset_root"
}

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

swift build
BUILD_BINARY="$(swift build --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
build_app_icon

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key>
  <string>$APP_ICON_FILE</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

xattr -cr "$APP_BUNDLE" >/dev/null 2>&1 || true
codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null
xattr -cr "$APP_BUNDLE" >/dev/null 2>&1 || true
touch "$APP_BUNDLE"
"$LSREGISTER" -u "$APP_BUNDLE" >/dev/null 2>&1 || true
"$LSREGISTER" -f "$APP_BUNDLE" >/dev/null 2>&1 || true

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
