#!/bin/zsh
# Builds MysqlDesk.app into ./build. Pass --install to copy it into /Applications.
set -euo pipefail

cd "${0:A:h}/.."
APP="build/MysqlDesk.app"
VERSION="${VERSION:-$(<VERSION)}"

# Universal binary (Apple Silicon + Intel) so the app runs on any Mac with macOS 14+.
ARCHS=(--arch arm64 --arch x86_64)

echo "→ Compiling (release, universal)…"
swift build -c release "${ARCHS[@]}"

echo "→ Bundling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BIN_DIR="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"
cp "$BIN_DIR/MysqlDesk" "$APP/Contents/MacOS/MysqlDesk"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>MysqlDesk</string>
    <key>CFBundleDisplayName</key><string>MysqlDesk</string>
    <key>CFBundleIdentifier</key><string>uk.co.llexeter.mysqldesk</string>
    <key>CFBundleExecutable</key><string>MysqlDesk</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <!-- .sql files can be dropped on the app icon or opened with MysqlDesk from Finder.
         Alternate rank: MysqlDesk is offered, but doesn't take over as the default .sql app. -->
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>SQL Script</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key><array><string>org.iso.sql</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Sign with the same certificate every time, so macOS recognises each new build as the same app and
# Keychain "Always Allow" keeps working after updates. An ad-hoc signature (-) changes with every build,
# which makes macOS ask for the Keychain password again. Uses the first Apple Development certificate in
# the login keychain, or ad-hoc if there isn't one; set SIGN_IDENTITY to choose another (or - for ad-hoc).
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ { print $2; exit }')}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
codesign --force --sign "$SIGN_IDENTITY" "$APP"
[[ "$SIGN_IDENTITY" == "-" ]] && echo "  (ad-hoc signed: Keychain will ask again after each update)" || echo "  Signed with: $SIGN_IDENTITY"
echo "✓ Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf /Applications/MysqlDesk.app
    cp -R "$APP" /Applications/
    echo "✓ Installed to /Applications/MysqlDesk.app"
fi
