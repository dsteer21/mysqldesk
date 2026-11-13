#!/bin/zsh
# Builds the Mac App Store version: a sandboxed MysqlDesk.app inside a signed installer package,
# build/MysqlDesk-<version>-appstore.pkg, ready to upload with Apple's Transporter app.
#
#   ./scripts/build-appstore.sh                 # the package for App Store Connect
#   ./scripts/build-appstore.sh --sandbox-test  # a sandboxed debug build to try locally (see below)
#
# Needs, once (see README → Mac App Store):
#   - an "Apple Distribution" (or "3rd Party Mac Developer Application") certificate,
#   - a "Mac Installer Distribution" (or "3rd Party Mac Developer Installer") certificate,
#   - a Mac App Store provisioning profile for uk.co.dave-steer.mysqldesk, downloaded to $PROFILE.
set -euo pipefail

cd "${0:A:h}/.."
VERSION="${VERSION:-$(<VERSION)}"
BUILD="${BUILD:-$(git rev-list --count HEAD)}"
ENTITLEMENTS="Resources/AppStore.entitlements"
PROFILE="${PROFILE:-$HOME/Downloads/MysqlDesk_App_Store.provisionprofile}"
BUNDLE_ID="uk.co.dave-steer.mysqldesk"

fail() { echo "✗ $1" >&2; exit 1; }
identity() { security find-identity -v ${=2:-} 2>/dev/null | awk -F'"' -v kind="$1" '$2 ~ kind { print $2; exit }'; }

# A debug build (so the DEBUG self-test hooks work) with the App Store sandbox, under a separate
# bundle ID so it gets its own sandbox container and never mixes with the real App Store app's data.
# Run it with: build/sandbox-test/MysqlDesk.app/Contents/MacOS/MysqlDesk (env vars pass through).
if [[ "${1:-}" == "--sandbox-test" ]]; then
    APP="build/sandbox-test/MysqlDesk.app"
    swift build
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    cp "$(swift build --show-bin-path)/MysqlDesk" "$APP/Contents/MacOS/MysqlDesk"
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
    [[ -f build/MysqlDesk.app/Contents/Info.plist ]] || ./scripts/build-app.sh
    cp build/MysqlDesk.app/Contents/Info.plist "$APP/Contents/Info.plist"
    plutil -replace CFBundleIdentifier -string "$BUNDLE_ID.sandbox-test" "$APP/Contents/Info.plist"
    # The application identifier only works with a provisioning profile, so leave it out here.
    TEST_ENTITLEMENTS="build/sandbox-test/test.entitlements"
    cp "$ENTITLEMENTS" "$TEST_ENTITLEMENTS"
    /usr/libexec/PlistBuddy -c 'Delete :com.apple.application-identifier' -c 'Delete :com.apple.developer.team-identifier' "$TEST_ENTITLEMENTS"
    SIGN_IDENTITY="${SIGN_IDENTITY:-$(identity "^Apple Development" "-p codesigning")}"
    codesign --force --sign "${SIGN_IDENTITY:--}" --entitlements "$TEST_ENTITLEMENTS" "$APP"
    echo "✓ Built $APP (sandboxed, container ~/Library/Containers/$BUNDLE_ID.sandbox-test)"
    exit 0
fi

APP_IDENTITY="${APP_IDENTITY:-$(identity "^(Apple Distribution|3rd Party Mac Developer Application)" "-p codesigning")}"
INSTALLER_IDENTITY="${INSTALLER_IDENTITY:-$(identity "^(Mac Installer Distribution|3rd Party Mac Developer Installer)")}"
[[ -n "$APP_IDENTITY" ]] || fail "No Apple Distribution certificate: create one in Xcode → Settings → Accounts → Manage Certificates"
[[ -n "$INSTALLER_IDENTITY" ]] || fail "No Mac Installer Distribution certificate: create one in Xcode → Settings → Accounts → Manage Certificates"
[[ -f "$PROFILE" ]] || fail "No provisioning profile at $PROFILE (set PROFILE to its path)"

# The profile must be for this app and team, or App Store Connect rejects the upload.
PROFILE_PLIST="$(mktemp)"
trap 'rm -f "$PROFILE_PLIST"' EXIT
security cms -D -i "$PROFILE" > "$PROFILE_PLIST"
PROFILE_APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$PROFILE_PLIST")"
EXPECTED_APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' "$ENTITLEMENTS")"
[[ "$PROFILE_APP_ID" == "$EXPECTED_APP_ID" ]] || fail "The profile is for $PROFILE_APP_ID, not $EXPECTED_APP_ID"

# Same build as the GitHub version, then re-signed for the App Store with the sandbox entitlements.
SIGN_IDENTITY=- VERSION="$VERSION" BUILD="$BUILD" ./scripts/build-app.sh
APP="build/appstore/MysqlDesk.app"
PKG="build/MysqlDesk-${VERSION}-appstore.pkg"
rm -rf build/appstore "$PKG"
mkdir -p build/appstore
cp -R build/MysqlDesk.app "$APP"
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
codesign --force --sign "$APP_IDENTITY" --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --strict "$APP"
echo "  Signed with: $APP_IDENTITY"

echo "→ Packaging $PKG…"
productbuild --component "$APP" /Applications --sign "$INSTALLER_IDENTITY" "$PKG" >/dev/null
echo "✓ Built $PKG (version $VERSION, build $BUILD)"
echo "  Upload it with Transporter (Mac App Store), signed in with your developer Apple ID."
