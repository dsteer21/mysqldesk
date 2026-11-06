#!/bin/zsh
# Builds MysqlDesk.app and packages it as build/MysqlDesk-<version>.dmg for installing on other Macs.
# The DMG opens to the app beside an Applications shortcut: drag one onto the other to install.
set -euo pipefail

cd "${0:A:h}/.."
VERSION="${VERSION:-1.0.0}"
DMG="build/MysqlDesk-${VERSION}.dmg"
STAGING="build/dmg"

VERSION="$VERSION" ./scripts/build-app.sh

echo "→ Packaging $DMG…"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R build/MysqlDesk.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# Compressed, read-only image.
hdiutil create -volname "MysqlDesk ${VERSION}" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGING"
# Unversioned copy for GitHub's /releases/latest/download/MysqlDesk.dmg link.
cp "$DMG" build/MysqlDesk.dmg
echo "✓ Built $DMG and build/MysqlDesk.dmg ($(du -h "$DMG" | cut -f1))"
