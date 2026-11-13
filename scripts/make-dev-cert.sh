#!/usr/bin/env bash
# Optional, for contributors: creates a self-signed code-signing identity in your
# login keychain so rebuilds keep the same signature. Without it, every rebuild is
# a "new app" to macOS and you must re-grant Accessibility / Screen Recording.
#
# Usage:  ./scripts/make-dev-cert.sh
# Then:   SIGN_IDENTITY="MenuBarManager Local Dev" ./build.sh
set -euo pipefail
NAME="MenuBarManager Local Dev"
if security find-identity -p codesigning | grep -q "$NAME"; then
  echo "Identity '$NAME' already exists."; exit 0
fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 -config "$TMP/cert.cnf" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:tmp 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:tmp
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P tmp -T /usr/bin/codesign
echo "Created '$NAME'. Build with: SIGN_IDENTITY=\"$NAME\" ./build.sh"
