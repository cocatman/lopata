#!/usr/bin/env bash
set -euo pipefail

BOOTSTRAP_STATE="${BOOTSTRAP_STATE:-/root/gloru-bootstrap.env}"
XUI_DB="${XUI_DB:-/etc/x-ui/x-ui.db}"
XUI_BIN="${XUI_BIN:-/usr/local/x-ui/x-ui}"
XUI_INSTALL_URL="${XUI_INSTALL_URL:-https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh}"
BOOTSTRAP_RAW_BASE="${BOOTSTRAP_RAW_BASE:-https://raw.githubusercontent.com/cocatman/lopata/main}"
NGINX_SITE="${NGINX_SITE:-/etc/nginx/sites-available/gloru}"

usage() {
  cat <<'EOF'
Развёртывание 3x-ui + Nginx + заглушка на чистом Ubuntu/Debian VPS.

Использование:
  sudo ./deploy/install.sh --domain example.com --email ops@example.com

Обязательные флаги:
  --domain NAME          домен, A-запись уже должна смотреть на этот сервер
  --email ADDRESS        почта для Let's Encrypt

Необязательные:
  --panel-path PATH      секретный путь панели (по умолчанию случайный)
  --sub-path PATH        секретный путь подписки (по умолчанию случайный)
  --panel-port PORT      локальный порт панели (23175)
  --sub-port PORT        локальный порт подписки (2096)
  --username NAME        логин панели
  --password SECRET      пароль панели
  --skip-dns-check       не сверять DNS с публичным IP
  --skip-ufw             не трогать ufw
  --skip-3xui            не ставить панель, только Nginx и заглушку
  --yes                  не спрашивать подтверждение

Повторный запуск безопасен: секреты берутся из /root/gloru-bootstrap.env.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '==> %s\n' "$*"
}

here() {
  local src="${BASH_SOURCE[0]:-}"
  if [[ -n "$src" && -f "$src" ]]; then
    cd "$(dirname "$src")" && pwd
  else
    printf ''
  fi
}

load_common() {
  local script_dir repo_common
  script_dir="$(here)"
  if [[ -n "$script_dir" && -f "${script_dir}/lib/common.sh" ]]; then
    # shellcheck source=lib/common.sh
    source "${script_dir}/lib/common.sh"
    REPO_ROOT="$(cd "${script_dir}/.." && pwd)"
    return 0
  fi

  repo_common="$(mktemp)"
  curl -fsSL "${BOOTSTRAP_RAW_BASE}/deploy/lib/common.sh" -o "$repo_common" \
    || die "не удалось загрузить deploy/lib/common.sh"
  # shellcheck disable=SC1090
  source "$repo_common"
  REPO_ROOT=""
}

need_root() {
  [[ "$(id -u)" -eq 0 ]] || die "запустите скрипт от root"
}

need_apt() {
  command -v apt-get >/dev/null 2>&1 || die "нужен Ubuntu или Debian с apt-get"
}

load_state() {
  if [[ -r "$BOOTSTRAP_STATE" ]]; then
    # shellcheck disable=SC1090
    source "$BOOTSTRAP_STATE"
    log "прочитан ${BOOTSTRAP_STATE}"
  fi
}

choose_secret_path() {
  local name="$1"
  local current="${2-}"
  if [[ -z "$current" ]]; then
    normalize_base_path "$(random_token "$3")"
    return 0
  fi
  current="$(normalize_base_path "$current")"
  require_secret_path "$name" "$current" || die "путь ${name} не может быть /"
  printf '%s\n' "$current"
}

fill_secrets() {
  PANEL_PORT="${PANEL_PORT:-23175}"
  SUB_PORT="${SUB_PORT:-2096}"
  PANEL_PATH="$(choose_secret_path panel "${PANEL_PATH:-}" 18)"
  SUB_PATH="$(choose_secret_path sub "${SUB_PATH:-}" 12)"
  [[ -n "${USERNAME:-}" ]] || USERNAME="$(random_token 10)"
  [[ -n "${PASSWORD:-}" ]] || PASSWORD="$(random_token 20)"
}

confirm_plan() {
  cat <<EOF

Будет установлено:
  домен:          ${DOMAIN}
  email:          ${EMAIL}
  панель:         https://${DOMAIN}${PANEL_PATH}
  подписка:       https://${DOMAIN}${SUB_PATH}
  3x-ui listen:   127.0.0.1:${PANEL_PORT} и 127.0.0.1:${SUB_PORT}

EOF
  if [[ "$ASSUME_YES" -eq 1 || ! -t 0 ]]; then
    return 0
  fi
  read -r -p "Продолжить? [y/N] " answer
  [[ "$answer" == [yY] || "$answer" == yes ]] || die "отменено"
}

public_ip() {
  curl -4 -fsS --max-time 8 https://api.ipify.org \
    || curl -4 -fsS --max-time 8 https://ifconfig.me/ip \
    || true
}

domain_ip() {
  if command -v getent >/dev/null 2>&1; then
    getent ahostsv4 "$DOMAIN" | awk '{print $1; exit}'
    return 0
  fi
  python3 - <<PY
import socket
print(socket.gethostbyname("${DOMAIN}"))
PY
}

check_dns() {
  [[ "$SKIP_DNS_CHECK" -eq 0 ]] || return 0
  local want have
  want="$(public_ip)"
  have="$(domain_ip || true)"
  [[ -n "$want" ]] || die "не удалось определить публичный IPv4 сервера"
  [[ -n "$have" ]] || die "домен ${DOMAIN} не резолвится"
  if [[ "$want" != "$have" ]]; then
    die "DNS ${DOMAIN} = ${have}, а IP сервера = ${want}. Поправьте A-запись или используйте --skip-dns-check"
  fi
  log "DNS ${DOMAIN} указывает на ${want}"
}

install_packages() {
  log "ставим пакеты"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq nginx certbot curl sqlite3 ufw openssl ca-certificates dnsutils >/dev/null
}

install_xui() {
  if [[ "$SKIP_3XUI" -eq 1 ]]; then
    log "пропуск установки 3x-ui"
    return 0
  fi
  if systemctl list-unit-files --type=service 2>/dev/null | grep -q '^x-ui'; then
    log "3x-ui уже установлен"
    return 0
  fi

  log "ставим 3x-ui в тихом режиме"
  local installer
  installer="$(mktemp)"
  curl -fsSL "$XUI_INSTALL_URL" -o "$installer"
  XUI_NONINTERACTIVE=1 \
    XUI_SSL_MODE=none \
    XUI_USERNAME="$USERNAME" \
    XUI_PASSWORD="$PASSWORD" \
    XUI_PANEL_PORT="$PANEL_PORT" \
    XUI_WEB_BASE_PATH="${PANEL_PATH#/}" \
    bash "$installer"
}

set_xui_setting() {
  local key="$1"
  local value="$2"
  local count
  [[ -f "$XUI_DB" ]] || die "нет базы 3x-ui: ${XUI_DB}"
  count="$(sqlite3 "$XUI_DB" "SELECT COUNT(*) FROM settings WHERE key='$(sql_escape "$key")';")"
  if [[ "$count" -gt 0 ]]; then
    sqlite3 "$XUI_DB" "UPDATE settings SET value='$(sql_escape "$value")' WHERE key='$(sql_escape "$key")';"
  else
    sqlite3 "$XUI_DB" "INSERT INTO settings (key, value) VALUES ('$(sql_escape "$key")', '$(sql_escape "$value")');"
  fi
}

configure_xui() {
  if [[ "$SKIP_3XUI" -eq 1 ]]; then
    return 0
  fi
  [[ -x "$XUI_BIN" ]] || die "не найден ${XUI_BIN}"

  log "привязываем панель к 127.0.0.1"
  "$XUI_BIN" setting \
    -username "$USERNAME" \
    -password "$PASSWORD" \
    -port "$PANEL_PORT" \
    -webBasePath "$PANEL_PATH" \
    -listenIP 127.0.0.1

  set_xui_setting webListen "127.0.0.1"
  set_xui_setting webPort "$PANEL_PORT"
  set_xui_setting webBasePath "$PANEL_PATH"
  set_xui_setting webCertFile ""
  set_xui_setting webKeyFile ""
  set_xui_setting webDomain "$DOMAIN"
  set_xui_setting subEnable "true"
  set_xui_setting subListen "127.0.0.1"
  set_xui_setting subPort "$SUB_PORT"
  set_xui_setting subPath "$SUB_PATH"
  set_xui_setting subDomain "$DOMAIN"
  set_xui_setting subURI "https://${DOMAIN}${SUB_PATH}"
  set_xui_setting subCertFile ""
  set_xui_setting subKeyFile ""
  set_xui_setting trustedProxyCIDRs "127.0.0.1/32,::1/128"

  systemctl enable x-ui >/dev/null
  systemctl restart x-ui
  sleep 2
  systemctl is-active --quiet x-ui || die "x-ui не запустился"
}

read_stub() {
  local remote
  if [[ -n "${REPO_ROOT:-}" && -f "${REPO_ROOT}/gloru-stub/index.html" ]]; then
    cat "${REPO_ROOT}/gloru-stub/index.html"
    return 0
  fi
  remote="$(mktemp)"
  if curl -fsSL "${BOOTSTRAP_RAW_BASE}/gloru-stub/index.html" -o "$remote"; then
    cat "$remote"
    return 0
  fi
  cat <<'EOF'
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Infrastructure</title></head>
<body><p>Infrastructure services are operational.</p></body>
</html>
EOF
}

deploy_stub() {
  log "кладём заглушку"
  mkdir -p /var/www/stub /var/www/certbot
  apply_stub_domain "$(read_stub)" "$DOMAIN" >/var/www/stub/index.html
  chown -R www-data:www-data /var/www/stub /var/www/certbot
}

write_nginx() {
  local kind="$1"
  mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
  if [[ "$kind" == http ]]; then
    render_nginx_http "$DOMAIN" >"$NGINX_SITE"
  else
    render_nginx_https \
      "$DOMAIN" \
      "$PANEL_PATH" \
      "$PANEL_PORT" \
      "$PANEL_SCHEME" \
      "$SUB_PATH" \
      "$SUB_PORT" \
      "$SUB_SCHEME" \
      >"$NGINX_SITE"
  fi
  ln -sfn "$NGINX_SITE" /etc/nginx/sites-enabled/gloru
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl enable nginx >/dev/null
  systemctl reload nginx || systemctl restart nginx
}

detect_scheme() {
  local port="$1"
  local path="$2"
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 3 "http://127.0.0.1:${port}${path}" || true)"
  if [[ "$code" =~ ^(200|204|301|302|307|308|401|403)$ ]]; then
    printf 'http\n'
    return 0
  fi
  code="$(curl -skS -o /dev/null -w '%{http_code}' --connect-timeout 3 "https://127.0.0.1:${port}${path}" || true)"
  if [[ "$code" =~ ^(200|204|301|302|307|308|401|403)$ ]]; then
    printf 'https\n'
    return 0
  fi
  printf 'http\n'
}

issue_cert() {
  if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
    log "сертификат ${DOMAIN} уже есть"
    return 0
  fi
  log "выпускаем Let's Encrypt"
  certbot certonly \
    --webroot \
    -w /var/www/certbot \
    -d "$DOMAIN" \
    --email "$EMAIL" \
    --agree-tos \
    --non-interactive \
    --keep-until-expiring

  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  cat >/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/bin/sh
nginx -t && systemctl reload nginx
EOF
  chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
}

maybe_ufw() {
  [[ "$SKIP_UFW" -eq 0 ]] || return 0
  command -v ufw >/dev/null 2>&1 || return 0
  log "открываем 22/80/443 в ufw"
  ufw allow OpenSSH >/dev/null || ufw allow 22/tcp >/dev/null || true
  ufw allow 80/tcp >/dev/null
  ufw allow 443/tcp >/dev/null
  ufw --force enable >/dev/null
}

save_state() {
  umask 077
  cat >"$BOOTSTRAP_STATE" <<EOF
DOMAIN=$(printf '%q' "$DOMAIN")
EMAIL=$(printf '%q' "$EMAIL")
PANEL_PATH=$(printf '%q' "$PANEL_PATH")
SUB_PATH=$(printf '%q' "$SUB_PATH")
PANEL_PORT=$(printf '%q' "$PANEL_PORT")
SUB_PORT=$(printf '%q' "$SUB_PORT")
USERNAME=$(printf '%q' "$USERNAME")
PASSWORD=$(printf '%q' "$PASSWORD")
PANEL_URL=$(printf '%q' "https://${DOMAIN}${PANEL_PATH}")
SUB_URI=$(printf '%q' "https://${DOMAIN}${SUB_PATH}")
EOF
  chmod 600 "$BOOTSTRAP_STATE"
}

print_summary() {
  cat <<EOF

Готово.

  Заглушка:   https://${DOMAIN}/
  Панель:     https://${DOMAIN}${PANEL_PATH}
  Подписка:   https://${DOMAIN}${SUB_PATH}
  Логин:      ${USERNAME}
  Пароль:     ${PASSWORD}

Секреты записаны в ${BOOTSTRAP_STATE} (режим 600).

Дальше в панели создайте inbound VLESS Reality на 443
(dest можно оставить внешний сайт или 127.0.0.1:8443, если
перенесёте Nginx с публичного 443 на localhost).

EOF
}

main() {
  load_common

  if [[ $# -eq 0 ]]; then
    usage
    exit 1
  fi

  load_state
  local rc=0
  parse_args "$@" && rc=0 || rc=$?
  if [[ "$rc" -eq 2 ]]; then
    usage
    exit 0
  fi
  if [[ "$rc" -ne 0 ]]; then
    usage
    die "нужны --domain и --email"
  fi

  need_root
  need_apt
  fill_secrets
  confirm_plan
  install_packages
  check_dns
  install_xui
  configure_xui
  deploy_stub
  write_nginx http
  issue_cert

  PANEL_SCHEME="http"
  SUB_SCHEME="http"
  if [[ "$SKIP_3XUI" -eq 0 ]]; then
    PANEL_SCHEME="$(detect_scheme "$PANEL_PORT" "$PANEL_PATH")"
    SUB_SCHEME="$(detect_scheme "$SUB_PORT" "$SUB_PATH")"
    log "бэкенд панели=${PANEL_SCHEME}, подписки=${SUB_SCHEME}"
  fi

  write_nginx https
  maybe_ufw
  save_state
  print_summary
}

main "$@"
