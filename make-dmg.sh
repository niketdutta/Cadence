#!/bin/sh
# builds Cadence.app, then packages it as Cadence.dmg (drag-to-Applications layout)
set -e
cd "$(dirname "$0")"
./build.sh
rm -rf dmg-staging Cadence.dmg
mkdir dmg-staging
cp -R Cadence.app dmg-staging/
ln -s /Applications dmg-staging/Applications
hdiutil create -volname "Cadence" -srcfolder dmg-staging -ov -format UDZO Cadence.dmg
rm -rf dmg-staging
echo "created $(pwd)/Cadence.dmg"
