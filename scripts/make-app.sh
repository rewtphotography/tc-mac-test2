#!/bin/bash
# Builds TrainCull.app from the Swift package and zips it. Run on a Mac (the automated build
# does this); the build number is the first argument.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="0.1.0"
BUILD="${1:-0}"

swift build -c release --arch arm64 --product TrainCull
BIN="$(swift build -c release --arch arm64 --show-bin-path)/TrainCull"

APP="build/TrainCull.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TrainCull"
sed -e "s/@VERSION@/$VERSION/" -e "s/@BUILD@/$BUILD/" packaging/Info.plist > "$APP/Contents/Info.plist"

# The app icon, drawn in code so no image files live in the repository.
swift scripts/make-icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf build/AppIcon.iconset

# The app never uses the network. Fail the build if networking code is linked in.
if nm -u "$APP/Contents/MacOS/TrainCull" | grep -E 'URLSession|NSURLConnection|NWConnection|nw_connection|CFNetwork|CFSocket|CFStream'; then
  echo "error: the app references networking code" >&2
  exit 1
fi

# Ad-hoc signature: no Apple Developer account is involved.
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" = "com.traincull"

ditto -c -k --keepParent "$APP" "build/TrainCull-$VERSION-alpha$BUILD.zip"
ls -lh build
