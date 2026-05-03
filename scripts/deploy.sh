#!/usr/bin/env bash
# scripts/deploy.sh — первичный деплой Joplin на подготовленный VPS.
# Запускать из /opt/joplin от пользователя joplin.
# Идемпотентен.
set -euo pipefail

cd "$(dirname "$0")/.."
PROJECT_DIR="$(pwd)"

# === Пред-проверки ===
if [[ $EUID -eq 0 ]]; then
    echo "Запускать от пользователя joplin, не root." >&2
    echo "  sudo -u joplin bash -lc 'cd /opt/joplin && ./scripts/deploy.sh'" >&2
    echo "Иначе .env и сгенерированные файлы окажутся с владельцем root." >&2
    exit 1
fi

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

if ! sudo ufw status | grep -qw active; then
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

# Освежить sudo timestamp заранее, чтобы пароль не запросили посреди долгого деплоя
sudo -v

# === Старт стека ===
echo "==> docker compose pull"
docker compose pull
echo "==> docker compose up -d"
docker compose up -d

# echo "==> Ожидание Joplin на 127.0.0.1:22300"
# curl -fsS --retry 30 --retry-delay 2 -o /dev/null http://127.0.0.1:22300/api/ping
#echo "  Joplin отвечает локально"

# === Nginx ===
NGINX_AVAILABLE=/etc/nginx/sites-available/example.com.conf
NGINX_ENABLED=/etc/nginx/sites-enabled/example.com.conf

echo "==> Установка nginx-конфига"
sudo cp nginx/example.com.conf "$NGINX_AVAILABLE"
if [[ ! -L "$NGINX_ENABLED" ]] || [[ "$(readlink "$NGINX_ENABLED")" != "$NGINX_AVAILABLE" ]]; then
    sudo ln -sfn "$NGINX_AVAILABLE" "$NGINX_ENABLED"
fi
sudo nginx -t
sudo systemctl reload nginx

# === Certbot ===
if sudo certbot certificates 2>/dev/null \
    | grep -q "Certificate Name: example.com"; then
    echo "==> Сертификат уже выпущен, пропускаю certbot"
else
    echo "==> Выпуск сертификата Let's Encrypt"
    sudo certbot --nginx \
        -d example.com \
        -m "$CERTBOT_EMAIL" \
        --agree-tos --no-eff-email \
        --redirect \
        --deploy-hook "systemctl reload nginx"
fi

# === Default-fallback (для запросов с неизвестным Host) ===
DEFAULT_AVAILABLE=/etc/nginx/sites-available/00-default-fallback.conf
DEFAULT_ENABLED=/etc/nginx/sites-enabled/00-default-fallback.conf

echo "==> Установка default-fallback nginx-конфига"
# Если активен Ubuntu's sites-enabled/default — отключаем его (наш fallback
# заменяет default_server). Файл в sites-available/ оставляем, можно вернуть.
if [[ -L /etc/nginx/sites-enabled/default ]]; then
    echo "  отключаю sites-enabled/default (заменяется нашим fallback)"
    sudo rm /etc/nginx/sites-enabled/default
fi

sudo cp nginx/00-default-fallback.conf "$DEFAULT_AVAILABLE"
if [[ ! -L "$DEFAULT_ENABLED" ]] || [[ "$(readlink "$DEFAULT_ENABLED")" != "$DEFAULT_AVAILABLE" ]]; then
    sudo ln -sfn "$DEFAULT_AVAILABLE" "$DEFAULT_ENABLED"
fi

# Проверяем nginx -t, при ошибке откатываем (убираем наш симлинк, возвращаем
# Ubuntu default если он был).
if ! sudo nginx -t 2>&1; then
    echo "ОШИБКА: nginx -t упал после установки default-fallback. Откатываю." >&2
    sudo rm -f "$DEFAULT_ENABLED"
    if [[ -f /etc/nginx/sites-available/default ]]; then
        sudo ln -sfn /etc/nginx/sites-available/default \
            /etc/nginx/sites-enabled/default
    fi
    sudo nginx -t
    exit 1
fi
sudo systemctl reload nginx

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
if curl -fsS https://example.com/api/ping >/dev/null; then
    echo "  HTTPS ping OK"
else
    echo "  ВНИМАНИЕ: HTTPS ping FAILED"
fi
HTTP_CODE=$(curl -sIo /dev/null -w '%{http_code}' http://example.com/)
if [[ "$HTTP_CODE" == "301" || "$HTTP_CODE" == "308" ]]; then
    echo "  HTTP→HTTPS редирект OK ($HTTP_CODE)"
else
    echo "  ВНИМАНИЕ: HTTP вернул $HTTP_CODE (ожидалось 301/308)"
fi
sudo certbot certificates 2>/dev/null \
    | grep -A2 "example.com" || true

cat <<'EOF'

==> Деплой завершён.
URL: https://example.com
Дефолтные креды: admin@localhost / admin
ВАЖНО: войдите и НЕМЕДЛЕННО смените пароль и email админа.

HSTS не включён автоматически — после проверки HTTPS см. README.
EOF
