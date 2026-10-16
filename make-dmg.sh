#!/bin/sh
# builds LockMusic.app, then packages it as LockMusic.dmg (drag-to-Applications layout)
set -e
cd "$(dirname "$0")"
./build.sh
rm -rf dmg-staging LockMusic.dmg
mkdir dmg-staging
cp -R LockMusic.app dmg-staging/
ln -s /Applications dmg-staging/Applications
hdiutil create -volname "LockMusic" -srcfolder dmg-staging -ov -format UDZO LockMusic.dmg
rm -rf dmg-staging
echo "created $(pwd)/LockMusic.dmg"
