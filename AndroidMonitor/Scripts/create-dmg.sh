#!/bin/zsh
set -euo pipefail

cd "${0:A:h}/.."
./Scripts/build-release.sh
rm -rf dist/dmg-root dist/Mirra.dmg
mkdir -p dist/dmg-root
cp -R "dist/Mirra.app" dist/dmg-root/
ln -s /Applications dist/dmg-root/Applications
hdiutil create -volname "Mirra" -srcfolder dist/dmg-root -ov -format UDZO dist/Mirra.dmg
shasum -a 256 dist/Mirra.dmg > dist/Mirra.dmg.sha256

