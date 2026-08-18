#!/usr/bin/env bash
# Cut a release: test, build, package, tag, publish.
#
#   ./scripts/release.sh 0.2.0
#
# Bumps MARKETING_VERSION in project.yml, so the version in the app bundle and
# the git tag can never drift apart.
set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "usage: $0 <version>   e.g. $0 0.2.0" >&2
  exit 1
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "version must look like 1.2.3" >&2
  exit 1
fi

cd "$(dirname "$0")/.."

if [[ -n "$(git status --porcelain)" ]]; then
  echo "working tree is dirty — commit first" >&2
  exit 1
fi

# What is published as the release body, and shown inside the app when an
# update is offered. Checked before the tests rather than after, because
# finding out at the end costs a full Release build to be told to go and write
# four lines.
NOTES=$(awk '/^## Unreleased$/{f=1;next} /^## /{f=0} f' CHANGELOG.md | sed '/^[[:space:]]*$/d')
if [[ -z "$NOTES" ]]; then
  echo "CHANGELOG.md has nothing under '## Unreleased'." >&2
  echo "These notes are shown in the app's update sheet, not just on GitHub —" >&2
  echo "somebody reads them to decide whether to install. Write them first." >&2
  exit 1
fi
NOTES_FILE="$(mktemp)"
awk '/^## Unreleased$/{f=1;next} /^## /{f=0} f' CHANGELOG.md > "$NOTES_FILE"

echo "==> bumping to $VERSION"
/usr/bin/sed -i '' -E "s/^( *MARKETING_VERSION: ).*/\1\"$VERSION\"/" project.yml
BUILD_NUMBER=$(( $(git rev-list --count HEAD) + 1 ))
/usr/bin/sed -i '' -E "s/^( *CURRENT_PROJECT_VERSION: ).*/\1\"$BUILD_NUMBER\"/" project.yml
xcodegen generate >/dev/null

# The entries just written become this version's section, and a fresh empty
# Unreleased takes their place.
awk -v ver="$VERSION" -v day="$(date +%Y-%m-%d)" '
  /^## Unreleased$/ { print; print ""; print "## " ver " — " day; next }
  { print }
' CHANGELOG.md > CHANGELOG.tmp && mv CHANGELOG.tmp CHANGELOG.md

echo "==> tests"
xcodebuild -project Cadence.xcodeproj -scheme Cadence \
  -destination 'platform=macOS' test 2>&1 | tail -3

# Sign with the stable self-signed identity when it is available. Passed on the
# command line rather than baked into project.yml so a fresh clone still builds
# — it just falls back to ad-hoc, and loses permission persistence.
SIGN_IDENTITY="Cadence Self-Signed"
SIGN_ARGS=()
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
  echo "==> signing identity: $SIGN_IDENTITY"
  SIGN_ARGS=(CODE_SIGN_IDENTITY="$SIGN_IDENTITY" CODE_SIGN_STYLE=Manual)
else
  echo "!! no signing identity — building ad-hoc." >&2
  echo "!! Calendar permission will reset for everyone on this update." >&2
  echo "!! Run ./scripts/setup-signing-identity.sh first." >&2
fi

echo "==> release build"
rm -rf dist
xcodebuild -project Cadence.xcodeproj -scheme Cadence \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath dist/build "${SIGN_ARGS[@]}" build 2>&1 | tail -2

APP="dist/build/Build/Products/Release/Cadence.app"
echo "==> designated requirement"
codesign -d -r- "$APP" 2>&1 | grep designated || true
ZIP="dist/Cadence-$VERSION-macOS.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "==> packaged $(du -h "$ZIP" | cut -f1)"

# Sign the zip. Installed copies refuse an update they cannot verify, so a
# release without this is a release nobody can install.
echo "==> signing"
swift scripts/sign-release.swift sign "$ZIP"
[[ -f "$ZIP.sig" ]] || { echo "signing produced no .sig" >&2; exit 1; }

git add project.yml CHANGELOG.md
git commit -m "Release $VERSION"
git tag "v$VERSION"
git push origin main --tags

gh release create "v$VERSION" "$ZIP" "$ZIP.sig" \
  --title "Cadence $VERSION" \
  --notes-file "$NOTES_FILE"

echo "==> done: $(gh release view "v$VERSION" --json url -q .url)"
