#!/usr/bin/env bash
# Выходной VPS (Финляндия): 3x-ui только на localhost + VLESS Reality на 443.
# Nginx на 443 не ставит. Запускать от root на чистой FI.
set -euo pipefail

XUI_INSTALL_URL="${XUI_INSTALL_URL:-https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh}"
XUI_BIN="${XUI_BIN:-/usr/local/x-ui/x-ui}"
XUI_DB="${XUI_DB:-/etc/x-ui/x-ui.db}"
STATE="${STATE:-/root/fi-exit.env}"
EXIT_RAW_BASE="${EXIT_RAW_BASE:-https://raw.githubusercontent.com/cocatman/lopata/cursor/infrastructure-landing-313e}"
PANEL_PORT="${PANEL_PORT:-23175}"
DEST="${DEST:-www.microsoft.com:443}"
SNI="${SNI:-www.microsoft.com}"
REMARK="${REMARK:-fi-exit}"

CLEANUP_FILES=()
INSTALLED_XUI_THIS_RUN=0
INBOUND_CREATED=0

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
log() { printf '==> %s\n' "$*"; }

remember_temp() { CLEANUP_FILES+=("$1"); }
cleanup() {
  if [[ "${#CLEANUP_FILES[@]}" -gt 0 ]]; then
    rm -f "${CLEANUP_FILES[@]}"
  fi
}
trap cleanup EXIT

here() {
  local src="${BASH_SOURCE[0]:-}"
  if [[ -n "$src" && -f "$src" ]]; then
    (cd "$(dirname "$src")" && pwd)
  else
    printf ''
  fi
}

fetch_lib() {
  local name="$1"
  local dest
  dest="$(mktemp)"
  remember_temp "$dest"
  curl -fsSL "${EXIT_RAW_BASE}/deploy/lib/${name}" -o "$dest" \
    || die "не удалось загрузить deploy/lib/${name}"
  # shellcheck disable=SC1090
  source "$dest"
}

load_libs() {
  local script_dir
  script_dir="$(here)"
  if [[ -n "$script_dir" && -f "${script_dir}/lib/common.sh" && -f "${script_dir}/lib/exit.sh" ]]; then
    # shellcheck source=lib/common.sh
    source "${script_dir}/lib/common.sh"
    # shellcheck source=lib/exit.sh
    source "${script_dir}/lib/exit.sh"
    return 0
  fi
  fetch_lib common.sh
  fetch_lib exit.sh
}

xui_installed() {
  systemctl list-unit-files --type=service 2>/dev/null | grep -qE '^x-ui(\.service)?'
}

sqlite_exec() {
  sqlite3 -cmd '.timeout 5000' "$XUI_DB" "$1"
}

set_xui_setting() {
  local key="$1"
  local value="$2"
  local count
  [[ -f "$XUI_DB" ]] || die "нет базы 3x-ui: ${XUI_DB}"
  count="$(sqlite_exec "SELECT COUNT(*) FROM settings WHERE key='$(sql_escape "$key")';")"
  if [[ "$count" -gt 0 ]]; then
    sqlite_exec "UPDATE settings SET value='$(sql_escape "$value")' WHERE key='$(sql_escape "$key")';"
  else
    sqlite_exec "INSERT INTO settings (key, value) VALUES ('$(sql_escape "$key")', '$(sql_escape "$value")');"
  fi
}

load_state() {
  if [[ -r "$STATE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE"
    log "прочитан ${STATE}"
  fi
}

fill_secrets() {
  USERNAME="${USERNAME:-$(random_token 10)}"
  PASSWORD="${PASSWORD:-$(random_token 20)}"
  if [[ -z "${PANEL_PATH:-}" ]]; then
    PANEL_PATH="/$(random_token 18)/"
  fi
  PANEL_PATH="$(normalize_base_path "$PANEL_PATH")"
  [[ "$PANEL_PATH" != "/" ]] || die "путь панели не может быть /"
  PANEL_PORT="${PANEL_PORT:-23175}"
  DEST="${DEST:-www.microsoft.com:443}"
  SNI="${SNI:-www.microsoft.com}"
  SUB_ID="${SUB_ID:-$(random_token 12)}"
}

save_state() {
  umask 077
  cat >"$STATE" <<EOF
USERNAME=$(printf '%q' "$USERNAME")
PASSWORD=$(printf '%q' "$PASSWORD")
PANEL_PORT=$(printf '%q' "$PANEL_PORT")
PANEL_PATH=$(printf '%q' "$PANEL_PATH")
UUID=$(printf '%q' "${UUID:-}")
PRIVATE_KEY=$(printf '%q' "${PRIVATE_KEY:-}")
PUBLIC_KEY=$(printf '%q' "${PUBLIC_KEY:-}")
SHORT_ID=$(printf '%q' "${SHORT_ID:-}")
DEST=$(printf '%q' "$DEST")
SNI=$(printf '%q' "$SNI")
SUB_ID=$(printf '%q' "${SUB_ID:-}")
EOF
  chmod 600 "$STATE"
}

port_in_use() {
  local port="$1"
  ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq ":${port}\$"
}

inbound_port_exists() {
  [[ -f "$XUI_DB" ]] || return 1
  local count
  count="$(sqlite_exec "SELECT COUNT(*) FROM inbounds WHERE port=443;")"
  [[ "${count:-0}" -gt 0 ]]
}

generate_reality_keys() {
  local xray_bin keys
  if [[ -n "${UUID:-}" && -n "${PRIVATE_KEY:-}" && -n "${PUBLIC_KEY:-}" && -n "${SHORT_ID:-}" ]]; then
    log "ключи Reality уже есть в ${STATE}"
    return 0
  fi
  xray_bin="$(ls /usr/local/x-ui/bin/xray* 2>/dev/null | head -1 || true)"
  [[ -n "$xray_bin" ]] || die "нет бинарника xray"
  keys="$("$xray_bin" x25519)"
  parse_x25519_output "$keys"
  [[ -n "${X25519_PRIVATE}" && -n "${X25519_PUBLIC}" ]] \
    || die "xray x25519 не вернул пару ключей:\n${keys}"
  PRIVATE_KEY="${PRIVATE_KEY:-$X25519_PRIVATE}"
  PUBLIC_KEY="${PUBLIC_KEY:-$X25519_PUBLIC}"
  UUID="${UUID:-$("$xray_bin" uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)}"
  SHORT_ID="${SHORT_ID:-$(openssl rand -hex 8)}"
}

write_json_temps() {
  SETTINGS_JSON="$(mktemp)"
  STREAM_JSON="$(mktemp)"
  SNIFF_JSON="$(mktemp)"
  remember_temp "$SETTINGS_JSON"
  remember_temp "$STREAM_JSON"
  remember_temp "$SNIFF_JSON"
  reality_vless_settings "$UUID" "$REMARK" "$SUB_ID" >"$SETTINGS_JSON"
  reality_stream_settings "$DEST" "$SNI" "$PRIVATE_KEY" "$PUBLIC_KEY" "$SHORT_ID" >"$STREAM_JSON"
  reality_sniffing >"$SNIFF_JSON"
}

panel_base() {
  printf 'http://127.0.0.1:%s%s' "$PANEL_PORT" "$PANEL_PATH"
}

try_panel_login() {
  local cookie="$1"
  local base body
  base="$(panel_base)"
  body="$(printf '{"username":%s,"password":%s}' \
    "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$USERNAME")" \
    "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$PASSWORD")")"
  if curl -sS -c "$cookie" -b "$cookie" \
      -H 'Content-Type: application/json' \
      -d "$body" \
      "${base}login" 2>/dev/null | grep -qi '"success"[[:space:]]*:[[:space:]]*true'; then
    return 0
  fi
  curl -sS -c "$cookie" -b "$cookie" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "username=${USERNAME}" \
    --data-urlencode "password=${PASSWORD}" \
    "${base}login" 2>/dev/null | grep -qi '"success"[[:space:]]*:[[:space:]]*true'
}

add_inbound_via_api() {
  local cookie payload resp
  cookie="$(mktemp)"
  payload="$(mktemp)"
  remember_temp "$cookie"
  remember_temp "$payload"
  try_panel_login "$cookie" || return 1
  python3 - "$SETTINGS_JSON" "$STREAM_JSON" "$SNIFF_JSON" "$payload" <<'PY'
import json, sys
settings = json.loads(open(sys.argv[1], encoding="utf-8").read())
stream = json.loads(open(sys.argv[2], encoding="utf-8").read())
sniff = json.loads(open(sys.argv[3], encoding="utf-8").read())
body = {
    "up": 0,
    "down": 0,
    "total": 0,
    "remark": "fi-exit",
    "enable": True,
    "expiryTime": 0,
    "listen": "",
    "port": 443,
    "protocol": "vless",
    "settings": settings,
    "streamSettings": stream,
    "sniffing": sniff,
}
open(sys.argv[4], "w", encoding="utf-8").write(json.dumps(body))
PY
  resp="$(curl -sS -b "$cookie" -H 'Content-Type: application/json' \
    -d @"$payload" "$(panel_base)panel/api/inbounds/add" || true)"
  printf '%s\n' "$resp" | grep -qi '"success"[[:space:]]*:[[:space:]]*true'
}

add_inbound_via_sqlite() {
  systemctl stop x-ui >/dev/null 2>&1 || true
  if ! python3 - "$XUI_DB" "$SETTINGS_JSON" "$STREAM_JSON" "$SNIFF_JSON" <<'PY'
import sqlite3, sys

db, settings_path, stream_path, sniff_path = sys.argv[1:5]
settings = open(settings_path, encoding="utf-8").read()
stream = open(stream_path, encoding="utf-8").read()
sniff = open(sniff_path, encoding="utf-8").read()
con = sqlite3.connect(db)
cur = con.cursor()
if cur.execute("SELECT COUNT(*) FROM inbounds WHERE port=443").fetchone()[0]:
    raise SystemExit(0)
cols = {row[1] for row in cur.execute("PRAGMA table_info(inbounds)")}
row = {
    "user_id": 1,
    "up": 0,
    "down": 0,
    "total": 0,
    "remark": "fi-exit",
    "enable": 1,
    "expiry_time": 0,
    "listen": "",
    "port": 443,
    "protocol": "vless",
    "settings": settings,
    "stream_settings": stream,
    "tag": "inbound-443",
    "sniffing": sniff,
}
keys = [k for k in row if k in cols]
if "port" not in keys or "settings" not in keys:
    raise SystemExit("inbounds table is missing required columns")
cur.execute(
    "INSERT INTO inbounds (%s) VALUES (%s)"
    % (",".join(keys), ",".join("?" * len(keys))),
    [row[k] for k in keys],
)
inbound_id = cur.lastrowid
tcols = {row[1] for row in cur.execute("PRAGMA table_info(client_traffics)")}
if tcols:
    trow = {
        "inbound_id": inbound_id,
        "enable": 1,
        "email": "fi-exit",
        "up": 0,
        "down": 0,
        "expiry_time": 0,
        "total": 0,
        "reset": 0,
        "last_online": 0,
    }
    tk = [k for k in trow if k in tcols]
    if tk:
        cur.execute(
            "INSERT INTO client_traffics (%s) VALUES (%s)"
            % (",".join(tk), ",".join("?" * len(tk))),
            [trow[k] for k in tk],
        )
con.commit()
PY
  then
    systemctl start x-ui
    return 0
  fi
  systemctl start x-ui
  return 1
}

ensure_reality_inbound() {
  if inbound_port_exists; then
    log "inbound на 443 уже есть"
    return 0
  fi
  if port_in_use 443; then
    die "порт 443 уже занят (не x-ui inbound). Освободите его — Reality должен слушать :443"
  fi
  write_json_temps
  if add_inbound_via_api; then
    INBOUND_CREATED=1
    log "inbound Reality создан через API панели"
    return 0
  fi
  log "API панели не принял inbound, пишем в sqlite"
  add_inbound_via_sqlite
  inbound_port_exists || die "не удалось создать inbound на 443"
  INBOUND_CREATED=1
  log "inbound Reality записан в базу"
}

wait_for_listen() {
  local port="$1" i
  for i in $(seq 1 20); do
    if port_in_use "$port"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

load_libs

[[ "$(id -u)" -eq 0 ]] || die "нужен root"
command -v apt-get >/dev/null || die "нужен Ubuntu/Debian"

if xui_installed && [[ ! -f "$STATE" ]]; then
  die "3x-ui уже стоит, а ${STATE} нет. Если это чистая FI — удалите /etc/x-ui и /usr/local/x-ui"
fi

load_state
fill_secrets

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl openssl ca-certificates ufw iproute2 sqlite3 python3 >/dev/null

if ! xui_installed; then
  log "ставим 3x-ui"
  tmp="$(mktemp)"
  remember_temp "$tmp"
  curl -fsSL "$XUI_INSTALL_URL" -o "$tmp"
  XUI_NONINTERACTIVE=1 \
    XUI_SSL_MODE=none \
    XUI_USERNAME="$USERNAME" \
    XUI_PASSWORD="$PASSWORD" \
    XUI_PANEL_PORT="$PANEL_PORT" \
    XUI_WEB_BASE_PATH="${PANEL_PATH#/}" \
    bash "$tmp"
  INSTALLED_XUI_THIS_RUN=1
fi

[[ -x "$XUI_BIN" ]] || die "нет $XUI_BIN"
[[ -f "$XUI_DB" ]] || die "нет базы 3x-ui: ${XUI_DB}"

log "панель только на 127.0.0.1"
if [[ "$INSTALLED_XUI_THIS_RUN" -eq 1 ]]; then
  "$XUI_BIN" setting \
    -username "$USERNAME" \
    -password "$PASSWORD" \
    -port "$PANEL_PORT" \
    -webBasePath "$PANEL_PATH" \
    -listenIP 127.0.0.1
else
  "$XUI_BIN" setting \
    -port "$PANEL_PORT" \
    -webBasePath "$PANEL_PATH" \
    -listenIP 127.0.0.1
fi

set_xui_setting webListen "127.0.0.1"
set_xui_setting webPort "$PANEL_PORT"
set_xui_setting webBasePath "$PANEL_PATH"
set_xui_setting webCertFile ""
set_xui_setting webKeyFile ""
set_xui_setting subEnable "false"
set_xui_setting subListen "127.0.0.1"

systemctl enable x-ui >/dev/null
systemctl restart x-ui
sleep 2
systemctl is-active --quiet x-ui || die "x-ui не запустился"
wait_for_listen "$PANEL_PORT" || die "панель 3x-ui не слушает :${PANEL_PORT}"

generate_reality_keys
save_state
ensure_reality_inbound
systemctl restart x-ui
sleep 2
systemctl is-active --quiet x-ui || die "x-ui не запустился после inbound"

if ! wait_for_listen 443; then
  log "предупреждение: :443 ещё не слушает — откройте панель, Save inbound, Restart Xray"
fi

ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null
ufw allow 443/tcp >/dev/null
ufw --force enable >/dev/null || true

pub_ip="$(curl -4 -fsS --max-time 8 https://api.ipify.org || true)"
share="$(vless_reality_uri "$UUID" "${pub_ip:-IP-ФИНЛЯНДИИ}" 443 "$PUBLIC_KEY" "$SHORT_ID" "$SNI" "$REMARK")"
save_state

cat <<EOF

Финляндия готова. Панель с улицы не открывается — только туннель.

  ssh -L ${PANEL_PORT}:127.0.0.1:${PANEL_PORT} root@${pub_ip:-IP-ФИНЛЯНДИИ}
  http://127.0.0.1:${PANEL_PORT}${PANEL_PATH}
  логин: ${USERNAME}
  пароль: ${PASSWORD}

Секреты: ${STATE}

vless:// для исходящего на secondgloru (не подписка :2096):

  ${share}

Поля, если вставляете вручную:
  address = ${pub_ip:-IP-ФИНЛЯНДИИ}
  port    = 443
  UUID    = ${UUID}
  flow    = xtls-rprx-vision
  pbk     = ${PUBLIC_KEY}
  sid     = ${SHORT_ID}
  sni     = ${SNI}
  dest    = ${DEST}
  fp      = firefox

На secondgloru: Outbounds → вставить vless:// → маршрут inbound телефона → это исходящее.
Проверка:

  curl -4 --connect-timeout 15 --max-time 20 -x socks5://127.0.0.1:10808 https://ifconfig.me

Должен вернуться IP Финляндии.

EOF
