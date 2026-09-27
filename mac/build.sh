#!/bin/sh
# Builds MagniGlass.app (universal: Apple silicon + Intel, macOS 12.3+). Needs the Xcode
# command line tools. Usage: mac/build.sh [version]   → out/MagniGlass.app
set -eu
cd "$(dirname "$0")/.."
VERSION="${1:-1.0.0}"
APP=out/MagniGlass.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

clang -fobjc-arc -O2 -Wall -Wno-deprecated-declarations \
  -arch arm64 -arch x86_64 -mmacosx-version-min=12.3 \
  -framework Cocoa -framework Carbon -framework ScreenCaptureKit -framework CoreMedia \
  -framework CoreVideo -framework QuartzCore -framework ImageIO -framework ServiceManagement \
  mac/MagniGlass.m core/lenscore.c -o "$APP/Contents/MacOS/MagniGlass"

sed "s/__VERSION__/$VERSION/g" mac/Info.plist > "$APP/Contents/Info.plist"

# App icon from the 1024 px render (tools/make-icons.sh).
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s mac/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) mac/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature (required on Apple silicon). CI re-signs with Developer ID and
# notarizes when the signing secrets are available (.github/workflows/build.yml).
codesign --force --sign - "$APP"
echo "Built $APP ($VERSION)"
