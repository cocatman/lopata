# Две цепочки: FI-каскад с dpdns + CDN перед duckdns

**Goal:** Новый выход через Финляндию с российского `gloru.dpdns.org`. Старую цепочку `gloru.duckdns.org → krotman/basehole` обернуть Яндекс CDN со стороны клиента.

**Главное:** CDN закрывает только хоп **телефон → origin**. Каскад **origin → krotman/basehole** CDN не лечит.

---

## Сейчас делаем только цепочку A

```
телефон → Reality gloru.dpdns.org (secondgloru, РФ)
        → VPS Финляндия :443
        → интернет (IP Финляндии)
```

Без CDN, без krotman, без подписки `:2096`. `gloru.dpdns.org` не трогать (не CNAME).

### A1. Финляндия — вход Reality

- [ ] Ubuntu, `apt update`, 3x-ui
- [ ] Панель слушает `127.0.0.1` или нестандартный порт, не светить на 443
- [ ] Inbound: VLESS + Reality, **порт 443**, listen пустой / `0.0.0.0`
- [ ] Target: `www.microsoft.com:443` или `nvidia.com:443` (живой сайт, не localhost)
- [ ] Server Names / SNI: то же имя (`www.microsoft.com`)
- [ ] Min Client Ver: **пусто**
- [ ] Один shortId, скопировать
- [ ] Клиент: flow `xtls-rprx-vision`, fingerprint `firefox`
- [ ] Скопировать **vless://**, не URL подписки
- [ ] С secondgloru: `timeout 5 bash -c 'echo >/dev/tcp/IP-FI/443' && echo OPEN`

### A2. secondgloru — исходящее

- [ ] Не добавлять подписку FI
- [ ] Outbounds → вставить `vless://`
- [ ] Address = **IP Финляндии**, port `443` (не домен, если DNS капризничает)
- [ ] SNI / shortId / pbk / uuid / flow / firefox — как в inbound FI
- [ ] Panel outbound = пусто / `direct`
- [ ] Save, restart panel/Xray
- [ ] HTTP ping этого исходящего (DNS на secondgloru уже 77.88.8.8)

### A3. Маршрут и SOCKS-проверка

- [ ] Маршрут: inbound **телефона** → исходящее FI
- [ ] Временно SOCKS `127.0.0.1:10808` → то же исходящее FI
- [ ] На secondgloru:

```bash
curl -4 --connect-timeout 15 --max-time 20 \
  -x socks5://127.0.0.1:10808 https://ifconfig.me
```

Должен быть **IP Финляндии**. `connection to proxy closed` — сверка SNI/shortId/ключей, Target не localhost.

### A4. Телефон

- [ ] Клиент на `gloru.dpdns.org` (как сейчас, Reality входа)
- [ ] Сайт: `https://ifconfig.me` = Финляндия
- [ ] На FI в панели этот UUID онлайн
- [ ] SOCKS 10808 потом можно выключить

Стоп, если A1 порт 443 с secondgloru FAIL — тогда FI IP тоже режут, писать хостер/менять IP. Цепочку B (CDN) не начинать, пока A4 не зелёный.

---

## Цепочка B — старая + CDN спереди

```
телефон → Яндекс CDN
        → origin = машина gloru.duckdns.org :443 (Nginx + XHTTP)
        → уже существующие outbound на krotman и/или basehole
```

«Пустить CDN впереди duckdns» — да, так и задумано в гайде. Клиент больше не стучится в IP `gloru.duckdns.org`.

Нужны два имени (на одном нельзя A и CNAME):

| Имя | Тип | Куда |
|---|---|---|
| `origin.gloru.duckdns.org` или второй хост | A | IP машины duckdns |
| клиентский (`cdn.…` или отдельный dpdns, не тот что Reality) | CNAME | `*.yccdn.ru` |

`gloru.dpdns.org` лучше оставить входу A (secondgloru). Для CDN взять другое имя, иначе сломаете цепочку A.

На duckdns-машине:

- Публичный 443 = **Nginx** (не Reality). XHTTP на `127.0.0.1:8080`, секретный path.
- Если сейчас Reality сидит на 443 — сначала панель мимо 443, потом отдать 443 Nginx (как на basehole уже обжигались).
- Если Nginx уже на 443 — только добавить location, панель не сносить.
- Маршрут: inbound XHTTP → старые outbound krotman/basehole.

Клиент: адрес = CDN-домен, 443, **TLS**, path + GET. Не vless Reality на IP duckdns.

---

## Где цепочка B ломается

CDN помогает, только если **Яндекс дотягивается до origin:443**.

`gloru.duckdns.org` стоит в РФ, но **с него krotman и basehole уже доступны** (другой хостер/маршрут, не как secondgloru). Значит:

- CDN → origin: РФ → РФ, ТСПУ на krotman тут ни при чём.
- origin → krotman/basehole: оставляете как сейчас.
- CDN нужен, чтобы телефон не стучался в IP duckdns (маскировка / если с части сетей сам duckdns уже режут).

С secondgloru на krotman по-прежнему нельзя опираться — это другой выход из РФ.

Проверка до CNAME:

- С дома/телефона без VPN: `https://gloru.duckdns.org/` (заглушка) открывается — Яндекс origin, скорее всего, тоже доедет.
- С **самой** duckdns-машины: каскад на krotman/basehole живой. С secondgloru это не проверять.

---

## Как не перепутать

| Домен | Роль |
|---|---|
| `gloru.dpdns.org` | Вход Reality, РФ → Финляндия. Без CDN |
| IP Финляндии | Выход цепочки A |
| `gloru.duckdns.org` | Origin цепочки B (A-запись), Nginx+XHTTP |
| Новое имя под CDN | То, что вписывают в клиент цепочки B |
| krotman / basehole | Выходы цепочки B, только если origin до них уже ходит |

Не вешать Яндекс CNAME на `gloru.dpdns.org`, пока на нём живой Reality-вход на Финляндию.

---

## Порядок работ

1. Поднять каскад dpdns → Финляндия, проверить сайты с телефона.
2. Выяснить: duckdns-машина в РФ или нет, открыт ли с Яндекса/РФ её :443, жив ли с неё каскад на krotman/basehole.
3. Только если origin доступен и каскад с него живой — XHTTP+Nginx и CDN перед duckdns.
4. Старых Reality-клиентов duckdns перевести на CDN-имя.

## Готово когда

- Цепочка A: телефон на `gloru.dpdns.org`, `ifconfig.me` = Финляндия.
- Цепочка B (если делаете): телефон на CDN-имя, `ifconfig.me` = krotman или basehole, панель duckdns не отвалилась.
