#!/bin/bash
# Creates the self-signed "Tone Local Signing" code-signing identity in the login
# keychain, once. If it already exists this script does nothing. Never regenerate
# it: TCC permissions are tied to this certificate's hash.
set -euo pipefail

NAME="${TONE_SIGNING_IDENTITY:-Tone Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "Identity \"$NAME\" already exists. Not touching it."
  security find-certificate -c "$NAME" -Z "$KEYCHAIN" | grep SHA-1
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

cat > cert.cnf <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CNF

openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem \
  -days 3650 -config cert.cnf >/dev/null 2>&1

PASS="$(openssl rand -hex 16)"
openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -name "$NAME" \
  -out identity.p12 -passout "pass:$PASS" 2>/dev/null \
  || openssl pkcs12 -export -inkey key.pem -in cert.pem -name "$NAME" \
       -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
       -out identity.p12 -passout "pass:$PASS"

security import identity.p12 -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
echo "Created \"$NAME\" (valid 10 years)."
security find-certificate -c "$NAME" -Z "$KEYCHAIN" | grep SHA-1
