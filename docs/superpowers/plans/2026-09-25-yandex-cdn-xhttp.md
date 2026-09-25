# Две цепочки: FI-каскад с dpdns + CDN перед duckdns

**Goal:** Новый выход через Финляндию с российского `gloru.dpdns.org`. Старую цепочку `gloru.duckdns.org → krotman/basehole` обернуть Яндекс CDN со стороны клиента.

**Главное:** CDN закрывает только хоп **телефон → origin**. Каскад **origin → krotman/basehole** CDN не лечит.

---

## Цепочка A — новая, без CDN

```
телефон → Reality gloru.dpdns.org (secondgloru, РФ)
        → VPS Финляндия :443
        → интернет (IP Финляндии)
```

Это отдельно и проще. С РФ до Финляндии ТСПУ обычно не глушит так, как подсеть krotman.

- [ ] На FI: 3x-ui, inbound Reality (или то, что уже умеете) на 443
- [ ] На secondgloru: исходящее на IP Финляндии, маршрут inbound телефона → этот outbound
- [ ] Проверка с secondgloru: SOCKS/HTTP ping и `curl` через туннель → IP Финляндии
- [ ] `gloru.dpdns.org` CNAME на Яндекс **не трогать** — это вход Reality

Делать **первой**. Не мешать с CDN на duckdns.

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

- С РФ (secondgloru): `timeout 5 bash -c 'echo >/dev/tcp/IP-DUCKDNS/443'`
- С самой duckdns-машины: каскад на krotman/basehole живой (клиент онлайн, HTTP ping)

Проверка origin: с Яндекса/дома `https://gloru.duckdns.org/` (заглушка) должна открываться. Каскад проверять **на самой duckdns-машине**, не с secondgloru.

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
