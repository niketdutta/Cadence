#!/bin/sh
# builds Cadence.app (ad-hoc signed) and opens it
set -e
cd "$(dirname "$0")"
swift build -c release
rm -rf Cadence.app && mkdir -p Cadence.app/Contents/MacOS
cp .build/release/Cadence Cadence.app/Contents/MacOS/
cp Info.plist Cadence.app/Contents/
mkdir -p Cadence.app/Contents/Resources && cp AppIcon.icns Cadence.app/Contents/Resources/
codesign --force --sign - Cadence.app
[ "$1" = "run" ] && open Cadence.app
exit 0
