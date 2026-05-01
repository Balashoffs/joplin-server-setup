# План реализации: развёртывание Joplin Server на VPS

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Спека:** `docs/superpowers/specs/2026-05-01-joplin-vps-deploy-design.md` (commit `93870ff`)

**Goal:** Создать в репозитории `/Users/bau/Documents/joplin` все артефакты (compose-файл, env-шаблон, nginx-конфиг, скрипты bootstrap/deploy/backup/restore, logrotate-конфиг, README), необходимые для развёртывания Joplin Server за nginx-host реверс-прокси с TLS на домене `owl.hello-vanilla.ru` (Ubuntu 22.04 VPS).

**Architecture:** Двухконтейнерный стек (Joplin Server + PostgreSQL 16) под управлением Docker Compose. Nginx и certbot — нативно на хосте VPS. Joplin публикует порт только на loopback (`127.0.0.1:22300`), Postgres внутри docker-сети без публикации. Идемпотентные shell-скрипты для подготовки хоста, деплоя, бэкапа и восстановления.

**Tech Stack:** Docker Compose v2, PostgreSQL 16-alpine, joplin/server (Docker Hub), nginx 1.18+ (Ubuntu 22.04 default), certbot + python3-certbot-nginx, UFW, systemd, bash, cron, logrotate.

---

## Структура файлов

```
joplin/
├── .gitignore                        # Task 1
├── docker-compose.yml                # Task 2
├── .env.example                      # Task 2
├── nginx/
│   └── owl.hello-vanilla.ru.conf     # Task 3
├── scripts/
│   ├── bootstrap.sh                  # Task 4
│   ├── deploy.sh                     # Task 5
│   ├── backup.sh                     # Task 6
│   └── restore.sh                    # Task 7
├── logrotate/
│   └── joplin-backup                 # Task 8
└── README.md                         # Task 9
```

**Принцип декомпозиции:** один файл — одна ответственность. `bootstrap.sh` готовит хост (пакеты, Docker, UFW), `deploy.sh` поднимает стек и оформляет TLS, `backup.sh`/`restore.sh` работают с pg_dump. Никакой общей логики между скриптами не вытаскиваем (лишний слой ради 3-4 строк дублирования — оверкилл, спека требует «один-VPS, один-домен»).

**Локальная валидация.** Файлы создаются на macOS, реальные интеграционные проверки (`nginx -t`, `docker compose up`, `certbot --nginx`) возможны только на VPS. На локальной машине проверяем только синтаксис: `bash -n` для скриптов, `python3 -c "import yaml; yaml.safe_load(open(...))"` для compose. Где доступен `shellcheck` / `docker compose` — используем их (плановые команды показывают и предпочтительный, и fallback вариант).

---

## Task 1: `.gitignore`

**Files:**
- Create: `.gitignore`

- [ ] **Step 1: Создать `.gitignore`**

```
# Секреты
.env

# Данные стека (создаются на VPS, в репо не нужны)
data/

# Бэкапы
*.dump.gz

# Логи
*.log

# macOS
.DS_Store
```

- [ ] **Step 2: Проверить что файл создан**

```bash
cat .gitignore
```

Ожидание: содержимое из шага 1.

- [ ] **Step 3: Закоммитить**

```bash
git add .gitignore
git commit -m "Добавить .gitignore: исключить .env, data/, бэкапы и логи"
```

---

## Task 2: `docker-compose.yml` и `.env.example`

**Files:**
- Create: `docker-compose.yml`
- Create: `.env.example`

- [ ] **Step 1: Создать `docker-compose.yml`**

```yaml
name: joplin

services:
  db:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $$POSTGRES_USER -d $$POSTGRES_DB"]
      interval: 10s
      timeout: 5s
      retries: 5
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  app:
    image: joplin/server:${JOPLIN_VERSION}
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    ports:
      - "127.0.0.1:22300:22300"
    environment:
      APP_PORT: 22300
      APP_BASE_URL: ${APP_BASE_URL}
      DB_CLIENT: pg
      POSTGRES_HOST: db
      POSTGRES_PORT: 5432
      POSTGRES_DATABASE: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
```

- [ ] **Step 2: Создать `.env.example`**

```env
# Joplin Server
# Перед первым деплоем сверьтесь с актуальным стабильным тегом:
# https://hub.docker.com/r/joplin/server/tags
JOPLIN_VERSION=3.4.4
APP_BASE_URL=https://owl.hello-vanilla.ru

# PostgreSQL
POSTGRES_USER=joplin
# POSTGRES_PASSWORD генерируется deploy.sh при первом запуске
# (openssl rand -base64 24). Заглушка ниже не используется напрямую.
POSTGRES_PASSWORD=__GENERATED_BY_DEPLOY_SH__
POSTGRES_DB=joplin
```

- [ ] **Step 3: Проверить YAML-синтаксис**

Предпочтительно (если на машине есть `docker`):
```bash
JOPLIN_VERSION=3.4.4 APP_BASE_URL=https://owl.hello-vanilla.ru \
POSTGRES_USER=joplin POSTGRES_PASSWORD=test POSTGRES_DB=joplin \
docker compose config --quiet && echo "OK: compose валиден"
```

Fallback (только парсинг YAML без semantic-проверки):
```bash
python3 -c "import yaml; yaml.safe_load(open('docker-compose.yml'))" && echo "OK: YAML валиден"
```

Ожидание: `OK: ...` без ошибок.

- [ ] **Step 4: Закоммитить**

```bash
git add docker-compose.yml .env.example
git commit -m "Добавить docker-compose.yml и .env.example для стека joplin+postgres"
```

---

## Task 3: `nginx/owl.hello-vanilla.ru.conf`

**Files:**
- Create: `nginx/owl.hello-vanilla.ru.conf`

- [ ] **Step 1: Создать каталог и файл**

```bash
mkdir -p nginx
```

Содержимое `nginx/owl.hello-vanilla.ru.conf`:

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

- [ ] **Step 2: Базовая проверка содержимого**

```bash
grep -q 'server_name owl.hello-vanilla.ru' nginx/owl.hello-vanilla.ru.conf
grep -q 'proxy_pass http://127.0.0.1:22300' nginx/owl.hello-vanilla.ru.conf
grep -q 'client_max_body_size 200m' nginx/owl.hello-vanilla.ru.conf
echo "OK: основные директивы на месте"
```

Ожидание: `OK: основные директивы на месте`. (Полный `nginx -t` запустится только на VPS — здесь только проверка наличия ключевых строк.)

- [ ] **Step 3: Закоммитить**

```bash
git add nginx/owl.hello-vanilla.ru.conf
git commit -m "Добавить стартовый nginx-конфиг для owl.hello-vanilla.ru (только 80)"
```

---

## Task 4: `scripts/bootstrap.sh`

**Files:**
- Create: `scripts/bootstrap.sh`

- [ ] **Step 1: Создать каталог и файл**

```bash
mkdir -p scripts
```

Содержимое `scripts/bootstrap.sh`:

```bash
#!/usr/bin/env bash
# scripts/bootstrap.sh — однократная подготовка VPS Ubuntu 22.04.
# Запускать от root: sudo ./scripts/bootstrap.sh
# Идемпотентен: повторный запуск ничего не ломает.
set -euo pipefail

# === Параметры ===
SSH_PORT=22                 # ВАЖНО: подставьте ваш фактический SSH-порт
JOPLIN_USER=joplin

# === Пред-проверки ===
if [[ $EUID -ne 0 ]]; then
    echo "Запускайте от root: sudo $0" >&2
    exit 1
fi

OS_VERSION=$(lsb_release -rs 2>/dev/null || echo "unknown")
if [[ "$OS_VERSION" != "22.04" ]]; then
    echo "Требуется Ubuntu 22.04, найдено: $OS_VERSION" >&2
    exit 1
fi

# Защита от self-lockout
ACTUAL_SSH_PORT=$(ss -tlnp 2>/dev/null \
    | awk '/sshd/ {split($4,a,":"); print a[length(a)]; exit}')
if [[ -n "${ACTUAL_SSH_PORT:-}" && "$ACTUAL_SSH_PORT" != "$SSH_PORT" ]]; then
    cat >&2 <<EOF
ОШИБКА: SSH_PORT в скрипте ($SSH_PORT) не совпадает с фактическим
портом sshd ($ACTUAL_SSH_PORT). Откройте $0 и поправьте SSH_PORT.
UFW не настраивается до устранения расхождения.
EOF
    exit 1
fi

# === apt + базовые пакеты ===
echo "==> apt update"
apt-get update -qq

echo "==> Проверка пакетов"
PACKAGES=(
    ca-certificates curl gnupg lsb-release
    nginx certbot python3-certbot-nginx
    ufw cron gzip openssl
)
for pkg in "${PACKAGES[@]}"; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
        echo "  $pkg — уже установлен"
    else
        echo "  ставлю $pkg"
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg"
    fi
done

# === Docker Engine + compose plugin ===
if docker compose version >/dev/null 2>&1; then
    echo "==> Docker уже установлен"
else
    echo "==> Установка Docker Engine + compose plugin"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
fi

# === Пользователь joplin ===
if ! id "$JOPLIN_USER" >/dev/null 2>&1; then
    echo "==> Создание пользователя $JOPLIN_USER"
    useradd -m -s /bin/bash "$JOPLIN_USER"
fi
if ! id -nG "$JOPLIN_USER" | tr ' ' '\n' | grep -qx docker; then
    usermod -aG docker "$JOPLIN_USER"
    echo "  $JOPLIN_USER добавлен в группу docker"
fi

# === Каталоги ===
install -d -o "$JOPLIN_USER" -g "$JOPLIN_USER" -m 0750 /opt/joplin
install -d -o "$JOPLIN_USER" -g "$JOPLIN_USER" -m 0750 /var/backups/joplin
install -d -o www-data -g www-data -m 0755 /var/www/certbot

# === UFW ===
echo "==> Настройка UFW"
UFW_STATUS=$(ufw status | head -1 | awk '{print $2}')
if [[ "$UFW_STATUS" == "inactive" ]]; then
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "${SSH_PORT}/tcp" comment 'SSH'
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'
    ufw --force enable
else
    # UFW уже активен (другими сервисами) — только добавляем нужные правила,
    # дефолтные политики не трогаем.
    ufw allow "${SSH_PORT}/tcp" comment 'SSH' || true
    ufw allow 80/tcp comment 'HTTP' || true
    ufw allow 443/tcp comment 'HTTPS' || true
fi

# === Summary ===
echo
echo "==> Готово"
echo "  Docker:  $(docker --version)"
echo "  Compose: $(docker compose version)"
echo "  Nginx:   $(nginx -v 2>&1)"
echo "  Certbot: $(certbot --version 2>&1)"
echo "  UFW:     $(ufw status | head -1)"
nginx -t
systemctl is-active nginx
docker info >/dev/null && echo "  Docker daemon: активен"
echo
echo "Дальше: переключитесь на пользователя joplin, скопируйте проект"
echo "в /opt/joplin/ и запустите ./scripts/deploy.sh"
```

- [ ] **Step 2: Сделать исполняемым**

```bash
chmod +x scripts/bootstrap.sh
```

- [ ] **Step 3: Проверить синтаксис bash**

Предпочтительно (если установлен `shellcheck`):
```bash
shellcheck scripts/bootstrap.sh && echo "OK: shellcheck прошёл"
```

Fallback:
```bash
bash -n scripts/bootstrap.sh && echo "OK: синтаксис валиден"
```

Ожидание: `OK: ...`. Если shellcheck выдаст предупреждения SC2086/SC2155 — это допустимо для этого скрипта; ошибок (SC2*) быть не должно.

- [ ] **Step 4: Закоммитить**

```bash
git add scripts/bootstrap.sh
git commit -m "Добавить scripts/bootstrap.sh: подготовка VPS (пакеты, Docker, UFW)"
```

---

## Task 5: `scripts/deploy.sh`

**Files:**
- Create: `scripts/deploy.sh`

- [ ] **Step 1: Создать `scripts/deploy.sh`**

```bash
#!/usr/bin/env bash
# scripts/deploy.sh — первичный деплой Joplin на подготовленный VPS.
# Запускать из /opt/joplin от пользователя joplin.
# Идемпотентен.
set -euo pipefail

cd "$(dirname "$0")/.."
PROJECT_DIR="$(pwd)"

# === Пред-проверки ===
if [[ "$PROJECT_DIR" != "/opt/joplin" ]]; then
    echo "Ожидался /opt/joplin, текущий каталог: $PROJECT_DIR" >&2
    exit 1
fi

for cmd in docker nginx ufw curl openssl sudo; do
    command -v "$cmd" >/dev/null \
        || { echo "Не найдено: $cmd. Сначала bootstrap.sh" >&2; exit 1; }
done

if ! docker compose version >/dev/null 2>&1; then
    echo "Не найдено: docker compose plugin. Сначала bootstrap.sh" >&2
    exit 1
fi

if ! ufw status | grep -qw active; then
    echo "UFW не активен. Сначала bootstrap.sh" >&2
    exit 1
fi

# === .env: первичная инициализация и генерация POSTGRES_PASSWORD ===
if [[ ! -f .env ]]; then
    [[ -f .env.example ]] || { echo "Нет .env.example в $PROJECT_DIR" >&2; exit 1; }
    echo "==> Создание .env из .env.example"
    cp .env.example .env
    chmod 600 .env
    PASS=$(openssl rand -base64 24 | tr -d '\n')
    # Безопасная замена через временный файл (избегаем sed-нюансов с / в base64).
    awk -v p="$PASS" '
        /^POSTGRES_PASSWORD=/ { print "POSTGRES_PASSWORD=" p; next }
        { print }
    ' .env > .env.new && mv .env.new .env
    chmod 600 .env
    echo "  POSTGRES_PASSWORD сгенерирован и записан в .env"
fi

# === CERTBOT_EMAIL ===
if [[ -z "${CERTBOT_EMAIL:-}" ]]; then
    read -rp "Email для Let's Encrypt (уведомления об истечении): " CERTBOT_EMAIL
fi
if [[ -z "$CERTBOT_EMAIL" ]]; then
    echo "CERTBOT_EMAIL обязателен" >&2
    exit 1
fi

# === Старт стека ===
echo "==> docker compose pull"
docker compose pull
echo "==> docker compose up -d"
docker compose up -d

echo "==> Ожидание Joplin на 127.0.0.1:22300"
curl -fsS --retry 30 --retry-delay 2 -o /dev/null \
    http://127.0.0.1:22300/api/ping
echo "  Joplin отвечает локально"

# === Nginx ===
NGINX_AVAILABLE=/etc/nginx/sites-available/owl.hello-vanilla.ru.conf
NGINX_ENABLED=/etc/nginx/sites-enabled/owl.hello-vanilla.ru.conf

echo "==> Установка nginx-конфига"
sudo cp nginx/owl.hello-vanilla.ru.conf "$NGINX_AVAILABLE"
[[ -L "$NGINX_ENABLED" ]] || sudo ln -s "$NGINX_AVAILABLE" "$NGINX_ENABLED"
sudo nginx -t
sudo systemctl reload nginx

# === Certbot ===
if sudo certbot certificates 2>/dev/null \
    | grep -q "Certificate Name: owl.hello-vanilla.ru"; then
    echo "==> Сертификат уже выпущен, пропускаю certbot"
else
    echo "==> Выпуск сертификата Let's Encrypt"
    sudo certbot --nginx \
        -d owl.hello-vanilla.ru \
        -m "$CERTBOT_EMAIL" \
        --agree-tos --no-eff-email \
        --redirect \
        --deploy-hook "systemctl reload nginx"
fi

# === Cron бэкапа ===
CRON_LINE="17 3 * * * /opt/joplin/scripts/backup.sh >> /var/log/joplin-backup.log 2>&1"
if ! sudo crontab -u joplin -l 2>/dev/null \
    | grep -qF "/opt/joplin/scripts/backup.sh"; then
    echo "==> Установка cron-задачи бэкапа"
    (sudo crontab -u joplin -l 2>/dev/null || true; echo "$CRON_LINE") \
        | sudo crontab -u joplin -
fi

# === Logrotate ===
if [[ ! -f /etc/logrotate.d/joplin-backup ]]; then
    echo "==> Установка logrotate-конфига"
    sudo cp logrotate/joplin-backup /etc/logrotate.d/joplin-backup
    sudo chmod 644 /etc/logrotate.d/joplin-backup
fi
sudo touch /var/log/joplin-backup.log
sudo chown joplin:joplin /var/log/joplin-backup.log

# === Финальные проверки ===
echo
echo "==> Финальные проверки"
curl -fsS https://owl.hello-vanilla.ru/api/ping >/dev/null \
    && echo "  HTTPS ping OK"
HTTP_CODE=$(curl -sIo /dev/null -w '%{http_code}' http://owl.hello-vanilla.ru/)
if [[ "$HTTP_CODE" == "301" || "$HTTP_CODE" == "308" ]]; then
    echo "  HTTP→HTTPS редирект OK ($HTTP_CODE)"
else
    echo "  ВНИМАНИЕ: HTTP вернул $HTTP_CODE (ожидалось 301/308)"
fi
sudo certbot certificates 2>/dev/null \
    | grep -A2 "owl.hello-vanilla.ru" || true

cat <<'EOF'

==> Деплой завершён.
URL: https://owl.hello-vanilla.ru
Дефолтные креды: admin@localhost / admin
ВАЖНО: войдите и НЕМЕДЛЕННО смените пароль и email админа.

HSTS не включён автоматически — после проверки HTTPS см. README.
EOF
```

- [ ] **Step 2: Сделать исполняемым**

```bash
chmod +x scripts/deploy.sh
```

- [ ] **Step 3: Проверить синтаксис**

```bash
shellcheck scripts/deploy.sh && echo "OK: shellcheck прошёл" \
    || bash -n scripts/deploy.sh && echo "OK: bash -n прошёл"
```

Ожидание: `OK: ...`. Известные допустимые предупреждения shellcheck: SC2086 (word splitting в `$(...)`), SC2155.

- [ ] **Step 4: Закоммитить**

```bash
git add scripts/deploy.sh
git commit -m "Добавить scripts/deploy.sh: первичный деплой стека и выпуск SSL"
```

---

## Task 6: `scripts/backup.sh`

**Files:**
- Create: `scripts/backup.sh`

- [ ] **Step 1: Создать `scripts/backup.sh`**

```bash
#!/usr/bin/env bash
# scripts/backup.sh — ежедневный pg_dump Joplin с ротацией.
# Запускается из cron пользователя joplin.
set -euo pipefail

cd /opt/joplin

# Загрузить переменные из .env
set -a
# shellcheck disable=SC1091
source .env
set +a

TS=$(date +%Y-%m-%d_%H%M)
BACKUP_DIR=/var/backups/joplin
DUMP="${BACKUP_DIR}/joplin-${TS}.dump.gz"

# === Дамп ===
docker compose exec -T db \
    pg_dump -U "$POSTGRES_USER" -Fc "$POSTGRES_DB" \
    | gzip > "$DUMP"

# === Целостность ===
gunzip -t "$DUMP"
SIZE=$(du -h "$DUMP" | cut -f1)
echo "[$(date +'%F %T')] backup OK: $DUMP ($SIZE)"

# === Weekly копия (воскресенье) ===
if [[ "$(date +%u)" == "7" ]]; then
    WEEKLY="${BACKUP_DIR}/weekly-$(date +%Y-%m-%d).dump.gz"
    cp "$DUMP" "$WEEKLY"
    echo "[$(date +'%F %T')] weekly: $WEEKLY"
fi

# === Ротация ежедневных: старше 7 дней удаляем ===
find "$BACKUP_DIR" -maxdepth 1 \
    -name 'joplin-????-??-??_*.dump.gz' \
    -mtime +7 -delete

# === Ротация еженедельных: оставить последние 4 ===
find "$BACKUP_DIR" -maxdepth 1 \
    -name 'weekly-*.dump.gz' \
    -printf '%T@ %p\n' \
    | sort -rn \
    | tail -n +5 \
    | cut -d' ' -f2- \
    | xargs -r rm -f
```

- [ ] **Step 2: Сделать исполняемым**

```bash
chmod +x scripts/backup.sh
```

- [ ] **Step 3: Проверить синтаксис**

```bash
shellcheck scripts/backup.sh && echo "OK: shellcheck прошёл" \
    || bash -n scripts/backup.sh && echo "OK: bash -n прошёл"
```

Ожидание: `OK: ...`.

- [ ] **Step 4: Закоммитить**

```bash
git add scripts/backup.sh
git commit -m "Добавить scripts/backup.sh: pg_dump + ротация (7 ежедневных + 4 weekly)"
```

---

## Task 7: `scripts/restore.sh`

**Files:**
- Create: `scripts/restore.sh`

- [ ] **Step 1: Создать `scripts/restore.sh`**

```bash
#!/usr/bin/env bash
# scripts/restore.sh — восстановление Joplin из дампа .dump.gz.
# Использование: ./scripts/restore.sh /var/backups/joplin/joplin-YYYY-MM-DD_HHMM.dump.gz
# ДЕСТРУКТИВНО: уничтожает текущие данные Joplin.
set -euo pipefail

DUMP="${1:-}"
if [[ -z "$DUMP" ]]; then
    cat >&2 <<'EOF'
Использование: ./scripts/restore.sh <path-to-dump.gz>
Пример: ./scripts/restore.sh /var/backups/joplin/joplin-2026-05-01_0317.dump.gz
EOF
    exit 1
fi

if [[ ! -f "$DUMP" ]]; then
    echo "Файл не найден: $DUMP" >&2
    exit 1
fi

echo "==> Проверка целостности дампа"
gunzip -t "$DUMP"

cd /opt/joplin
set -a
# shellcheck disable=SC1091
source .env
set +a

cat <<EOF

ВНИМАНИЕ: восстановление УНИЧТОЖИТ текущие данные Joplin.
  Дамп: $DUMP
  БД:   $POSTGRES_DB (на хосте db в docker compose)

EOF
read -rp "Продолжить? [y/N] " ANSWER
if [[ "$ANSWER" != "y" && "$ANSWER" != "Y" ]]; then
    echo "Отмена."
    exit 1
fi

echo "==> Остановка app"
docker compose stop app

echo "==> Сброс схемы public"
docker compose exec -T db \
    psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;'

echo "==> Накат дампа"
gunzip -c "$DUMP" \
    | docker compose exec -T db \
        pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
        --no-owner --no-acl

echo "==> Старт app"
docker compose start app

echo "==> Проверка ping"
curl -fsS --retry 30 --retry-delay 2 -o /dev/null \
    http://127.0.0.1:22300/api/ping

echo "==> Восстановление завершено."
```

- [ ] **Step 2: Сделать исполняемым**

```bash
chmod +x scripts/restore.sh
```

- [ ] **Step 3: Проверить синтаксис**

```bash
shellcheck scripts/restore.sh && echo "OK: shellcheck прошёл" \
    || bash -n scripts/restore.sh && echo "OK: bash -n прошёл"
```

Ожидание: `OK: ...`.

- [ ] **Step 4: Закоммитить**

```bash
git add scripts/restore.sh
git commit -m "Добавить scripts/restore.sh: восстановление БД из дампа с подтверждением"
```

---

## Task 8: `logrotate/joplin-backup`

**Files:**
- Create: `logrotate/joplin-backup`

- [ ] **Step 1: Создать каталог и файл**

```bash
mkdir -p logrotate
```

Содержимое `logrotate/joplin-backup`:

```
/var/log/joplin-backup.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 0640 joplin joplin
}
```

- [ ] **Step 2: Базовая проверка**

```bash
grep -q '/var/log/joplin-backup.log' logrotate/joplin-backup
grep -q 'create 0640 joplin joplin' logrotate/joplin-backup
echo "OK: logrotate-конфиг сформирован"
```

(Полная проверка `logrotate -d /etc/logrotate.d/joplin-backup` запускается на VPS — здесь только sanity-check.)

- [ ] **Step 3: Закоммитить**

```bash
git add logrotate/joplin-backup
git commit -m "Добавить logrotate-конфиг для лога бэкапов"
```

---

## Task 9: `README.md`

**Files:**
- Create: `README.md`

- [ ] **Step 1: Создать `README.md`**

````markdown
# Joplin Server на VPS — owl.hello-vanilla.ru

Self-hosted развёртывание [Joplin Server](https://github.com/laurent22/joplin/tree/dev/packages/server)
на VPS Ubuntu 22.04 с TLS через Let's Encrypt. Спроектировано как «хороший
сосед» для других веб-приложений на том же VPS — см. раздел
[Footprint на VPS](#footprint-на-vps).

**Дизайн-документ:** [`docs/superpowers/specs/2026-05-01-joplin-vps-deploy-design.md`](docs/superpowers/specs/2026-05-01-joplin-vps-deploy-design.md)

## Архитектура

```
[client https]──443──▶[nginx host]──127.0.0.1:22300──▶[joplin-app]──joplin_default──▶[joplin-db]
                          ▲
                          │ certbot.timer (systemd) — auto-renew Let's Encrypt
```

- nginx и certbot — нативно на хосте VPS;
- Joplin Server и PostgreSQL 16 — в Docker Compose (`name: joplin`);
- Joplin публикует порт только на `127.0.0.1:22300` (наружу не торчит);
- Postgres не публикует портов вовсе (только во внутренней docker-сети).

## Структура репозитория

```
.
├── docker-compose.yml            # стек (joplin-server + postgres)
├── .env.example                  # шаблон env-файла
├── .env                          # НЕ КОММИТИТСЯ — секреты, генерируется deploy.sh
├── nginx/
│   └── owl.hello-vanilla.ru.conf # стартовый 80-блок (certbot достроит 443)
├── scripts/
│   ├── bootstrap.sh              # подготовка VPS (root) — пакеты, Docker, UFW
│   ├── deploy.sh                 # первичный деплой (joplin) — стек + SSL
│   ├── backup.sh                 # ежедневный pg_dump
│   └── restore.sh                # восстановление из дампа
├── logrotate/
│   └── joplin-backup             # ротация /var/log/joplin-backup.log
└── docs/
    └── superpowers/specs/
        └── 2026-05-01-joplin-vps-deploy-design.md
```

## Развёртывание

### 1. Предусловия

- VPS на Ubuntu 22.04 (других версий не поддерживается).
- DNS A-запись `owl.hello-vanilla.ru → <IP VPS>` уже создана и распространилась.
- SSH-доступ root (или sudo).
- Клонированный репозиторий на локальной машине.

### 2. Залить проект на VPS

```bash
# с локальной машины
rsync -av --exclude='.git' --exclude='data/' \
  /Users/bau/Documents/joplin/ \
  user@VPS_IP:/tmp/joplin-bootstrap/
```

### 3. Первичная подготовка хоста (root)

На VPS:

```bash
sudo mv /tmp/joplin-bootstrap /opt/joplin
cd /opt/joplin

# ВАЖНО: откройте scripts/bootstrap.sh и поправьте SSH_PORT,
# если у вас не дефолтный 22.
sudo nano scripts/bootstrap.sh

sudo ./scripts/bootstrap.sh
```

Скрипт:
- проверит, что ОС = Ubuntu 22.04;
- определит фактический порт sshd через `ss -tlnp` и сравнит с `SSH_PORT`
  (защита от self-lockout);
- доустановит недостающие пакеты, Docker Engine + compose plugin;
- создаст пользователя `joplin` и каталоги `/opt/joplin`, `/var/backups/joplin`,
  `/var/www/certbot`;
- настроит UFW (если не активен — включит с deny incoming; если активен —
  только добавит правила SSH/80/443 без смены дефолтов).

После завершения смените владельца проекта:

```bash
sudo chown -R joplin:joplin /opt/joplin
```

### 4. Первичный деплой стека (от пользователя joplin)

```bash
sudo -u joplin bash -lc 'cd /opt/joplin && ./scripts/deploy.sh'
```

При первом запуске скрипт спросит email для Let's Encrypt. После завершения:

- стек поднят (`docker compose ps`);
- nginx-конфиг установлен в `/etc/nginx/sites-available/`, симлинк в `sites-enabled/`;
- сертификат выпущен (`certbot certificates`);
- cron-задача бэкапа в `crontab -u joplin -l`;
- logrotate-конфиг в `/etc/logrotate.d/joplin-backup`.

### 5. Настройка Joplin

Откройте `https://owl.hello-vanilla.ru` — войдите как:

```
admin@localhost / admin
```

**Немедленно** смените email и пароль администратора (профиль → Change password / Email).
Затем создайте обычных пользователей для синхронизации.

### 6. (опционально) Включить HSTS

Только после того как убедились, что HTTPS работает корректно:

```bash
sudo sed -i '/listen 443 ssl/a \    add_header Strict-Transport-Security "max-age=31536000" always;' \
  /etc/nginx/sites-available/owl.hello-vanilla.ru.conf
sudo nginx -t && sudo systemctl reload nginx
```

HSTS на год — необратимо в браузерах клиентов; включайте только когда
уверены в SSL-конфигурации.

## Эксплуатация

### Бэкапы

Автоматически: cron `joplin` запускает `backup.sh` каждый день в 03:17.
Хранение: 7 ежедневных + 4 еженедельных (воскресные копии с префиксом
`weekly-`). Лог: `/var/log/joplin-backup.log` (ротация через logrotate).

Ручной бэкап:
```bash
sudo -u joplin /opt/joplin/scripts/backup.sh
ls -lh /var/backups/joplin/
```

### Восстановление

```bash
sudo -u joplin /opt/joplin/scripts/restore.sh \
  /var/backups/joplin/joplin-2026-05-01_0317.dump.gz
```

Скрипт интерактивно требует подтверждения. **Уничтожает текущие данные.**

### Обновление версии Joplin Server

```bash
# 1. Бэкап перед апгрейдом
sudo -u joplin /opt/joplin/scripts/backup.sh

# 2. Сверьтесь с changelog
# https://github.com/laurent22/joplin/releases
# и hub.docker.com/r/joplin/server/tags

# 3. Обновите тег в .env
sudo -u joplin nano /opt/joplin/.env  # JOPLIN_VERSION=...

# 4. Применить
cd /opt/joplin
sudo -u joplin docker compose pull
sudo -u joplin docker compose up -d

# 5. Проверка
curl -fsS https://owl.hello-vanilla.ru/api/ping
```

Никаких автоматических обновлений — всё руками после прочтения changelog.

### Просмотр логов

```bash
cd /opt/joplin
sudo -u joplin docker compose logs -f app
sudo -u joplin docker compose logs -f db
sudo tail -f /var/log/joplin-backup.log
```

## Footprint на VPS

Что стек создаёт и где:

| Путь / ресурс | Создаётся | Назначение |
|---|---|---|
| `/opt/joplin/` | bootstrap + deploy | код, `.env`, `data/postgres/` |
| `/var/backups/joplin/` | bootstrap | дампы pg_dump |
| `/var/log/joplin-backup.log` | первый запуск backup.sh | лог бэкапов |
| `/etc/nginx/sites-available/owl.hello-vanilla.ru.conf` + симлинк в `sites-enabled/` | deploy | конфиг nginx |
| `/etc/letsencrypt/live/owl.hello-vanilla.ru/` | certbot | сертификат |
| `/etc/letsencrypt/renewal/owl.hello-vanilla.ru.conf` | certbot | конфиг автообновления |
| crontab пользователя `joplin` | deploy | задача backup.sh |
| `/etc/logrotate.d/joplin-backup` | deploy | ротация логов |
| Системный пользователь `joplin` (uid auto), группа `docker` | bootstrap | владелец стека |
| UFW-правила: SSH-порт, 80/tcp, 443/tcp | bootstrap | firewall |
| TCP `127.0.0.1:22300` | docker compose | публикуемый порт Joplin |

Чужие конфиги (`/etc/nginx/sites-enabled/default`, другие compose-проекты,
Docker-сети других стеков) — **не трогаются.**

## Удаление стека

```bash
# 1. Снять стек
cd /opt/joplin
sudo -u joplin docker compose down -v

# 2. Удалить данные и код
sudo rm -rf /opt/joplin /var/backups/joplin /var/log/joplin-backup.log

# 3. Снять nginx-конфиг
sudo rm -f /etc/nginx/sites-enabled/owl.hello-vanilla.ru.conf
sudo rm -f /etc/nginx/sites-available/owl.hello-vanilla.ru.conf
sudo systemctl reload nginx

# 4. Удалить сертификат
sudo certbot delete --cert-name owl.hello-vanilla.ru

# 5. Удалить cron-задачу
sudo crontab -u joplin -e   # удалить строку с backup.sh

# 6. Удалить logrotate-конфиг
sudo rm -f /etc/logrotate.d/joplin-backup

# 7. (опционально) Удалить пользователя
sudo userdel -r joplin
```

Пакеты (docker, nginx, certbot, ufw) и UFW-правила 80/443 **не удаляются** —
могут быть нужны другим приложениям.

## Чек-лист приёмки

После первого деплоя:

- [ ] `https://owl.hello-vanilla.ru` открывается в браузере, загружается web UI Joplin
- [ ] `curl -fsS https://owl.hello-vanilla.ru/api/ping` возвращает 200
- [ ] `curl -sI http://owl.hello-vanilla.ru/ | head -1` показывает `301 Moved Permanently`
- [ ] [SSL Labs](https://www.ssllabs.com/ssltest/) для домена показывает A или выше
- [ ] `sudo certbot certificates` показывает expiry > 60 дней
- [ ] `systemctl list-timers | grep certbot` — таймер активен
- [ ] `sudo ufw status verbose` — активен, в правилах SSH, 80, 443
- [ ] Дефолтные креды `admin@localhost` / `admin` сменены через web UI
- [ ] Joplin desktop клиент подключается и синхронизирует тестовую заметку
- [ ] `sudo -u joplin /opt/joplin/scripts/backup.sh` работает, в `/var/backups/joplin/` появляется свежий `.dump.gz`, `gunzip -t` проходит
- [ ] `docker compose down && docker compose up -d` — стек переподнимается без потери данных
````

- [ ] **Step 2: Базовая проверка**

```bash
grep -q 'owl.hello-vanilla.ru' README.md
grep -q 'bootstrap.sh' README.md
grep -q 'deploy.sh' README.md
grep -q 'Footprint на VPS' README.md
echo "OK: README покрывает развёртывание, эксплуатацию, footprint и удаление"
```

- [ ] **Step 3: Закоммитить**

```bash
git add README.md
git commit -m "Добавить README: развёртывание, эксплуатация, footprint и удаление"
```

---

## Task 10: Финальная проверка структуры репозитория

**Files:** (никаких изменений, только верификация)

- [ ] **Step 1: Сверить структуру**

```bash
find . -type f \
  -not -path './.git/*' \
  -not -path './data/*' \
  -not -name '.env' \
  | sort
```

Ожидание (точный список):
```
./.gitignore
./README.md
./docker-compose.yml
./docs/superpowers/plans/2026-05-01-joplin-vps-deploy.md
./docs/superpowers/specs/2026-05-01-joplin-vps-deploy-design.md
./.env.example
./logrotate/joplin-backup
./nginx/owl.hello-vanilla.ru.conf
./scripts/backup.sh
./scripts/bootstrap.sh
./scripts/deploy.sh
./scripts/restore.sh
```

- [ ] **Step 2: Проверить права на скрипты**

```bash
ls -l scripts/
```

Ожидание: у всех `.sh` бит исполняемости (`-rwxr-xr-x`).

Если у какого-то нет:
```bash
chmod +x scripts/*.sh
```

- [ ] **Step 3: Проверить что .env (если случайно появился) не в git**

```bash
git check-ignore .env && echo "OK: .env игнорируется"
git ls-files | grep -q '^\.env$' && echo "ОШИБКА: .env в git" || echo "OK: .env не в git"
```

Ожидание: `.env игнорируется` и `.env не в git`.

- [ ] **Step 4: Проверить чистоту рабочего дерева**

```bash
git status
```

Ожидание: `nothing to commit, working tree clean`.

- [ ] **Step 5: Просмотреть лог коммитов**

```bash
git log --oneline
```

Ожидание (порядок снизу вверх):
1. Добавить дизайн-документ
2. Поправить дизайн-документ после self-review
3. Добавить план реализации (если коммитили)
4. Добавить .gitignore
5. Добавить docker-compose.yml и .env.example
6. Добавить стартовый nginx-конфиг
7. Добавить scripts/bootstrap.sh
8. Добавить scripts/deploy.sh
9. Добавить scripts/backup.sh
10. Добавить scripts/restore.sh
11. Добавить logrotate-конфиг
12. Добавить README

---

## После выполнения плана

Артефакты в репозитории готовы. Дальнейшие шаги — **на VPS**, в этом плане они не выполняются:

1. Залить репо на VPS в `/tmp/joplin-bootstrap/` (`rsync` по ssh).
2. Поправить `SSH_PORT` в `scripts/bootstrap.sh`.
3. Запустить `sudo ./scripts/bootstrap.sh`.
4. Перенести в `/opt/joplin/`, сменить владельца на `joplin`.
5. Запустить `sudo -u joplin ./scripts/deploy.sh`.
6. Сменить дефолтные креды Joplin через web UI.
7. (Опционально) включить HSTS — см. `README.md`.
8. Прогнать чек-лист приёмки из `README.md`.
