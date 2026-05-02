#!/usr/bin/env bash
# Sign, notarize, and staple a macOS .app bundle.
#
# Usage: scripts/sign-and-notarize.sh <path/to/Foo.app>
#
# Required env vars:
#   APPLE_ID                   Apple ID email used for notarization
#   APPLE_TEAM_ID              10-char Apple Developer Team ID
#   APPLE_APP_PASSWORD         App-specific password for APPLE_ID (notarytool)
#   DEVELOPER_ID_APPLICATION   Full common name of the signing identity, e.g.
#                              "Developer ID Application: Jane Doe (ABCDE12345)"
#
# Optional (CI keychain import; if both set, a temp keychain is created and
# the cert is imported before signing):
#   DEVELOPER_ID_CERT_P12_BASE64   base64-encoded .p12 export of the identity
#   DEVELOPER_ID_CERT_PASSWORD     password used when exporting the .p12
#
# Exits non-zero on any failure with a clear message.

set -euo pipefail

log()  { printf '\033[1;34m[sign]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[sign:FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $# -eq 1 ]] || fail "usage: $0 <path/to/Foo.app>"
APP_PATH="$1"
[[ -d "$APP_PATH" ]] || fail "app bundle not found: $APP_PATH"
[[ "$APP_PATH" == *.app ]] || fail "expected a .app bundle, got: $APP_PATH"

require() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then fail "missing required env var: $name"; fi
}
require APPLE_ID
require APPLE_TEAM_ID
require APPLE_APP_PASSWORD
require DEVELOPER_ID_APPLICATION

command -v codesign  >/dev/null || fail "codesign not on PATH (run on macOS)"
command -v xcrun     >/dev/null || fail "xcrun not on PATH (run on macOS)"
command -v ditto     >/dev/null || fail "ditto not on PATH"

KEYCHAIN_PATH=""
cleanup() {
  if [[ -n "$KEYCHAIN_PATH" && -f "$KEYCHAIN_PATH" ]]; then
    log "removing temp keychain"
    security delete-keychain "$KEYCHAIN_PATH" || true
  fi
}
trap cleanup EXIT

# ---- 1. Optional: import signing cert into a temp keychain (CI) -------------
if [[ -n "${DEVELOPER_ID_CERT_P12_BASE64:-}" ]]; then
  [[ -n "${DEVELOPER_ID_CERT_PASSWORD:-}" ]] \
    || fail "DEVELOPER_ID_CERT_P12_BASE64 set but DEVELOPER_ID_CERT_PASSWORD is not"
  log "importing signing certificate into a temporary keychain"

  : "${RUNNER_TEMP:=$(mktemp -d)}"
  KEYCHAIN_PATH="$RUNNER_TEMP/signing.keychain-db"
  KEYCHAIN_PASSWORD="$(openssl rand -base64 24)"
  P12_PATH="$RUNNER_TEMP/cert.p12"

  echo "$DEVELOPER_ID_CERT_P12_BASE64" | base64 --decode > "$P12_PATH" \
    || fail "failed to base64-decode DEVELOPER_ID_CERT_P12_BASE64"

  security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
  security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
  security import "$P12_PATH" -P "$DEVELOPER_ID_CERT_PASSWORD" \
    -A -t cert -f pkcs12 -k "$KEYCHAIN_PATH" \
    || fail "security import failed"
  security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null

  # Prepend our keychain to the search list so codesign finds the identity.
  ORIG_LIST=$(security list-keychains -d user | tr -d '"' | xargs)
  # shellcheck disable=SC2086
  security list-keychains -d user -s "$KEYCHAIN_PATH" $ORIG_LIST

  rm -f "$P12_PATH"
fi

# ---- 2. Verify the identity is available ------------------------------------
log "checking for signing identity: $DEVELOPER_ID_APPLICATION"
if ! security find-identity -v -p codesigning | grep -q "$DEVELOPER_ID_APPLICATION"; then
  security find-identity -v -p codesigning >&2 || true
  fail "signing identity not found in any keychain: $DEVELOPER_ID_APPLICATION"
fi

# ---- 3. Codesign with hardened runtime --------------------------------------
log "codesigning $APP_PATH"
codesign --force --options runtime --timestamp \
  --sign "$DEVELOPER_ID_APPLICATION" \
  "$APP_PATH" \
  || fail "codesign failed"

log "verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH" \
  || fail "codesign verify failed"

# ---- 4. Zip for notarization -----------------------------------------------
APP_DIR="$(cd "$(dirname "$APP_PATH")" && pwd)"
APP_NAME="$(basename "$APP_PATH")"
ZIP_PATH="$APP_DIR/${APP_NAME%.app}.zip"

log "zipping for notarization: $ZIP_PATH"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH" \
  || fail "ditto zip failed"

# ---- 5. Submit to notarytool, wait for result -------------------------------
log "submitting to notarytool (this can take several minutes)"
NOTARY_LOG="$(mktemp)"
if ! xcrun notarytool submit "$ZIP_PATH" \
      --apple-id "$APPLE_ID" \
      --team-id  "$APPLE_TEAM_ID" \
      --password "$APPLE_APP_PASSWORD" \
      --wait \
      --output-format plist > "$NOTARY_LOG"; then
  cat "$NOTARY_LOG" >&2 || true
  fail "notarytool submit failed"
fi
cat "$NOTARY_LOG"

STATUS=$(/usr/libexec/PlistBuddy -c "Print :status" "$NOTARY_LOG" 2>/dev/null || echo "unknown")
if [[ "$STATUS" != "Accepted" ]]; then
  SUBMISSION_ID=$(/usr/libexec/PlistBuddy -c "Print :id" "$NOTARY_LOG" 2>/dev/null || echo "")
  if [[ -n "$SUBMISSION_ID" ]]; then
    log "fetching notarization log for $SUBMISSION_ID"
    xcrun notarytool log "$SUBMISSION_ID" \
      --apple-id "$APPLE_ID" \
      --team-id  "$APPLE_TEAM_ID" \
      --password "$APPLE_APP_PASSWORD" >&2 || true
  fi
  fail "notarization status: $STATUS (expected Accepted)"
fi

# ---- 6. Staple --------------------------------------------------------------
log "stapling ticket to $APP_PATH"
xcrun stapler staple "$APP_PATH" || fail "stapler failed"
xcrun stapler validate "$APP_PATH" || fail "stapler validate failed"

# ---- 7. Final Gatekeeper assessment ----------------------------------------
log "spctl assessment"
spctl --assess --type execute --verbose=4 "$APP_PATH" \
  || fail "spctl assessment failed"

# Re-zip the stapled app so the artifact in $ZIP_PATH is the shippable one.
log "re-zipping stapled app"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

log "done: $APP_PATH"
log "shippable zip: $ZIP_PATH"
