# Yandex CDN + VLESS XHTTP Implementation Plan

> **For agentic workers:** Origin is **krotman** (`krotman.duckdns.org`, `82.22.36.141`), not basehole. Nginx there already owns public :443 — add an XHTTP location, do not rebuild the site or steal :443 from Reality on another box.

**Goal:** Клиент из РФ ходит на `gloru.dpdns.org` через Яндекс CDN, origin — krotman (там уже Nginx + заглушка + панель), выход в интернет с krotman. secondgloru как вход больше не нужен.

**Architecture:** Телефон → CNAME `gloru.dpdns.org` на `*.yccdn.ru` → CDN тянет origin на krotman:443 → существующий Nginx отдаёт заглушку/панель и проксирует новый секретный path на Xray VLESS+XHTTP `127.0.0.1:8080`.

**Tech Stack:** уже стоящий Nginx на krotman, Let's Encrypt, 3x-ui / Xray 26.7+, VLESS XHTTP (`uplinkHTTPMethod=GET`), Yandex Cloud CDN + Certificate Manager.

---

## Риск, из‑за которого план может не взлететь

С secondgloru (РФ) до krotman уже было: ping есть, **TCP 22/80/443 — timeout**. Подсеть хостера в ТСПУ. Яндекс CDN тоже ходит на origin **из РФ**. Если с сети Яндекса до `82.22.36.141:443` так же глухо — CDN даст 502 и схема не заработает.

Сначала Task 0. Если origin с РФ не открывается даже «как сайт», не переключайте CNAME `gloru.dpdns.org`.

basehole в этом плане не участвует (панель там можно не трогать).

---

## Имена на том же домене

На одном имени нельзя одновременно A (origin) и CNAME (CDN).

| Имя | Тип | Куда | Зачем |
|---|---|---|---|
| `origin.gloru.dpdns.org` или второй хост `gloruorigin.dpdns.org` | A | `82.22.36.141` | сертификат origin, «домен источника» в YC |
| `gloru.dpdns.org` | CNAME | технический домен YC | адрес в клиенте |

Если dpdns не даёт поддомен — второй хост A на krotman. В клиенте всё равно `gloru.dpdns.org`.

`krotman.duckdns.org` можно оставить как есть для SSH/панели. В CDN-клиенте его не использовать.

Пока CNAME не переключён, `gloru.dpdns.org` может смотреть на secondgloru.

## Чего не делать

- Не сносить существующие `location` панели и подписки на krotman.
- Не вешать XHTTP на тот же path, что панель.
- Не ставить Reality на публичный 443 krotman (там уже Nginx).
- Не качать подписку с `:2096` с РФ.
- Не переключать CNAME, пока Task 0 и `curl https://origin…` с CDN/РФ не зелёные.

## Файлы в репозитории

- `deploy/cdn/nginx-origin.conf` — образец `location` для XHTTP (вмержить в уже стоящий сайт, не заменить всё)
- `deploy/cdn/inbound-xhttp.json` — inbound на `127.0.0.1:8080`

---

### Task 0: Доедет ли Яндекс до krotman

- [ ] С secondgloru: `timeout 5 bash -c 'echo >/dev/tcp/82.22.36.141/443' && echo OPEN || echo FAIL`
- [ ] С телефона **без VPN**: `curl -I --connect-timeout 8 https://krotman.duckdns.org/`
- [ ] Если оба FAIL — CDN из РФ, скорее всего, тоже не дотянет. Нужен другой origin (новый VPS не из этой подсети) или сначала смена IP krotman.
- [ ] Если с телефона/дома 443 OPEN, а с secondgloru FAIL — у хостера krotman, возможно, режут только часть сетей; CDN можно пробовать, но держать запасной план.

Стоп-критерий: оба пути FAIL → этот план не начинать.

---

### Task 1: Панель krotman не ломать

- [ ] Зайти в панель krotman так, как заходите обычно (через Nginx path, не через Reality fallback)
- [ ] `ss -lntp | grep -E ':443|:80|:8080|nginx|xray|x-ui'`
- [ ] На `:443` должен быть **nginx**, не xray
- [ ] Запомнить текущие location панели/подписки — их не удалять

Проверка: заглушка и панель krotman открываются как сейчас.

---

### Task 2: DNS origin

- [ ] A `origin.gloru.dpdns.org` (или запасной хост) → `82.22.36.141`
- [ ] `gloru.dpdns.org` CNAME на Яндекс **ещё не ставить**
- [ ] Проверка: `getent ahosts origin.gloru.dpdns.org` = `82.22.36.141`

---

### Task 3: Сертификат origin на krotman

Nginx уже на 80/443 — webroot проще, чем на basehole.

- [ ] ACME location на 80, если ещё нет
- [ ] `certbot certonly --webroot -w /var/www/certbot -d origin.gloru.dpdns.org --agree-tos -m EMAIL`
- [ ] Либо добавить `origin.gloru.dpdns.org` в уже существующий server_name и `certbot --nginx -d krotman.duckdns.org -d origin.gloru.dpdns.org` (не сносить старый cert)
- [ ] Проверка: `/etc/letsencrypt/live/origin.gloru.dpdns.org/fullchain.pem` или имя в существующем live/

---

### Task 4: Вмержить XHTTP location в текущий Nginx

Не подменять весь `default`/`stub`. Добавить в **тот же** server 443:

- [ ] Свой секретный path (не `/api/stream` из гайда, не path панели)
- [ ] Блок как в `deploy/cdn/nginx-origin.conf` (`proxy_pass http://127.0.0.1:8080`, buffering off, timeout 600s)
- [ ] `server_name` дополнить `origin.gloru.dpdns.org` (и старые имена оставить)
- [ ] `nginx -t && systemctl reload nginx`
- [ ] Проверка: старые `/` и панель живы; `curl -kI --resolve origin.gloru.dpdns.org:443:127.0.0.1 https://127.0.0.1/секрет/` пока может быть 502 — Xray ещё нет

---

### Task 5: XHTTP inbound в 3x-ui на krotman

- [ ] Обновить **ядро Xray** на krotman
- [ ] Входящие → расширенный шаблон → `deploy/cdn/inbound-xhttp.json`, path как в Nginx
- [ ] listen `127.0.0.1:8080`, не публичный 443
- [ ] Создать клиента, сохранить **vless://**
- [ ] Проверка: `ss -lntp | grep 8080` = `127.0.0.1:8080` xray
- [ ] С самого krotman: `curl -skI --resolve origin.gloru.dpdns.org:443:127.0.0.1 https://127.0.0.1/секретный-path` — уже не 502 от «connection refused»

---

### Task 6: Yandex Cloud CDN

- [ ] Certificate Manager: LE для **`gloru.dpdns.org`**, TXT у DNS
- [ ] Cloud CDN: origin = `origin.gloru.dpdns.org` или IP `82.22.36.141` + Host, HTTPS :443
- [ ] Логи и экранирование выключить
- [ ] Пока CNAME не переключать: в YC проверить статус origin (должен ходить на krotman)
- [ ] Если origin в консоли YC красный/timeout — ТСПУ до krotman, план стоп
- [ ] CNAME `gloru.dpdns.org` → технический домен YC
- [ ] 15–30 минут
- [ ] Проверка: `curl -I https://gloru.dpdns.org/` → заглушка krotman через CDN (не IP secondgloru)

---

### Task 7: Клиент

- [ ] Обновить Happ / v2rayNG / v2rayN / Shadowrocket
- [ ] Импорт **vless://** с krotman
- [ ] Address и SNI = `gloru.dpdns.org`, port `443`, security **TLS** (не Reality)
- [ ] Path и GET как на inbound
- [ ] Проверка: `ifconfig.me` = `82.22.36.141` (IP krotman)
- [ ] Клиент в панели krotman — онлайн

---

### Task 8: Выключить старый вход

- [ ] Task 7 стабилен → Reality на secondgloru можно не использовать
- [ ] Каскад на basehole не нужен
- [ ] Панель krotman по старому Nginx-пути оставить

---

## Если сломается

| Симптом | Что проверить |
|---|---|
| Task 0 оба FAIL | Другой origin / смена IP krotman |
| CDN origin timeout | ТСПУ до `82.22.36.141` из сети Яндекса |
| Панель krotman 502 | Случайно затёрли location панели |
| Клиент не коннектится | ядро/клиент, path, GET vs POST, SNI = `gloru.dpdns.org` |
| ifconfig.me не krotman | CNAME ещё на secondgloru |

## Готово когда

- `https://gloru.dpdns.org/` — заглушка krotman через Яндекс
- Секретный path с телефона даёт туннель
- Выходной IP — krotman
- Старая панель krotman на своём path жива
