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

echo "==> bumping to $VERSION"
/usr/bin/sed -i '' -E "s/^( *MARKETING_VERSION: ).*/\1\"$VERSION\"/" project.yml
BUILD_NUMBER=$(( $(git rev-list --count HEAD) + 1 ))
/usr/bin/sed -i '' -E "s/^( *CURRENT_PROJECT_VERSION: ).*/\1\"$BUILD_NUMBER\"/" project.yml
xcodegen generate >/dev/null

echo "==> tests"
xcodebuild -project Cadence.xcodeproj -scheme Cadence \
  -destination 'platform=macOS' test 2>&1 | tail -3

echo "==> release build"
rm -rf dist
xcodebuild -project Cadence.xcodeproj -scheme Cadence \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath dist/build build 2>&1 | tail -2

APP="dist/build/Build/Products/Release/Cadence.app"
ZIP="dist/Cadence-$VERSION-macOS.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "==> packaged $(du -h "$ZIP" | cut -f1)"

# Sign the zip. Installed copies refuse an update they cannot verify, so a
# release without this is a release nobody can install.
echo "==> signing"
swift scripts/sign-release.swift sign "$ZIP"
[[ -f "$ZIP.sig" ]] || { echo "signing produced no .sig" >&2; exit 1; }

git add project.yml
git commit -m "Release $VERSION"
git tag "v$VERSION"
git push origin main --tags

gh release create "v$VERSION" "$ZIP" "$ZIP.sig" \
  --title "Cadence $VERSION" \
  --generate-notes \
  --notes-start-tag "$(git describe --abbrev=0 --tags "v$VERSION^" 2>/dev/null || echo '')"

echo "==> done: $(gh release view "v$VERSION" --json url -q .url)"
