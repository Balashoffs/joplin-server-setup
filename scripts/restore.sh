#!/usr/bin/env bash
# scripts/restore.sh — восстановление Joplin из дампа .dump.gz.
# Использование: ./scripts/restore.sh /var/backups/joplin/joplin-YYYY-MM-DD_HHMM.dump.gz
#
# ДЕСТРУКТИВНО: уничтожает текущие данные Joplin.
# Не атомарно: при ошибке посередине БД остаётся в полу-восстановленном
# состоянии. Скрипт делает safety-дамп до начала. Re-run после ошибки
# безопасен (DROP+CREATE сбрасывает схему).
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

# Не пересекаться с backup.sh (cron запускает его в 03:17)
exec 9>/var/lock/joplin-backup.lock
flock 9   # блокирующий — ждём, если бэкап в процессе

echo "==> Проверка целостности дампа"
gunzip -t "$DUMP"

cd /opt/joplin
set -a
# shellcheck disable=SC1091
source .env
set +a

# Защита от пустых значений в .env
: "${POSTGRES_USER:?POSTGRES_USER не задан в .env}"
: "${POSTGRES_DB:?POSTGRES_DB не задан в .env}"

cat <<EOF

ВНИМАНИЕ: восстановление УНИЧТОЖИТ текущие данные Joplin.
  Дамп: $DUMP
  БД:   $POSTGRES_DB (на хосте db в docker compose)

Перед DROP схемы будет снят safety-дамп в /var/backups/joplin/pre-restore-*.dump.gz.
В случае ошибки посередине данные останутся в полу-восстановленном состоянии;
повторите запуск с тем же дампом или с safety-дампом.

EOF
read -rp "Продолжить? [y/N] " ANSWER
if [[ "$ANSWER" != "y" && "$ANSWER" != "Y" ]]; then
    echo "Отмена."
    exit 1
fi

# Safety-дамп до любой деструктивной операции
SAFETY="/var/backups/joplin/pre-restore-$(date +%Y-%m-%d_%H%M%S).dump.gz"
echo "==> Safety-дамп: $SAFETY"
docker compose exec -T db \
    pg_dump -U "$POSTGRES_USER" -Fc "$POSTGRES_DB" \
    | gzip > "$SAFETY"
gunzip -t "$SAFETY"
echo "  safety-дамп сохранён"

# ERR-trap: при любой ошибке после этой точки гарантируем что app снова запущен
trap 'rc=$?; echo "[restore] прервано на строке $LINENO (exit $rc), пытаюсь поднять app" >&2; docker compose start app >/dev/null 2>&1 || true; echo "Safety-дамп: $SAFETY" >&2; exit "$rc"' ERR

echo "==> Остановка app"
docker compose stop --timeout 30 app

echo "==> Сброс схемы public"
docker compose exec -T db \
    psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    -v ON_ERROR_STOP=1 \
    -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;'

echo "==> Накат дампа"
gunzip -c "$DUMP" \
    | docker compose exec -T db \
        pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
        --no-owner --no-acl --exit-on-error

echo "==> Старт app"
docker compose start app

echo "==> Проверка ping"
curl -fsS --retry 30 --retry-delay 2 -o /dev/null \
    http://127.0.0.1:22300/api/ping

echo "==> Восстановление завершено."
echo "  Safety-дамп остался: $SAFETY"
