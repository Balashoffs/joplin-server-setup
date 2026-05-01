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
