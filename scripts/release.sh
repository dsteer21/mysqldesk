#!/bin/zsh
# Publishes a GitHub release of the version in ./VERSION: ./scripts/release.sh (or ./scripts/release.sh 1.3.0 to double-check it)
# Builds the DMG, tags the pushed HEAD as v<version> and uploads MysqlDesk-<version>.dmg plus MysqlDesk.dmg,
# so https://github.com/dsteer21/mysqldesk/releases/latest/download/MysqlDesk.dmg always serves the newest build.
set -euo pipefail

cd "${0:A:h}/.."
VERSION="$(<VERSION)"
TAG="v${VERSION}"
GH="$(command -v gh || echo /opt/homebrew/bin/gh)"

fail() { echo "✗ $1" >&2; exit 1; }

[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || fail "VERSION should hold a version such as 1.3.0, not '$VERSION'"
[[ -z "${1:-}" || "$1" == "$VERSION" ]] || fail "VERSION says $VERSION, not $1: update the VERSION file and commit it first"
"$GH" auth status >/dev/null 2>&1 || fail "Log in to GitHub first: gh auth login"

# The release must match code that is on GitHub, so refuse uncommitted or unpushed work.
[[ -z "$(git status --porcelain)" ]] || fail "Commit your changes first (working tree isn't clean)"
git fetch -q origin
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[[ "$(git rev-parse HEAD)" == "$(git rev-parse "origin/$BRANCH" 2>/dev/null)" ]] || fail "Push $BRANCH first (HEAD doesn't match origin/$BRANCH)"
"$GH" release view "$TAG" >/dev/null 2>&1 && fail "Release $TAG already exists"

VERSION="$VERSION" ./scripts/make-dmg.sh

NOTES="Download **MysqlDesk.dmg**, open it and drag MysqlDesk onto Applications. Needs macOS 14 or later.

The app isn't notarised, so on first launch open **System Settings → Privacy & Security** and click **Open Anyway** (or run \`xattr -dr com.apple.quarantine /Applications/MysqlDesk.app\`)."

echo "→ Publishing $TAG…"
"$GH" release create "$TAG" "build/MysqlDesk-${VERSION}.dmg" build/MysqlDesk.dmg \
    --target "$(git rev-parse HEAD)" --title "MysqlDesk ${VERSION}" --notes "$NOTES" --generate-notes
echo "✓ Released $TAG"
echo "  Latest download: https://github.com/dsteer21/mysqldesk/releases/latest/download/MysqlDesk.dmg"
