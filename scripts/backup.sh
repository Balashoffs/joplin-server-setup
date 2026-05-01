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
