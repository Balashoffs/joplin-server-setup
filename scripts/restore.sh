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
