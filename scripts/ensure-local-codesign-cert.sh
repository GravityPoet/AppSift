#!/bin/bash
set -euo pipefail

IDENTITY="AppSift Local Code Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

identity_exists() {
  /usr/bin/security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null \
    | /usr/bin/grep -F "\"$IDENTITY\"" >/dev/null
}

if identity_exists; then
  printf '%s\n' "$IDENTITY"
  exit 0
fi

if /usr/bin/security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "Error: a certificate named '$IDENTITY' exists but is not a valid code-signing identity." >&2
  echo "Remove or repair that certificate in Keychain Access before retrying." >&2
  exit 1
fi

WORK_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/appsift-codesign.XXXXXX")"
cleanup() {
  case "$WORK_DIR" in
    "${TMPDIR:-/tmp}"/appsift-codesign.*) /bin/rm -rf -- "$WORK_DIR" ;;
    *) echo "Refusing to remove unexpected temporary path: $WORK_DIR" >&2 ;;
  esac
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

umask 077
OPENSSL_CONFIG="$WORK_DIR/openssl.cnf"
KEY_PATH="$WORK_DIR/codesign.key"
CERTIFICATE="$WORK_DIR/codesign.crt"
PKCS12="$WORK_DIR/codesign.p12"
P12_PASSWORD="$(/usr/bin/uuidgen)"

/bin/cat >"$OPENSSL_CONFIG" <<EOF
[req]
distinguished_name = dn
x509_extensions = codesign_ext
prompt = no

[dn]
CN = $IDENTITY

[codesign_ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
basicConstraints = critical, CA:true
subjectKeyIdentifier = hash
EOF

/usr/bin/openssl req \
  -x509 \
  -newkey rsa:2048 \
  -nodes \
  -days 3650 \
  -keyout "$KEY_PATH" \
  -out "$CERTIFICATE" \
  -config "$OPENSSL_CONFIG" \
  >/dev/null 2>&1

/usr/bin/openssl pkcs12 \
  -export \
  -inkey "$KEY_PATH" \
  -in "$CERTIFICATE" \
  -out "$PKCS12" \
  -passout "pass:$P12_PASSWORD" \
  >/dev/null 2>&1

/usr/bin/security import "$PKCS12" \
  -k "$KEYCHAIN" \
  -P "$P12_PASSWORD" \
  -T /usr/bin/codesign \
  >/dev/null

# Trust is scoped to code signing. The private key remains in the login
# keychain and is never exported into the repository or printed to stdout.
/usr/bin/security add-trusted-cert \
  -d \
  -r trustRoot \
  -p codeSign \
  -k "$KEYCHAIN" \
  "$CERTIFICATE" \
  >/dev/null 2>&1

# The import ACL above is sufficient on most Macs. This best-effort partition
# update prevents non-interactive xcodebuild from showing a keychain prompt on
# login keychains that use the default empty automation password.
/usr/bin/security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s \
  -k "" \
  "$KEYCHAIN" \
  >/dev/null 2>&1 || true

if ! identity_exists; then
  echo "Error: failed to create local code-signing identity: $IDENTITY" >&2
  exit 1
fi

SMOKE_BINARY="$WORK_DIR/AppSiftSigningSmoke"
/bin/cp /bin/echo "$SMOKE_BINARY"
/usr/bin/codesign --force --sign "$IDENTITY" --timestamp=none "$SMOKE_BINARY" >/dev/null
/usr/bin/codesign --verify --strict "$SMOKE_BINARY"
if ! /usr/bin/codesign -d -r- "$SMOKE_BINARY" 2>&1 \
    | /usr/bin/grep -F 'certificate leaf = H"' >/dev/null; then
  echo "Error: local identity did not produce a certificate-backed requirement." >&2
  exit 1
fi

printf '%s\n' "$IDENTITY"
