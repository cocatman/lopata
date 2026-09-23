# lopata

Скрипт быстрого развёртывания входного VPS: **3x-ui**, **Nginx**, сертификат Let's Encrypt и нейтральная заглушка.

На чистом Ubuntu/Debian получается такая схема:

```
https://<домен>/                 заглушка
https://<домен>/<секрет-панели>/ 3x-ui
https://<домен>/<секрет-подписки>/ подписка
```

Панель и подписка слушают только `127.0.0.1`. Наружу открыты 80 и 443.

## Перед запуском

1. Поднимите VPS (Ubuntu 22.04/24.04 или Debian 12).
2. Направьте A-запись домена на публичный IPv4 сервера.
3. Откройте в security group / firewall хостера порты **22, 80, 443**.
4. Зайдите по SSH как root.

## Установка из репозитория

```bash
git clone https://github.com/cocatman/lopata.git
cd lopata
sudo ./deploy/install.sh --domain example.com --email ops@example.com
```

Однострочник после попадания файлов в `main`:

```bash
curl -fsSL https://raw.githubusercontent.com/cocatman/lopata/main/deploy/install.sh \
  | sudo bash -s -- --domain example.com --email ops@example.com
```

Скрипт сам дотянет `deploy/lib/common.sh` и заглушку из этого репозитория.

## Полезные флаги

| Флаг | Зачем |
| --- | --- |
| `--panel-path /secret/` | свой путь панели вместо случайного |
| `--sub-path /sub/` | свой путь подписки |
| `--username` / `--password` | свои учётки панели |
| `--skip-dns-check` | если DNS ещё не доехал, но вы уверены |
| `--skip-3xui` | только Nginx + заглушка + сертификат |
| `--force-reconfigure` | перенастроить уже стоящий 3x-ui, если нет `/root/gloru-bootstrap.env` |
| `--yes` | без вопроса «продолжить?» |

Повторный запуск подхватывает секреты из `/root/gloru-bootstrap.env` и не сбрасывает пароль панели, если вы не передали `--username` / `--password`. Если 3x-ui уже стоит, а state-файла нет, скрипт остановится и попросит `--force-reconfigure`.

## Что сделать после установки

1. Откройте URL панели из вывода скрипта и смените пароль, если ставили дефолтный из лога.
2. В 3x-ui создайте inbound **VLESS + Reality** (обычно порт 443, fingerprint `firefox`).
3. Если Reality должен занять публичный 443, перенесите Nginx на `127.0.0.1:8443` и поставьте Reality dest в `127.0.0.1:8443`.
4. Клиентские ссылки берите из панели; URI подписки уже `https://<домен>/<секрет-подписки>/`.

## Проверка локально

```bash
bash tests/deploy/test_common.sh
```

Тесты покрывают нормализацию путей, рендер Nginx и разбор аргументов. Сам установщик рассчитан на VPS, не на этот репозиторий.
