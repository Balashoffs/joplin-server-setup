# Дизайн: развёртывание Joplin Server на VPS (owl.hello-vanilla.ru)

**Дата:** 2026-05-01
**Домен:** owl.hello-vanilla.ru
**Целевая ОС:** Ubuntu 22.04 LTS

## 1. Цель

Развернуть на VPS self-hosted Joplin Server с TLS-доступом по адресу `https://owl.hello-vanilla.ru`. Стек должен быть воспроизводим (идемпотентные скрипты), переносим (всё в git-репозитории) и быть «хорошим соседом» для других веб-приложений на том же VPS.

## 2. Зафиксированные решения

| Решение | Значение | Обоснование |
|---|---|---|
| Реверс-прокси | nginx нативно на хосте | Простейший выпуск SSL через `certbot --nginx`; меньше движущихся частей |
| Сертификаты | Let's Encrypt через certbot, http-01 challenge | Стандартный путь, автообновление через systemd-таймер |
| База данных | PostgreSQL 16-alpine в Docker | Postgres 13 из публичных гайдов EOL с ноября 2025; 16 — стабильная, поддерживается |
| Storage driver Joplin | По умолчанию (всё в БД) | Бэкап = один `pg_dump`. При росте БД переключаемся на filesystem без миграции данных |
| Сценарий пользователей | Multi-user без SMTP | Подтверждено пользователем; админ заводит аккаунты вручную, пароли out-of-band |
| Бэкапы | Локальный cron + `pg_dump`, ротация 7 ежедневных + 4 еженедельных | Защита от ошибок и повреждения БД; не защищает от потери VPS — это явно |
| Версия Joplin | Закреплена тегом `JOPLIN_VERSION` в `.env`, не `:latest` | Контролируемые обновления |
| Путь проекта на VPS | `/opt/joplin/` | Стандартное место под опциональное ПО |
| Системный пользователь | `joplin` в группе `docker` | Не запускать стек от root |
| Расположение бэкапов | `/var/backups/joplin/` | Стандартный путь под `/var/backups` |

## 3. Предположения и границы

- На VPS работают **другие веб-приложения** (часть в Docker, часть как обычные сайты). Стек спроектирован чтобы:
  - не перетирать общие конфиги (`/etc/nginx/`, UFW-правила, Docker-сети других проектов);
  - именовать всё уникальным префиксом `joplin-` / `joplin_`;
  - документировать свой footprint в `README.md`.
- Предполагается, что **на VPS один общий nginx-host**, который терминирует TLS для всех веб-приложений. Если параллельно работает другой reverse-proxy (Traefik, Caddy, nginx в Docker) на 80/443 — этот дизайн неприменим без изменений.
- DNS A-запись `owl.hello-vanilla.ru → <IP VPS>` уже создана и распространилась.
- SSH на VPS — по ключу, на нестандартном порту (значение задаётся переменной `SSH_PORT` в `bootstrap.sh`).

## 4. Архитектура верхнего уровня

```
[client https]──443──▶[nginx host]──127.0.0.1:22300──▶[joplin-app]──joplin_default──▶[joplin-db]
                          ▲
                          │ certbot (Let's Encrypt) обновляет /etc/letsencrypt/...
                          │ certbot.timer (systemd) — auto-renew каждые 12h
```

- Nginx на хосте слушает 80 и 443. На 443 терминирует TLS, проксирует на `127.0.0.1:22300`.
- Joplin-контейнер публикует порт **только на loopback** (`127.0.0.1:22300:22300`) — наружу не торчит.
- Postgres-контейнер **не публикует портов вовсе** — доступен только по docker-сети `joplin_default` от сервиса `app`.
- Certbot работает в режиме `--nginx`: правит nginx-конфиг in-place, ставит `--deploy-hook "systemctl reload nginx"` для автоматического reload после продления.

## 5. Структура локального репозитория

```
joplin/
├── docker-compose.yml            # joplin-server + postgres
├── .env.example                  # шаблон, коммитится
├── .env                          # реальные секреты, в .gitignore
├── .gitignore
├── README.md                     # порядок развёртывания, footprint, удаление
├── docs/
│   └── superpowers/specs/2026-05-01-joplin-vps-deploy-design.md  # этот файл
├── nginx/
│   └── owl.hello-vanilla.ru.conf # минимальный 80-блок, certbot достроит 443
└── scripts/
    ├── bootstrap.sh              # подготовка хоста: пакеты, Docker, UFW
    ├── deploy.sh                 # первичный деплой стека + certbot
    ├── backup.sh                 # ежедневный pg_dump + ротация
    └── restore.sh                # восстановление из дампа (интерактивный confirm)
```

`.env` — единственный файл с секретами; явно в `.gitignore`. `.env.example` — шаблон с заглушками.

## 6. Контейнерный слой

### 6.1 `docker-compose.yml`

Верхнеуровневый ключ `name: joplin` фиксирует имя compose-проекта. Compose автоматически префиксует все ресурсы:
- сеть: `joplin_default`
- контейнеры: `joplin-app-1`, `joplin-db-1`

Жёсткий `container_name` **не задаётся** — позволяет compose избежать конфликтов с другими стеками.

#### Сервис `db`

| Параметр | Значение |
|---|---|
| image | `postgres:16-alpine` |
| restart | `unless-stopped` |
| ports | не публикуется наружу |
| volumes | `./data/postgres:/var/lib/postgresql/data` |
| environment | `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` (из `.env`) |
| healthcheck | `pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"`, interval 10s, retries 5 |
| logging | `json-file`, `max-size: 10m`, `max-file: 3` |

#### Сервис `app`

| Параметр | Значение |
|---|---|
| image | `joplin/server:${JOPLIN_VERSION}` |
| restart | `unless-stopped` |
| ports | `127.0.0.1:22300:22300` (только loopback) |
| depends_on | `db` с `condition: service_healthy` |
| logging | `json-file`, `max-size: 10m`, `max-file: 3` |
| environment | см. ниже |

Переменные окружения, передаваемые в `app` через compose:

```
APP_PORT=22300
APP_BASE_URL=https://owl.hello-vanilla.ru
DB_CLIENT=pg
POSTGRES_HOST=db
POSTGRES_PORT=5432
POSTGRES_DATABASE=${POSTGRES_DB}
POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
```

Переменные `MAILER_*` **не задаются** — multi-user без SMTP.

### 6.2 `.env`

```env
# Joplin
JOPLIN_VERSION=3.4.4              # подставить актуальный стабильный тег с hub.docker.com/r/joplin/server/tags
APP_BASE_URL=https://owl.hello-vanilla.ru

# Postgres
POSTGRES_USER=joplin
POSTGRES_PASSWORD=<сгенерируется bootstrap.sh через openssl rand -base64 24>
POSTGRES_DB=joplin
```

`.env.example` — то же, но с явными плейсхолдерами вместо реального пароля. Коммитится в git. `.env` — никогда.

### 6.3 Том данных Postgres

`./data/postgres` (относительно `/opt/joplin/`) — bind-mount, владелец `joplin:joplin`, mode `0700`. Не named volume, чтобы:
- путь был очевиден при отладке и бэкапе;
- удаление стека (`rm -rf /opt/joplin/data`) гарантированно сносило данные.

## 7. Слой реверс-прокси и TLS

### 7.1 Стартовый конфиг (что лежит в репо)

`nginx/owl.hello-vanilla.ru.conf`:

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name owl.hello-vanilla.ru;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        proxy_pass http://127.0.0.1:22300;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;

        client_max_body_size 200m;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
        proxy_request_buffering off;
    }
}
```

Файл копируется в `/etc/nginx/sites-available/`, симлинк в `sites-enabled/`. **Сайт `default` и любые чужие конфиги не трогаются.**

### 7.2 Выпуск сертификата

После того как nginx перезагружен с минимальным конфигом, `deploy.sh` запускает:

```bash
certbot --nginx \
  -d owl.hello-vanilla.ru \
  -m "$CERTBOT_EMAIL" \
  --agree-tos --no-eff-email \
  --redirect \
  --deploy-hook "systemctl reload nginx"
```

Certbot in-place добавляет 443-блок, редирект 80→443, пути к сертификату и рекомендуемые TLS-параметры (`/etc/letsencrypt/options-ssl-nginx.conf`, DH-параметры).

`CERTBOT_EMAIL` — переменная окружения, запрашивается интерактивно при первом запуске `deploy.sh` если не задана.

### 7.3 HSTS

Включается **отдельным шагом** после того как пользователь убедился что HTTPS работает. В `deploy.sh` есть закомментированный шаг с пометкой «раскомментировать после первой проверки». Преждевременное включение HSTS на ошибочной конфигурации может на год заблокировать домен в браузерах.

### 7.4 Автообновление

Пакет `certbot` Ubuntu при установке регистрирует systemd-таймер `certbot.timer` (срабатывает дважды в сутки). `--deploy-hook "systemctl reload nginx"` сохраняется в `/etc/letsencrypt/renewal/owl.hello-vanilla.ru.conf` и применяется при каждом продлении.

## 8. Операционный слой

### 8.1 `scripts/bootstrap.sh` — подготовка хоста

Запускается **один раз от root** на свежем VPS. Идемпотентен — повторный запуск ничего не ломает.

Параметры (переменные в начале скрипта):

```bash
SSH_PORT=22                # пользователь подставляет свой нестандартный порт
JOPLIN_USER=joplin
```

Если `SSH_PORT` остался дефолтным `22` и при этом sshd слушает на другом порту — скрипт **падает с ошибкой** до включения UFW (защита от self-lockout).

Шаги:

1. Проверить ОС: `lsb_release -rs` == `22.04`. Иначе — exit с сообщением.
2. `apt-get update`.
3. Доустановить пакеты, если их нет (`dpkg -s pkg || apt-get install -y pkg`):
   `ca-certificates`, `curl`, `gnupg`, `nginx`, `certbot`, `python3-certbot-nginx`, `ufw`, `cron`, `gzip`, `openssl`.
4. Установить Docker Engine + compose plugin по официальной инструкции (репозиторий `download.docker.com`), **только если** `docker compose version` ещё не работает.
5. Создать пользователя `joplin` (если нет): `useradd -m -s /bin/bash joplin`, добавить в группу `docker`.
6. Создать каталоги:
   - `/opt/joplin/` — owner `joplin:joplin`, mode `0750`
   - `/var/backups/joplin/` — owner `joplin:joplin`, mode `0750`
   - `/var/www/certbot/` — owner `www-data:www-data`, для ACME http-01 challenge
7. Настроить UFW:
   - Если `ufw status` = `inactive`:
     - `ufw default deny incoming`
     - `ufw default allow outgoing`
     - `ufw allow ${SSH_PORT}/tcp comment 'SSH'`
     - `ufw allow 80/tcp comment 'HTTP'`
     - `ufw allow 443/tcp comment 'HTTPS'`
     - `ufw --force enable`
   - Если `ufw status` = `active`:
     - **Только** `ufw allow ${SSH_PORT}/tcp`, `ufw allow 80/tcp`, `ufw allow 443/tcp` (не дублируется, ufw сам обнаружит существующие).
     - Дефолтные политики **не меняются** (могут быть нужны другим приложениям).
8. Финальный summary: версии docker/nginx/certbot, статус UFW, проверки `nginx -t`, `systemctl is-active nginx`, `docker info`.

### 8.2 `scripts/deploy.sh` — первичный деплой

Запускается от пользователя `joplin` из `/opt/joplin/`. Идемпотентен.

Шаги:

1. Проверить что `bootstrap.sh` отработал: `command -v docker compose`, `nginx -v`, `ufw status | grep -q active`. Иначе exit с подсказкой.
2. Если `.env` нет — скопировать из `.env.example`, сгенерировать `POSTGRES_PASSWORD=$(openssl rand -base64 24)` и записать в `.env`. Если `.env` есть — не трогать.
3. Запросить `CERTBOT_EMAIL` если не задан в окружении (интерактивный prompt).
4. `docker compose pull`.
5. `docker compose up -d`. Postgres стартует, healthcheck → app.
6. Подождать локальный ping: `curl -fsS --retry 30 --retry-delay 2 http://127.0.0.1:22300/api/ping`.
7. Скопировать `nginx/owl.hello-vanilla.ru.conf` в `/etc/nginx/sites-available/`, создать симлинк в `sites-enabled/` (если ещё нет). `nginx -t && systemctl reload nginx`.
8. Если сертификата ещё нет (`certbot certificates | grep -q owl.hello-vanilla.ru` → false) — запустить certbot (см. 7.2). Иначе пропустить.
9. Финальные проверки:
   - `curl -fsS https://owl.hello-vanilla.ru/api/ping` → 200
   - `curl -sIo /dev/null -w '%{http_code}' http://owl.hello-vanilla.ru/` → 301
   - `certbot certificates` показывает `owl.hello-vanilla.ru` с expiry > 60 дней
10. Печатает URL для входа в админку и дефолтные креды Joplin (`admin@localhost` / `admin`) с напоминанием **немедленно сменить пароль**.

### 8.3 `scripts/backup.sh` — ежедневный pg_dump

Запускается из cron пользователя `joplin` каждый день в 03:17:

```cron
17 3 * * * /opt/joplin/scripts/backup.sh >> /var/log/joplin-backup.log 2>&1
```

Шаги:

1. `cd /opt/joplin`
2. `TS=$(date +%Y-%m-%d_%H%M)`
3. Источник секретов: `set -a; source .env; set +a` — чтобы получить `POSTGRES_USER`, `POSTGRES_DB`.
4. Дамп:
   ```bash
   docker compose exec -T db \
     pg_dump -U "$POSTGRES_USER" -Fc "$POSTGRES_DB" \
     | gzip > "/var/backups/joplin/joplin-${TS}.dump.gz"
   ```
5. Проверка целостности: `gunzip -t "/var/backups/joplin/joplin-${TS}.dump.gz"`. При ошибке — exit 1.
6. Если `date +%u` = `7` (воскресенье) — сделать копию с префиксом `weekly-`.
7. Ротация:
   - Ежедневные: `find /var/backups/joplin/joplin-????-??-??_*.dump.gz -mtime +7 -delete`
   - Еженедельные: оставить последние 4 файла `weekly-*`, остальные удалить.

`/var/log/joplin-backup.log` ротируется через `logrotate` — конфиг кладётся в `/etc/logrotate.d/joplin-backup`.

### 8.4 `scripts/restore.sh` — восстановление

Принимает аргументом путь к `.dump.gz`. Интерактивно требует подтверждения (`y/N`) — деструктивно.

Шаги:

1. Проверить файл существует и проходит `gunzip -t`.
2. `docker compose stop app`.
3. Сбросить схему: `docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"`.
4. Накатить дамп: `gunzip -c "$DUMP" | docker compose exec -T db pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --no-acl`.
5. `docker compose start app`.
6. Проверка ping.

### 8.5 Обновление версии Joplin

Документируется в `README.md`:

```
1. ./scripts/backup.sh                       # бэкап перед апгрейдом
2. отредактировать JOPLIN_VERSION в .env     # сверившись с github.com/laurent22/joplin/releases
3. docker compose pull && docker compose up -d
4. curl -fsS https://owl.hello-vanilla.ru/api/ping
```

Никаких автоматических обновлений.

## 9. Footprint на VPS

Документируется в `README.md`. Полный список того, что стек создаёт на VPS:

| Путь / ресурс | Создаётся | Назначение |
|---|---|---|
| `/opt/joplin/` | bootstrap + deploy | код, `.env`, данные Postgres |
| `/var/backups/joplin/` | bootstrap | дампы |
| `/var/log/joplin-backup.log` | первый запуск backup.sh | лог бэкапов |
| `/etc/nginx/sites-available/owl.hello-vanilla.ru.conf` + симлинк | deploy | конфиг nginx |
| `/etc/letsencrypt/live/owl.hello-vanilla.ru/` | certbot | сертификат (общая инфра certbot) |
| `/etc/letsencrypt/renewal/owl.hello-vanilla.ru.conf` | certbot | конфиг автообновления |
| crontab пользователя `joplin` | deploy | задача backup.sh |
| `/etc/logrotate.d/joplin-backup` | deploy | ротация логов бэкапа |
| Системный пользователь `joplin` (uid auto), группа `docker` | bootstrap | владелец стека |
| UFW-правила: SSH-порт, 80/tcp, 443/tcp | bootstrap | firewall |
| TCP 127.0.0.1:22300 | docker compose | публикуемый порт Joplin (только loopback) |

## 10. Удаление стека

Документируется в `README.md` отдельным разделом:

```bash
# 1. Снять стек
cd /opt/joplin && docker compose down -v

# 2. Удалить данные и код
sudo rm -rf /opt/joplin /var/backups/joplin /var/log/joplin-backup.log

# 3. Снять nginx-конфиг
sudo rm /etc/nginx/sites-enabled/owl.hello-vanilla.ru.conf
sudo rm /etc/nginx/sites-available/owl.hello-vanilla.ru.conf
sudo systemctl reload nginx

# 4. Удалить сертификат
sudo certbot delete --cert-name owl.hello-vanilla.ru

# 5. Удалить cron-задачу
sudo crontab -u joplin -e   # удалить строку с backup.sh

# 6. Удалить logrotate-конфиг
sudo rm /etc/logrotate.d/joplin-backup

# 7. (опционально) Удалить пользователя
sudo userdel -r joplin
```

Пакеты (docker, nginx, certbot, ufw) и UFW-правила **не удаляются** — могут быть нужны другим приложениям. UFW-правила 80/tcp и 443/tcp остаются по той же причине.

## 11. Вне scope

Явно не делается:

- Настройка SMTP / `MAILER_*` (multi-user без email подтверждено).
- Удалённая выгрузка бэкапов (S3/B2/rclone) — выбран вариант B, не C.
- Мониторинг (Prometheus, Grafana, healthcheck-сервисы).
- Поддержка нескольких реверс-прокси параллельно (только nginx-host).
- Высокая доступность (один VPS, один контейнер app).
- Поддержка ОС кроме Ubuntu 22.04.

## 12. Чек-лист приёмки (что проверяется после первого деплоя)

1. `https://owl.hello-vanilla.ru` открывается в браузере, загружается web UI Joplin.
2. `curl -fsS https://owl.hello-vanilla.ru/api/ping` возвращает 200.
3. `curl -sI http://owl.hello-vanilla.ru/ | head -1` показывает `301 Moved Permanently`, `Location: https://owl.hello-vanilla.ru/`.
4. SSL Labs (или `testssl.sh`) для домена показывает A или выше.
5. `certbot certificates` показывает `owl.hello-vanilla.ru` с expiry > 60 дней.
6. `systemctl list-timers | grep certbot` — таймер активен.
7. `ufw status verbose` — активен, в правилах SSH, 80, 443.
8. Joplin admin UI: вход под `admin@localhost` / `admin`, пароль немедленно сменён, создан рабочий пользователь.
9. Joplin desktop клиент успешно подключается (`Synchronisation target` = `Joplin Server`, URL = `https://owl.hello-vanilla.ru`) и синхронизирует тестовую заметку.
10. `./scripts/backup.sh` отрабатывает руками без ошибок, в `/var/backups/joplin/` появляется свежий `.dump.gz`, `gunzip -t` проходит.
11. `docker compose down && docker compose up -d` — стек переподнимается без потери данных.
