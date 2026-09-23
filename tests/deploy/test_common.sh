#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../deploy/lib/common.sh
source "$ROOT/deploy/lib/common.sh"

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

# --- normalize_base_path ---
assert_eq "adds slashes to bare token" "/wegaw/" "$(normalize_base_path 'wegaw')"
assert_eq "keeps already-normalized path" "/panel/" "$(normalize_base_path '/panel/')"
assert_eq "adds trailing slash" "/secret/" "$(normalize_base_path '/secret')"
assert_eq "adds leading slash" "/secret/" "$(normalize_base_path 'secret/')"
assert_eq "root path stays root" "/" "$(normalize_base_path '/')"
assert_eq "empty path becomes root" "/" "$(normalize_base_path '')"

# --- sql_escape ---
assert_eq "escapes single quotes" "O''Reilly" "$(sql_escape "O'Reilly")"

# --- random_token ---
token="$(random_token 18)"
assert_eq "random token length" "18" "${#token}"
assert_match "random token is alphanumeric" '^[A-Za-z0-9]+$' "$token"

# --- apply_stub_domain ---
stub_in='Contact hello@gloru.dpdns.org and https://gloru.dpdns.org/'
stub_out="$(apply_stub_domain "$stub_in" 'newlab.example.com')"
assert_eq "rewrites decoy contact domain" \
  'Contact hello@newlab.example.com and https://newlab.example.com/' \
  "$stub_out"

# --- render_nginx_http ---
http_conf="$(render_nginx_http 'lab.example.com')"
assert_match "http listens on 80" 'listen 80;' "$http_conf"
assert_match "http has ACME webroot" 'location \^~ /\.well-known/acme-challenge/' "$http_conf"
assert_match "http redirects to https" 'return 301 https://\$host\$request_uri;' "$http_conf"
assert_match "http uses requested server_name" 'server_name lab.example.com;' "$http_conf"

# --- render_nginx_https ---
https_conf="$(render_nginx_https \
  'lab.example.com' \
  '/VVAyxFyTZbVq31eO1K/' \
  '23175' \
  'http' \
  '/wegaw/' \
  '2096' \
  'http')"

assert_match "https uses old-nginx http2 listen" 'listen 443 ssl http2;' "$https_conf"
assert_match "https uses domain cert" 'ssl_certificate     /etc/letsencrypt/live/lab.example.com/fullchain.pem;' "$https_conf"
assert_match "https roots decoy site" 'root /var/www/stub;' "$https_conf"
assert_match "https proxies panel path" 'location /VVAyxFyTZbVq31eO1K/' "$https_conf"
assert_match "https panel proxy_pass keeps slash" \
  'proxy_pass http://127.0.0.1:23175/VVAyxFyTZbVq31eO1K/;' \
  "$https_conf"
assert_match "https proxies subscription path" 'location /wegaw/' "$https_conf"
assert_match "https sub proxy_pass keeps slash" \
  'proxy_pass http://127.0.0.1:2096/wegaw/;' \
  "$https_conf"
assert_not_match "http backend does not disable ssl verify" \
  'proxy_ssl_verify off;' \
  "$https_conf"

https_tls="$(render_nginx_https \
  'lab.example.com' \
  '/panel/' \
  '39873' \
  'https' \
  '/sub/' \
  '2096' \
  'https')"
assert_match "https backend uses https proxy_pass" \
  'proxy_pass https://127.0.0.1:39873/panel/;' \
  "$https_tls"
assert_match "https backend disables ssl verify" 'proxy_ssl_verify off;' "$https_tls"

# --- require_secret_path ---
if require_secret_path panel '/wegaw/'; then
  assert_eq "secret path accepts token" "0" "0"
else
  assert_eq "secret path accepts token" "0" "1"
fi
if require_secret_path panel '/'; then
  assert_eq "secret path rejects root" "1" "0"
else
  assert_eq "secret path rejects root" "1" "1"
fi

# --- parse_args ---
PANEL_PATH='/keep/'
if parse_args --domain 'lab.example.com' --email 'ops@lab.example.com'; then
  assert_eq "parse_args domain" "lab.example.com" "$DOMAIN"
  assert_eq "parse_args email" "ops@lab.example.com" "$EMAIL"
  assert_eq "parse_args keeps existing panel path" "/keep/" "$PANEL_PATH"
else
  assert_eq "parse_args should succeed" "0" "1"
fi

if parse_args --domain 'lab.example.com'; then
  assert_eq "email is required" "1" "0"
else
  assert_eq "parse_args rejects missing email" "1" "1"
fi

if [[ "$failures" -eq 0 ]]; then
  printf '\nAll checks passed.\n'
  exit 0
fi

printf '\n%s check(s) failed.\n' "$failures"
exit 1
