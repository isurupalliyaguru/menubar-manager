#!/usr/bin/env bash
# Builds "MenuBar Manager.app" without opening Xcode.
#   ./build.sh                 -> release build, ad-hoc signed, into ./build
#   VERSION=1.2.0 ./build.sh   -> stamp version
#   SIGN_IDENTITY="Developer ID Application: You (TEAMID)" ./build.sh  -> real signing
#   UNIVERSAL=1 ./build.sh     -> arm64 + x86_64
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-$(date +%Y%m%d%H%M)}"
APP_NAME="MenuBar Manager"
OUT="build"
APP="$OUT/$APP_NAME.app"

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi

swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MenuBarManager" "$APP/Contents/MacOS/MenuBarManager"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/" && \
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"

IDENTITY="${SIGN_IDENTITY:--}"
if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP"
else
  if [[ "$IDENTITY" == Developer\ ID* ]]; then
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
  else
    codesign --force --sign "$IDENTITY" "$APP"
  fi
fi

(cd "$OUT" && rm -f MenuBarManager.zip && ditto -c -k --keepParent "$APP_NAME.app" MenuBarManager.zip)
echo "Built $APP"
echo "Zip:  $OUT/MenuBarManager.zip  sha256: $(shasum -a 256 "$OUT/MenuBarManager.zip" | cut -d' ' -f1)"
