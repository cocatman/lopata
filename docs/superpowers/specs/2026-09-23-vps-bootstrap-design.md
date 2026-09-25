# VPS bootstrap: 3x-ui + Nginx + decoy site

## Goal

Give a single script that turns a fresh Ubuntu/Debian VPS into the
Gloru-style entry server: 3x-ui on localhost, Nginx with Let's Encrypt,
a public decoy site on `/`, and secret HTTPS paths for the panel and
subscription.

## Out of scope

- Creating VLESS Reality inbounds (done later in the panel).
- Cascading outbounds to another VPS.
- Keenetic / AmneziaWG / Mihomo client config.
- Changing existing panel, subscription, ACME, or Xray paths on an
  already-running server unless the operator passes explicit flags.

## Architecture

```
Internet
  :80  nginx  ACME webroot + HTTPS redirect
  :443 nginx  TLS for the domain
         /                         -> /var/www/stub  (decoy)
         /<panel-path>/            -> 127.0.0.1:<panel-port>
         /<sub-path>/              -> 127.0.0.1:<sub-port>
         /.well-known/acme-challenge/ -> /var/www/certbot

3x-ui
  webListen=127.0.0.1  HTTP  (Nginx terminates TLS)
  subListen=127.0.0.1  HTTP
```

3x-ui is installed unattended (`XUI_NONINTERACTIVE=1`, `XUI_SSL_MODE=none`)
and then rebound to localhost so the panel port is never public.

If a later 3x-ui release serves the panel over HTTPS on localhost, Nginx
uses `https://` and `proxy_ssl_verify off`.

## Operator contract

```bash
sudo ./deploy/install.sh --domain example.com --email ops@example.com
```

Required: DNS A/AAAA for `--domain` already points at this VPS.

The script writes credentials to `/root/gloru-bootstrap.env` (mode 600)
and prints the public panel URL, subscription base URI, and next steps
for a Reality inbound on 443.

The final Nginx site always keeps a port 80 server for ACME and
HTTP→HTTPS redirect alongside the TLS server on 443.

An already-installed 3x-ui without this repo's state file is left
untouched unless `--force-reconfigure` is passed.

## Acceptance

- `https://<domain>/` serves the infrastructure landing page.
- `https://<domain>/<panel-path>/` reaches 3x-ui.
- `https://<domain>/<sub-path>/` reaches the subscription server.
- Port 80 still answers ACME challenges.
- 3x-ui listen addresses are `127.0.0.1` only.
