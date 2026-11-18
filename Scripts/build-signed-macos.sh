#!/bin/bash
# Build a release with its persistent signing identity in a temporary keychain.
set -euo pipefail

: "${TAPSNAP_MAC_SIGNING_SHA1:?请为正式版配置签名证书指纹}"
: "${TAPSNAP_MAC_SIGNING_P12:?请为正式版配置签名证书 PKCS#12}"
: "${TAPSNAP_MAC_SIGNING_PASSWORD:?请配置 PKCS#12 的密码}"
[[ "$TAPSNAP_MAC_SIGNING_SHA1" =~ ^[[:xdigit:]]{40}$ ]] || { echo "签名证书指纹应为 40 位十六进制。" >&2; exit 1; }

root="$(cd "$(dirname "$0")/.." && pwd)"
certificate="$TAPSNAP_MAC_SIGNING_P12"
certificate_password="$TAPSNAP_MAC_SIGNING_PASSWORD"
unset TAPSNAP_MAC_SIGNING_P12 TAPSNAP_MAC_SIGNING_PASSWORD
work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/tapsnap-signing.XXXXXX")"
keychain="$work/release.keychain-db"
cleanup() {
  if [[ -f "$keychain" ]]; then security delete-keychain "$keychain" || true; fi
  rm -rf "$work"
}
trap cleanup EXIT

(umask 077; printf %s "$certificate" | /usr/bin/base64 -D > "$work/certificate.p12")
unset certificate
keychain_password="$(openssl rand -hex 32)"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 3600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$work/certificate.p12" -k "$keychain" -f pkcs12 -P "$certificate_password" -T /usr/bin/codesign >/dev/null
unset certificate_password
rm -f "$work/certificate.p12"
security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$keychain" >/dev/null
unset keychain_password

# codesign also consults the search list when resolving a signing identity.
# Deleting this keychain removes its entry without replacing other keychains.
security list-keychains -d user > "$work/search-list"
search_list=("$keychain")
while IFS='"' read -r _ existing _; do
  if [[ -n "$existing" && "$existing" != "$keychain" ]]; then search_list+=("$existing"); fi
done < "$work/search-list"
security list-keychains -d user -s "${search_list[@]}"

TAPSNAP_MAC_SIGNING_KEYCHAIN="$keychain" "$root/Scripts/build-app.sh" release
