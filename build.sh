#!/usr/bin/env bash
# Builds Para.app into ./build
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"
APP="build/Para.app"
IDENTITY="${CODESIGN_IDENTITY:--}"

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG" "${ARCH_FLAGS[@]}"

BIN="$(swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --show-bin-path)/Para"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Para"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -n "${VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION#v}" "$APP/Contents/Info.plist"
fi
if [[ -n "${BUILD_NUMBER:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
fi
if [[ -f Resources/Para.icns ]]; then
  cp Resources/Para.icns "$APP/Contents/Resources/Para.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string Para" "$APP/Contents/Info.plist" 2>/dev/null || true
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signing with identity: $IDENTITY"
if [[ "$IDENTITY" == "-" ]]; then
  # Ad-hoc signatures default to a cdhash-based designated requirement, which makes
  # macOS forget the Accessibility grant after every rebuild. Pin it to the bundle id.
  BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
  codesign --force --options runtime --sign - \
    --requirements "=designated => identifier \"$BUNDLE_ID\"" "$APP"
else
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict --verbose=1 "$APP"

if [[ "${PACKAGE:-0}" == "1" ]]; then
  APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
  ZIP="build/Para-$APP_VERSION.zip"
  echo "==> Packaging $ZIP"
  rm -f "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
  (cd build && shasum -a 256 "Para-$APP_VERSION.zip" | tee "Para-$APP_VERSION.zip.sha256")
fi

echo "==> Done: $APP"
echo "    Run with: open $APP"
