#!/bin/sh
# builds LockMusic.app (ad-hoc signed) and opens it
set -e
cd "$(dirname "$0")"
swift build -c release
rm -rf LockMusic.app && mkdir -p LockMusic.app/Contents/MacOS
cp .build/release/LockMusic LockMusic.app/Contents/MacOS/
cp Info.plist LockMusic.app/Contents/
codesign --force --sign - LockMusic.app
[ "$1" = "run" ] && open LockMusic.app
exit 0
