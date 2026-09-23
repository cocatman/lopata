#!/usr/bin/env bash
# Shared helpers for Gloru VPS bootstrap. Safe to source from tests.

normalize_base_path() {
  local path="${1-}"
  path="${path#"${path%%[![:space:]]*}"}"
  path="${path%"${path##*[![:space:]]}"}"
  if [[ -z "$path" || "$path" == "/" ]]; then
    printf '/\n'
    return 0
  fi
  [[ "$path" == /* ]] || path="/$path"
  [[ "$path" == */ ]] || path="${path}/"
  printf '%s\n' "$path"
}

sql_escape() {
  local value="${1-}"
  value="${value//\'/\'\'}"
  printf '%s\n' "$value"
}

random_token() {
  local length="${1:-18}"
  local token=""
  local chars

  if [[ -r /dev/urandom ]] && command -v tr >/dev/null 2>&1; then
    token="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$length" || true)"
  fi

  while [[ "${#token}" -lt "$length" ]]; do
    chars="$(printf '%s' "$$${RANDOM}${SECONDS}" | sha256sum | awk '{print $1}')"
    token="${token}${chars}"
  done

  printf '%s\n' "${token:0:$length}"
}

apply_stub_domain() {
  local html="${1-}"
  local domain="${2-}"
  html="${html//gloru.dpdns.org/${domain}}"
  printf '%s' "$html"
}

_proxy_location() {
  local path="$1"
  local port="$2"
  local scheme="$3"
  local verify=""

  if [[ "$scheme" == "https" ]]; then
    verify=$'        proxy_ssl_verify off;\n'
  fi

  cat <<EOF
    location ${path} {
        proxy_pass ${scheme}://127.0.0.1:${port}${path};
${verify}        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
EOF
}

nginx_ipv6_listen() {
  local spec="$1"
  if [[ -e /proc/net/if_inet6 ]]; then
    printf '    listen [::]:%s;\n' "$spec"
  fi
}

render_nginx_http() {
  local domain="$1"
  cat <<EOF
server {
    listen 80;
$(nginx_ipv6_listen 80)
    server_name ${domain};

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
        default_type text/plain;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF
}

render_nginx_https() {
  local domain="$1"
  local panel_path="$2"
  local panel_port="$3"
  local panel_scheme="$4"
  local sub_path="$5"
  local sub_port="$6"
  local sub_scheme="$7"

  cat <<EOF
server {
    listen 443 ssl http2;
$(nginx_ipv6_listen '443 ssl http2')
    server_name ${domain};

    ssl_certificate     /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_timeout 1d;
    ssl_session_cache   shared:SSL:10m;

    root /var/www/stub;
    index index.html;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
        default_type text/plain;
    }

$(_proxy_location "$panel_path" "$panel_port" "$panel_scheme")

$(_proxy_location "$sub_path" "$sub_port" "$sub_scheme")

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
}

require_secret_path() {
  local path="${2-}"
  if [[ -z "$path" || "$path" == "/" ]]; then
    return 1
  fi
  return 0
}

parse_args() {
  DOMAIN=""
  EMAIL=""
  PANEL_PORT="${PANEL_PORT:-23175}"
  SUB_PORT="${SUB_PORT:-2096}"
  SKIP_DNS_CHECK="${SKIP_DNS_CHECK:-0}"
  SKIP_UFW="${SKIP_UFW:-0}"
  SKIP_3XUI="${SKIP_3XUI:-0}"
  ASSUME_YES="${ASSUME_YES:-0}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain)
        DOMAIN="${2-}"
        shift 2
        ;;
      --email)
        EMAIL="${2-}"
        shift 2
        ;;
      --panel-path)
        PANEL_PATH="${2-}"
        shift 2
        ;;
      --sub-path)
        SUB_PATH="${2-}"
        shift 2
        ;;
      --panel-port)
        PANEL_PORT="${2-}"
        shift 2
        ;;
      --sub-port)
        SUB_PORT="${2-}"
        shift 2
        ;;
      --username)
        USERNAME="${2-}"
        shift 2
        ;;
      --password)
        PASSWORD="${2-}"
        shift 2
        ;;
      --skip-dns-check)
        SKIP_DNS_CHECK=1
        shift
        ;;
      --skip-ufw)
        SKIP_UFW=1
        shift
        ;;
      --skip-3xui)
        SKIP_3XUI=1
        shift
        ;;
      --yes|-y)
        ASSUME_YES=1
        shift
        ;;
      --help|-h)
        return 2
        ;;
      *)
        printf 'unknown argument: %s\n' "$1" >&2
        return 1
        ;;
    esac
  done

  if [[ -z "$DOMAIN" || -z "$EMAIL" ]]; then
    return 1
  fi
  return 0
}
