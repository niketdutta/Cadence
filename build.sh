#!/bin/sh
# builds Cadence.app (ad-hoc signed) and opens it
set -e
cd "$(dirname "$0")"
swift build -c release
sparkle=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
test -d "$sparkle"
rm -rf Cadence.app && mkdir -p Cadence.app/Contents/MacOS
cp .build/release/Cadence Cadence.app/Contents/MacOS/
cp Info.plist Cadence.app/Contents/
mkdir -p Cadence.app/Contents/Resources && cp AppIcon.icns Cadence.app/Contents/Resources/
mkdir -p Cadence.app/Contents/Frameworks
ditto "$sparkle" Cadence.app/Contents/Frameworks/Sparkle.framework
codesign --force --sign - Cadence.app
[ "$1" = "run" ] && open Cadence.app
exit 0
