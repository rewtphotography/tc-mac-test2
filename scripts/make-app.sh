#!/bin/bash
# Builds TrainCull.app from the Swift package and puts it in a disk image, build/TrainCull.dmg.
# Run on a Mac (the automated build does this). The arguments are the alpha number and the
# build number; the version itself is in packaging/VERSION.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(tr -d '[:space:]' < packaging/VERSION)"
ALPHA="${1:-0}"
BUILD="${2:-0}"

swift build -c release --arch arm64 --product TrainCull
BIN="$(swift build -c release --arch arm64 --show-bin-path)/TrainCull"

APP="build/TrainCull.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TrainCull"
sed -e "s/@VERSION@/$VERSION/" -e "s/@BUILD@/$BUILD/" -e "s/@RELEASE@/$VERSION alpha $ALPHA/" packaging/Info.plist > "$APP/Contents/Info.plist"

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

# A disk image to install from: open it and drag TrainCull onto the Applications folder.
# The file name never changes, so one link always downloads the newest build.
STAGE="build/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/TrainCull.app"
ln -s /Applications "$STAGE/Applications"
for attempt in 1 2 3; do
  if hdiutil create -volname "TrainCull" -srcfolder "$STAGE" -ov -format UDZO "build/TrainCull.dmg"; then break; fi
  if [ "$attempt" = 3 ]; then echo "error: the disk image couldn't be made" >&2; exit 1; fi
  sleep 5
done
rm -rf "$STAGE"
ls -lh build
