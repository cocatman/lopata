#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../deploy/lib/exit.sh
source "$ROOT/deploy/lib/exit.sh"

failures=0

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok  %s\n' "$name"
    return 0
  fi
  printf 'FAIL  %s\n  expected: %q\n  actual:   %q\n' "$name" "$expected" "$actual"
  failures=$((failures + 1))
}

assert_match() {
  local name="$1" pattern="$2" actual="$3"
  if [[ "$actual" =~ $pattern ]]; then
    printf 'ok  %s\n' "$name"
    return 0
  fi
  printf 'FAIL  %s\n  pattern: %s\n  actual:\n%s\n' "$name" "$pattern" "$actual"
  failures=$((failures + 1))
}

assert_not_match() {
  local name="$1" pattern="$2" actual="$3"
  if [[ ! "$actual" =~ $pattern ]]; then
    printf 'ok  %s\n' "$name"
    return 0
  fi
  printf 'FAIL  %s\n  should not match: %s\n  actual:\n%s\n' "$name" "$pattern" "$actual"
  failures=$((failures + 1))
}

# --- parse_x25519_output: current xray (Password is public key) ---
parse_x25519_output $'PrivateKey: ADqgfJN12IYgAYgIxrOunpvUEWo4pBx5eHXlkRwPk2s\nPassword: 3oxSydKPtqIS6fnKXcfSzni5oPUNdoVaHlstWlMkrBA\nHash32: c4f5WfHx9KMH6XvmPxxkCd0DUP2kGVNYUGtegj41eZg\n'
assert_eq "new xray private key" "ADqgfJN12IYgAYgIxrOunpvUEWo4pBx5eHXlkRwPk2s" "${X25519_PRIVATE}"
assert_eq "new xray public key from Password" "3oxSydKPtqIS6fnKXcfSzni5oPUNdoVaHlstWlMkrBA" "${X25519_PUBLIC}"
assert_eq "new xray does not use Hash32 as public" "1" "$([[ "${X25519_PUBLIC}" != "c4f5WfHx9KMH6XvmPxxkCd0DUP2kGVNYUGtegj41eZg" ]] && echo 1 || echo 0)"

# --- parse_x25519_output: Password (PublicKey) label ---
parse_x25519_output $'PrivateKey: privAAA\nPassword (PublicKey): pubBBB\nHash32: hashCCC\n'
assert_eq "labeled Password (PublicKey) private" "privAAA" "${X25519_PRIVATE}"
assert_eq "labeled Password (PublicKey) public" "pubBBB" "${X25519_PUBLIC}"

# --- parse_x25519_output: classic Private key / Public key ---
parse_x25519_output $'Private key: oldPriv\nPublic key: oldPub\n'
assert_eq "classic private key" "oldPriv" "${X25519_PRIVATE}"
assert_eq "classic public key" "oldPub" "${X25519_PUBLIC}"

# --- parse_x25519_output: Public wins over Password if both present ---
parse_x25519_output $'PrivateKey: k1\nPublic key: realPub\nPassword: notThis\n'
assert_eq "explicit Public key wins" "realPub" "${X25519_PUBLIC}"

# --- vless_reality_uri ---
uri="$(vless_reality_uri \
  '11111111-2222-3333-4444-555555555555' \
  '203.0.113.10' \
  '443' \
  'pbkVALUE' \
  'abcd1234' \
  'www.microsoft.com' \
  'fi-exit')"
assert_eq "vless scheme and host" \
  "vless://11111111-2222-3333-4444-555555555555@203.0.113.10:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=firefox&pbk=pbkVALUE&sid=abcd1234&type=tcp&headerType=none#fi-exit" \
  "$uri"

# --- reality JSON builders ---
settings="$(reality_vless_settings '11111111-2222-3333-4444-555555555555' 'fi-exit' 'subid12')"
assert_match "settings has uuid" '"id": "11111111-2222-3333-4444-555555555555"' "$settings"
assert_match "settings has vision flow" '"flow": "xtls-rprx-vision"' "$settings"
assert_match "settings decryption none" '"decryption": "none"' "$settings"

stream="$(reality_stream_settings \
  'www.microsoft.com:443' \
  'www.microsoft.com' \
  'privKEY' \
  'pubKEY' \
  'deadbeef')"
assert_match "stream dest" '"dest": "www.microsoft.com:443"' "$stream"
assert_match "stream target alias" '"target": "www.microsoft.com:443"' "$stream"
assert_match "stream SNI" '"www.microsoft.com"' "$stream"
assert_match "stream private key" '"privateKey": "privKEY"' "$stream"
assert_match "stream public key" '"publicKey": "pubKEY"' "$stream"
assert_match "stream shortId" '"deadbeef"' "$stream"
assert_match "stream firefox fingerprint" '"fingerprint": "firefox"' "$stream"
assert_match "stream reality security" '"security": "reality"' "$stream"
assert_not_match "min client ver stays empty string" '"minClientVer": "[^"]+"' "$stream"

# --- reality_keys_complete is all-or-nothing ---
UUID="" PRIVATE_KEY="" PUBLIC_KEY="" SHORT_ID=""
if reality_keys_complete; then
  assert_eq "incomplete keys rejected" "1" "0"
else
  assert_eq "incomplete keys rejected" "1" "1"
fi
UUID="u" PRIVATE_KEY="priv" PUBLIC_KEY="" SHORT_ID="sid"
if reality_keys_complete; then
  assert_eq "partial keys rejected" "1" "0"
else
  assert_eq "partial keys rejected" "1" "1"
fi
UUID="u" PRIVATE_KEY="priv" PUBLIC_KEY="pub" SHORT_ID="sid"
if reality_keys_complete; then
  assert_eq "complete keys accepted" "0" "0"
else
  assert_eq "complete keys accepted" "0" "1"
fi

# --- refuse foreign 3x-ui without state ---
if should_refuse_foreign_xui 1 0; then
  assert_eq "refuse installed x-ui without state" "0" "0"
else
  assert_eq "refuse installed x-ui without state" "0" "1"
fi
if should_refuse_foreign_xui 1 1; then
  assert_eq "allow installed x-ui with state" "1" "0"
else
  assert_eq "allow installed x-ui with state" "1" "1"
fi
if should_refuse_foreign_xui 0 0; then
  assert_eq "allow fresh host without x-ui" "1" "0"
else
  assert_eq "allow fresh host without x-ui" "1" "1"
fi

assert_eq "missing_commands finds absent binary" \
  "definitely-not-a-cmd-xyz" \
  "$(missing_commands definitely-not-a-cmd-xyz)"
assert_eq "missing_commands skips present bash" "" "$(missing_commands bash)"
assert_eq "missing_commands reports only the missing one" \
  "definitely-not-a-cmd-xyz" \
  "$(missing_commands bash definitely-not-a-cmd-xyz)"

assert_eq "extract csrf obj" "tok-abc" "$(extract_json_obj '{"success":true,"obj":"tok-abc"}')"
assert_eq "extract csrf empty on failure json" "" "$(extract_json_obj '{"success":false,"msg":"no"}')"
assert_eq "extract csrf empty on garbage" "" "$(extract_json_obj 'not-json')"

if [[ "$failures" -eq 0 ]]; then
  printf '\nAll checks passed.\n'
  exit 0
fi

printf '\n%s check(s) failed.\n' "$failures"
exit 1
