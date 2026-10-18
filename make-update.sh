#!/bin/sh
# Prepare signed GitHub Release assets without publishing them.
set -eu
cd "$(dirname "$0")"
./build.sh
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
mkdir -p updates
archive="updates/Cadence-$version.zip"
if [ -e "$archive" ]; then
    echo "Update archive already exists: $archive. Increment the version before preparing another release." >&2
    exit 1
fi
ditto -c -k --sequesterRsrc --keepParent Cadence.app "$archive"
.build/artifacts/sparkle/Sparkle/bin/generate_appcast \
    --account dev.niket.cadence \
    --download-url-prefix "https://github.com/niketdutta/Cadence/releases/download/$version/" \
    --maximum-deltas 0 \
    --versions "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist)" \
    updates
echo "Ready to upload $archive and updates/appcast.xml to GitHub Release $version."
