# Yandex CDN + VLESS XHTTP Implementation Plan

> **For agentic workers:** This is an operations plan for live VPS (basehole + DNS + Yandex Cloud). Do not take public :443 from Reality until Nginx and the panel-on-20321 path are confirmed.

**Goal:** Клиент из РФ ходит на `gloru.dpdns.org` через Яндекс CDN, origin — basehole, выход в интернет с basehole. secondgloru как вход больше не нужен.

**Architecture:** Телефон → CNAME `gloru.dpdns.org` на `*.yccdn.ru` → CDN тянет origin по A-записи на IP basehole → Nginx :443 отдаёт заглушку и проксирует секретный путь на Xray VLESS+XHTTP `127.0.0.1:8080`. Reality с публичного 443 basehole снимается только после рабочего Nginx и доступа в панель мимо 443.

**Tech Stack:** Nginx, Let's Encrypt, 3x-ui / Xray 26.7+, VLESS XHTTP (`uplinkHTTPMethod=GET`), Yandex Cloud CDN + Certificate Manager.

---

## Имена на том же домене

На одном имени нельзя одновременно A (origin) и CNAME (CDN).

| Имя | Тип | Куда | Зачем |
|---|---|---|---|
| `origin.gloru.dpdns.org` или второй хост `gloruorigin.dpdns.org` | A | `194.147.35.214` | сертификат origin, «домен источника» в YC |
| `gloru.dpdns.org` | CNAME | технический домен YC | адрес в клиенте |

Если dpdns не даёт поддомен `origin.gloru.dpdns.org` — завести второй бесплатный хост (`gloruorigin.dpdns.org`) и его A на basehole. В клиенте всё равно будет `gloru.dpdns.org`.

Пока CNAME не переключён, `gloru.dpdns.org` может временно смотреть на secondgloru — не сносить вход, пока CDN не проверен.

## Чего не делать

- Не менять Reality Target/SNI, сидя в панели по `https://basehole.duckdns.org/` (снова выкинет).
- Не вешать панель 3x-ui на публичный 443 origin.
- Не качать подписку basehole `:2096` с РФ.
- Не ставить origin на secondgloru: ТСПУ до basehole останется.

## Файлы в репозитории

- `deploy/cdn/nginx-origin.conf` — Nginx origin (80 ACME + 443 заглушка + XHTTP location)
- `deploy/cdn/inbound-xhttp.json` — inbound 3x-ui / Xray на `127.0.0.1:8080`

---

### Task 1: Доступ к панели basehole мимо 443

- [ ] С secondgloru: `ssh root@194.147.35.214`
- [ ] `ss -lntp | grep -E 'x-ui|20321|2053'`
- [ ] С ноутбука: `ssh -L 20321:127.0.0.1:20321 root@194.147.35.214` (порт подставить свой)
- [ ] Открыть панель на `https://127.0.0.1:20321/...` и убедиться, что inbound/клиенты видны
- [ ] Reality на 443 **пока не трогать**

Проверка: панель открывается без `https://basehole.duckdns.org/`.

---

### Task 2: DNS origin

- [ ] Создать A `origin.gloru.dpdns.org` (или запасной хост) → `194.147.35.214`
- [ ] `gloru.dpdns.org` CNAME на Яндекс **ещё не ставить**
- [ ] Проверка: `getent ahosts origin.gloru.dpdns.org` = `194.147.35.214`

---

### Task 3: Сертификат origin на basehole

Пока Reality держит 443, выпуск только с **порта 80** (webroot) или DNS-01.

- [ ] На basehole: Nginx слушает 80, `location /.well-known/acme-challenge/`
- [ ] `certbot certonly --webroot -w /var/www/certbot -d origin.gloru.dpdns.org --agree-tos -m EMAIL`
- [ ] Проверка: есть `/etc/letsencrypt/live/origin.gloru.dpdns.org/fullchain.pem`

Если 80 занят/закрыт — DNS-01 у регистратора dpdns.

---

### Task 4: Nginx origin (ещё не забирать 443)

- [ ] Скопировать `deploy/cdn/nginx-origin.conf`, подставить домен и пути cert
- [ ] Придумать свой path вместо `/api/stream` (как панель и `/wegaw/`)
- [ ] `root` заглушки: `/var/www/stub` или `/var/www/html`
- [ ] Пока `listen 443` можно держать только на `127.0.0.1:8443` для проверки: `nginx -t && systemctl reload nginx`
- [ ] Проверка: `curl -kI --resolve origin.gloru.dpdns.org:8443:127.0.0.1 https://127.0.0.1:8443/` → заглушка

---

### Task 5: XHTTP inbound в 3x-ui

- [ ] Обновить **ядро Xray** на basehole (не только панель). Нужен XHTTP `uplinkHTTPMethod=GET`
- [ ] Панель только через туннель Task 1
- [ ] Входящие → расширенный шаблон → вставить `deploy/cdn/inbound-xhttp.json` с тем же path, что в Nginx
- [ ] Создать клиента, скопировать **vless://**, не sub `:2096`
- [ ] Проверка: `ss -lntp | grep 8080` = `127.0.0.1:8080` xray

---

### Task 6: Отдать публичный 443 Nginx

Только когда панель открывается с 20321/туннеля.

- [ ] Reality inbound: порт с 443 убрать или выключить (не менять dest, сидя на :443)
- [ ] Restart Xray, `ss -lntp | grep ':443'` — Xray больше нет
- [ ] Nginx: `listen 443 ssl http2` на `0.0.0.0`
- [ ] `nginx -t && systemctl reload nginx`
- [ ] Проверка с secondgloru: `curl -I --resolve origin.gloru.dpdns.org:443:194.147.35.214 https://origin.gloru.dpdns.org/` → заглушка

---

### Task 7: Yandex Cloud CDN

- [ ] Certificate Manager: LE для **`gloru.dpdns.org`**, проверка TXT у DNS
- [ ] Cloud CDN: origin = `origin.gloru.dpdns.org` (или IP + Host), origin protocol HTTPS :443
- [ ] Логи и экранирование выключить (как в гайде)
- [ ] CNAME `gloru.dpdns.org` → технический домен YC
- [ ] Подождать 15–30 минут
- [ ] Проверка: `curl -I https://gloru.dpdns.org/` → заглушка (через CDN, не IP secondgloru)

---

### Task 8: Клиент

- [ ] Обновить Happ / v2rayNG / v2rayN / Shadowrocket
- [ ] Импорт **vless://** с basehole
- [ ] Address и SNI = `gloru.dpdns.org`, port `443`, security **TLS** (не Reality)
- [ ] Path и `uplinkHTTPMethod=GET` как на inbound
- [ ] Проверка: `ifconfig.me` = `194.147.35.214` (или актуальный IP basehole)
- [ ] Клиент на basehole в панели — онлайн

---

### Task 9: Выключить старый вход

- [ ] Когда Task 8 стабилен — Reality на secondgloru можно не использовать
- [ ] Каскад gloru→basehole не нужен
- [ ] Подписку `:2096` с РФ не восстанавливать

---

## Если сломается

| Симптом | Что проверить |
|---|---|
| Снова выкинуло из панели на :443 | Только туннель/20321 |
| CDN 502 | origin A, Nginx 443, Host, cert origin |
| Клиент не коннектится | ядро/клиент слишком старые, path, GET vs POST, SNI = CDN-домен |
| ifconfig.me российский | клиент попал на secondgloru, CNAME ещё не сменился |
| Сайты не открываются, онлайн есть | DNS клиента, IPv6 |

## Готово когда

- `https://gloru.dpdns.org/` — заглушка через Яндекс
- Секретный path с телефона даёт туннель
- Выходной IP — basehole
- Панель basehole открывается без публичного 443
