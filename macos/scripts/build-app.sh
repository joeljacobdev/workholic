#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build -c release
APP="dist/Workholic.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Workholic "$APP/Contents/MacOS/Workholic"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [ -n "${VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
codesign --force --sign - "$APP"
echo "$APP"
