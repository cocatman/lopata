# Gloru infrastructure landing page

## Goal

Replace the generic server placeholder at `/var/www/stub/index.html` with a
static, neutral infrastructure-services landing page. Existing panel,
subscription, ACME, nginx, and Xray paths must remain unchanged.

## Design

- Visual style: dark slate/blue technical service page.
- Content: generic infrastructure lab, monitoring, deployment, and network
  services.
- No references to VPN, proxies, circumvention, Xray, ports, or the admin
  panel.
- Static HTML/CSS only; no backend, forms, external JavaScript, or external
  runtime dependencies.
- Root path `/` serves the landing page.
- Existing secret panel and subscription locations continue to be handled by
  nginx before the root fallback.

## Deployment

1. Back up the existing `/var/www/stub/index.html`.
2. Replace only that file.
3. Run `nginx -t`.
4. Reload nginx.
5. Check the root page and verify that panel/subscription paths still respond.

## Acceptance checks

- `https://gloru.dpdns.org/` renders the infrastructure landing page.
- `/VVAyxFyTZbVq31eO1K/` still reaches 3x-ui.
- ACME challenge handling remains available on port 80.
- No nginx configuration or routing changes are required.
