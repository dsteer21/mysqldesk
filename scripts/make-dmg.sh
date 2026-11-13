#!/bin/zsh
# Builds MysqlDesk.app and packages it as build/MysqlDesk-<version>.dmg for installing on other Macs.
# The DMG opens to the app beside an Applications shortcut: drag one onto the other to install.
# With a Developer ID certificate and a notarytool keychain profile, the DMG is signed, notarised by Apple
# and stapled, so it opens on any Mac without a Gatekeeper warning.
set -euo pipefail

cd "${0:A:h}/.."
VERSION="${VERSION:-$(<VERSION)}"
# The Apple ID and team profile shared with GitDesk; created once with: xcrun notarytool store-credentials
NOTARY_PROFILE="${NOTARY_PROFILE:-gitdesk-notary}"
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

SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '$2 ~ /^Developer ID Application/ { print $2; exit }')}"
if [[ "$SIGN_IDENTITY" == "Developer ID Application"* ]]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
    if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        echo "→ Notarising with Apple (usually a few minutes)…"
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
        # Confirm Gatekeeper accepts it as a downloaded, notarised DMG.
        spctl --assess --type open --context context:primary-signature -v "$DMG"
    else
        echo "! Signed but NOT notarised: no \"$NOTARY_PROFILE\" keychain profile" >&2
    fi
fi
# Unversioned copy for GitHub's /releases/latest/download/MysqlDesk.dmg link.
cp "$DMG" build/MysqlDesk.dmg
echo "✓ Built $DMG and build/MysqlDesk.dmg ($(du -h "$DMG" | cut -f1))"
