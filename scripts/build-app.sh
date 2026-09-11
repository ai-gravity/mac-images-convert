#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
VERSION="0.1.0-beta"
APP_NAME="Mac images convert"
APP_DIR="$ROOT_DIR/dist/$APP_NAME-$VERSION-macos-arm64.app"
CONTENTS="$APP_DIR/Contents"
ICON_SOURCE="$ROOT_DIR/Resources/AppIcon.png"
if [[ ! -f "$ICON_SOURCE" ]]; then
  print -u2 "Resources/AppIcon.png is missing."
  exit 1
fi

cd "$ROOT_DIR"
swift build -c release
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp .build/release/MacImagesConvert "$CONTENTS/MacOS/MacImagesConvert"
cp Resources/Info.plist "$CONTENTS/Info.plist"

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
sips -z 16 16 "$ICON_SOURCE" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 "$ICON_SOURCE" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ICON_SOURCE" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$ICON_SOURCE" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"
rm -rf "${ICONSET:h}"

# This is an ad-hoc signature for local beta testing. It is not a Developer ID signature.
codesign --force --deep --sign - "$APP_DIR"
rm -f "$ROOT_DIR/dist/$APP_NAME-$VERSION-macos-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ROOT_DIR/dist/$APP_NAME-$VERSION-macos-arm64.zip"
print "Built $APP_DIR"
print "Built $ROOT_DIR/dist/$APP_NAME-$VERSION-macos-arm64.zip"
