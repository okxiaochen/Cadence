#!/usr/bin/env bash
#
# Creates the self-signed code signing identity Cadence is signed with.
#
#   ./scripts/setup-signing-identity.sh
#
# Why bother, given this does nothing for Gatekeeper: macOS privacy permissions
# (TCC) are recorded against an app's *designated requirement*. Ad-hoc signing
# makes that requirement the binary's own cdhash, which changes on every build,
# so every install and every update looks like a brand new app and calendar
# access has to be granted again. Signing with one stable certificate makes the
# requirement `identifier … and certificate leaf = H"…"`, which survives
# rebuilds — for every user, not just here.
#
# Idempotent: if the identity already exists it is left alone.
set -euo pipefail

NAME="Cadence Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "identity already present: $NAME"
  security find-identity -v -p codesigning | grep "$NAME" || true
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "==> generating a 10-year code signing certificate"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -subj "/CN=$NAME/O=Cadence/C=US" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  2>/dev/null

# OpenSSL 3 defaults to AES-256 with a SHA-256 MAC, which Apple's importer
# rejects outright ("MAC verification failed"). These flags pin the container to
# the older algorithms Security.framework can actually read.
PASSPHRASE="cadence-import"
openssl pkcs12 -export -legacy -macalg sha1 \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/identity.p12" -passout "pass:$PASSPHRASE"

echo "==> importing into the login keychain"
# -T pre-authorises codesign so signing does not prompt for the key every time.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSPHRASE" \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null

echo "==> trusting it for code signing"
# User-domain trust only; no sudo, nothing added to the system store.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem" \
  || echo "note: could not set trust automatically — signing may still work"

echo
security find-identity -v -p codesigning | grep "$NAME" \
  || echo "note: not listed as a valid identity; scripts fall back to ad-hoc"
echo
echo "Done. Builds signed with this identity keep their calendar permission"
echo "across updates. Gatekeeper is unaffected — see docs/RELEASING.md."
