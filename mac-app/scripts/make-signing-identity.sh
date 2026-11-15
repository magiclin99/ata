#!/bin/bash
# One-time: creates the self-signed code-signing identity that every ATA release is signed with.
#
#   scripts/make-signing-identity.sh [secrets-dir]      (default: ~/ata-secrets/mac)
#
# Why: macOS keys the Bluetooth (TCC) approval to the app's designated requirement. With a
# self-signed certificate that requirement is "identifier io.github.magiclin99.ata.mac and certificate root = H<cert
# hash>", which stays the same for every build signed with this certificate. Lose the key and the next release is a
# "new app" to every user's Mac (one more Bluetooth prompt, re-pairing). Back the directory up (encrypted, offline).
#
# Creates, all mode 600 inside a mode 700 directory:
#   p12-password.txt            random password protecting the .p12
#   keychain-password.txt       random password of the dedicated keychain
#   ata-signing.p12             certificate + private key (the thing to back up and to put into GitHub Secrets)
#   ata-signing.keychain-db     dedicated keychain holding the identity, used by scripts/release.sh
#   ata-signing-cert.pem        public certificate only (not secret; also copied to signing/ in the repo)
#   github-secret-p12-base64.txt  base64 of the .p12, ready to paste into the MAC_SIGNING_P12_BASE64 secret
#
# Never touches the login keychain, trust settings, or (permanently) the keychain search list. Passwords are passed
# via files / stdin, never on a command line, and are never printed.
set -euo pipefail
umask 077

DIR="${1:-$HOME/ata-secrets/mac}"
PARENT="$(dirname "$DIR")"
mkdir -p "$DIR"
chmod 700 "$PARENT" "$DIR"
CN="ATA Release Signing (magiclin99)"
KC="$DIR/ata-signing.keychain-db"

if [ -e "$DIR/ata-signing.p12" ] || [ -e "$KC" ]; then
    echo "refusing to overwrite: $DIR already holds a signing identity" >&2
    exit 1
fi

openssl rand -hex 32 > "$DIR/p12-password.txt"
openssl rand -hex 32 > "$DIR/keychain-password.txt"

WORK="$(mktemp -d "$DIR/.work.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $CN
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

# RSA 3072, 20 years. The key never exists unencrypted outside $WORK (deleted on exit).
openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 7300 \
    -config "$WORK/cert.cnf" -keyout "$WORK/key.pem" -out "$DIR/ata-signing-cert.pem" 2>/dev/null
# PBE-SHA1-3DES / SHA-1 MAC: the PKCS#12 flavour every macOS `security import` accepts.
openssl pkcs12 -export -name "$CN" -inkey "$WORK/key.pem" -in "$DIR/ata-signing-cert.pem" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
    -passout "file:$DIR/p12-password.txt" -out "$DIR/ata-signing.p12"
base64 -i "$DIR/ata-signing.p12" > "$DIR/github-secret-p12-base64.txt"

# Dedicated keychain. `security create-keychain` appends it to the user's search list; put the list back exactly.
SEARCH_BEFORE=()
while IFS= read -r l; do l="${l#"${l%%[![:space:]]*}"}"; l="${l%\"}"; SEARCH_BEFORE+=("${l#\"}"); done \
    < <(security list-keychains -d user)
KCPW="$(cat "$DIR/keychain-password.txt")"
P12PW="$(cat "$DIR/p12-password.txt")"
# `security -i` reads commands from stdin, so the passwords never appear in a process argument list.
security -i <<EOF >/dev/null
create-keychain -p $KCPW $KC
set-keychain-settings $KC
unlock-keychain -p $KCPW $KC
import $DIR/ata-signing.p12 -k $KC -f pkcs12 -P $P12PW -T /usr/bin/codesign
set-key-partition-list -S apple-tool:,apple:,codesign: -s -k $KCPW $KC
EOF
unset KCPW P12PW
security list-keychains -d user -s "${SEARCH_BEFORE[@]}"
chmod 600 "$DIR"/*

SHA1="$(openssl x509 -in "$DIR/ata-signing-cert.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')"
echo "created identity \"$CN\" (certificate SHA-1 $SHA1) in $DIR"
security find-identity -p codesigning "$KC"
