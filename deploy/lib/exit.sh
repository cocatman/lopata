#!/usr/bin/env bash
# Helpers for Finland/exit VPS bootstrap. Safe to source from tests.

_x25519_field() {
  local text="$1"
  local pattern="$2"
  printf '%s\n' "$text" | awk -F': *' -v pat="$pattern" '
    tolower($1) ~ pat {
      val = $2
      for (i = 3; i <= NF; i++) val = val ":" $i
      gsub(/^[ \t]+|[ \t]+$/, "", val)
      print val
      exit
    }
  '
}

reality_keys_complete() {
  [[ -n "${UUID:-}" && -n "${PRIVATE_KEY:-}" && -n "${PUBLIC_KEY:-}" && -n "${SHORT_ID:-}" ]]
}

should_refuse_foreign_xui() {
  local installed="${1:-0}"
  local has_state="${2:-0}"
  [[ "$installed" -eq 1 && "$has_state" -eq 0 ]]
}

parse_x25519_output() {
  local text="${1-}"
  X25519_PRIVATE=""
  X25519_PUBLIC=""
  X25519_PRIVATE="$(_x25519_field "$text" "private")"
  X25519_PUBLIC="$(_x25519_field "$text" "public")"
  if [[ -z "${X25519_PUBLIC}" ]]; then
    X25519_PUBLIC="$(_x25519_field "$text" "password")"
  fi
}

vless_reality_uri() {
  local uuid="$1"
  local address="$2"
  local port="$3"
  local pbk="$4"
  local sid="$5"
  local sni="$6"
  local remark="${7:-fi-exit}"
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=firefox&pbk=%s&sid=%s&type=tcp&headerType=none#%s\n' \
    "$uuid" "$address" "$port" "$sni" "$pbk" "$sid" "$remark"
}

extract_json_obj() {
  local text="${1-}"
  printf '%s' "$text" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
if not data.get("success"):
    raise SystemExit(0)
obj = data.get("obj", "")
if obj is None:
    raise SystemExit(0)
if isinstance(obj, (dict, list)):
    sys.stdout.write(json.dumps(obj, separators=(",", ":")))
else:
    sys.stdout.write(str(obj))
'
}

json_escape() {
  local value="${1-}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

reality_vless_settings() {
  local uuid
  local email
  local sub_id
  uuid="$(json_escape "$1")"
  email="$(json_escape "${2:-fi-exit}")"
  sub_id="$(json_escape "${3:-fiexit}")"
  cat <<EOF
{
  "clients": [
    {
      "id": "${uuid}",
      "flow": "xtls-rprx-vision",
      "email": "${email}",
      "limitIp": 0,
      "totalGB": 0,
      "expiryTime": 0,
      "enable": true,
      "tgId": "",
      "subId": "${sub_id}",
      "comment": "",
      "reset": 0
    }
  ],
  "decryption": "none",
  "encryption": "none",
  "fallbacks": []
}
EOF
}

reality_stream_settings() {
  local dest sni private_key public_key short_id
  dest="$(json_escape "$1")"
  sni="$(json_escape "$2")"
  private_key="$(json_escape "$3")"
  public_key="$(json_escape "$4")"
  short_id="$(json_escape "$5")"
  cat <<EOF
{
  "network": "tcp",
  "security": "reality",
  "externalProxy": [],
  "realitySettings": {
    "show": false,
    "xver": 0,
    "dest": "${dest}",
    "target": "${dest}",
    "serverNames": ["${sni}"],
    "privateKey": "${private_key}",
    "minClient": "",
    "minClientVer": "",
    "maxClient": "",
    "maxTimediff": 0,
    "shortIds": ["${short_id}"],
    "settings": {
      "publicKey": "${public_key}",
      "fingerprint": "firefox",
      "serverName": "",
      "spiderX": "/"
    }
  },
  "tcpSettings": {
    "acceptProxyProtocol": false,
    "header": { "type": "none" }
  }
}
EOF
}

reality_sniffing() {
  cat <<'EOF'
{
  "enabled": true,
  "destOverride": ["http", "tls", "quic", "fakedns"],
  "metadataOnly": false,
  "routeOnly": false
}
EOF
}
