#!/usr/bin/env bash
# One persistent, locally trusted identity per login Keychain. Never used for releases.
set -euo pipefail

name='HyperMug Local Development'
keychain="$(security login-keychain -d user 2>/dev/null | sed -E 's/^[[:space:]]*"?//; s/"?[[:space:]]*$//' || :)"
# Some Macs have no explicit login-keychain preference even though the normal
# login.keychain-db is present in the user's keychain search list.
if [ -z "$keychain" ]; then
  keychain="$HOME/Library/Keychains/login.keychain-db"
fi
if [ -z "$keychain" ] || [ ! -f "$keychain" ]; then
  echo 'error: macOS login Keychain is unavailable' >&2
  exit 1
fi

identity() {
  local matches
  matches="$(security find-identity -v -p codesigning "$keychain" | \
    grep -F "\"$name\"" | \
    sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]+([[:xdigit:]]{40}).*/\1/' || :)"
  if [ "$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l | tr -d ' ')" != 1 ]; then
    return 1
  fi
  [[ "$matches" =~ ^[[:xdigit:]]{40}$ ]] || return 1
  printf '%s\n' "$matches"
}

case "${1:-}" in
  identity)
    if ! identity; then
      echo 'error: HyperMug local code-signing identity unavailable; run make setup-dev once' >&2
      exit 1
    fi
    ;;
  setup)
    if identity >/dev/null; then
      echo 'HyperMug local signing identity already exists in the login Keychain.'
      exit 0
    fi
    work="$(mktemp -d "${TMPDIR:-/tmp}/hypermug-dev-signing.XXXXXX")"
    trap 'rm -rf "$work"' EXIT
    umask 077
    # Recover from an interrupted first setup by trusting the already imported
    # certificate. Never generate a replacement behind the developer's back.
    if security find-certificate -c "$name" -p "$keychain" >"$work/cert.pem" 2>/dev/null && \
       grep -q 'BEGIN CERTIFICATE' "$work/cert.pem"; then
      security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$work/cert.pem" >/dev/null
      if ! identity >/dev/null; then
        echo 'error: HyperMug certificate exists but is not a unique valid code-signing identity. Inspect it in Keychain Access.' >&2
        exit 1
      fi
      echo 'Existing HyperMug local signing identity is ready in the login Keychain.'
      exit 0
    fi
    # The unencrypted PEM and temporary PKCS#12 exist only in the private work dir.
    openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 \
      -subj "/CN=$name" \
      -addext 'basicConstraints=critical,CA:TRUE' \
      -addext 'keyUsage=critical,digitalSignature,keyCertSign' \
      -addext 'extendedKeyUsage=codeSigning' \
      -keyout "$work/key.pem" -out "$work/cert.pem" >/dev/null 2>&1
    passphrase="$(openssl rand -hex 24)"
    openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" \
      -out "$work/identity.p12" -passout "pass:$passphrase" >/dev/null 2>&1
    security import "$work/identity.p12" -k "$keychain" -f pkcs12 -P "$passphrase" \
      -T /usr/bin/codesign >/dev/null
    unset passphrase
    # Trust only this certificate for code signing in this user's trust domain.
    security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$work/cert.pem" >/dev/null
    if ! identity >/dev/null; then
      echo 'error: certificate was imported, but codesign cannot use it. Check Keychain Access and rerun setup after repair.' >&2
      exit 1
    fi
    echo 'HyperMug local signing identity created in the login Keychain.'
    ;;
  *)
    echo 'usage: helpers/dev-signing.sh {setup|identity}' >&2
    exit 2
    ;;
esac
