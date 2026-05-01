#!/usr/bin/env bash
# scripts/backup.sh — ежедневный pg_dump Joplin с ротацией.
# Запускается из cron пользователя joplin.
set -euo pipefail

# Не позволять двум бэкапам идти одновременно (cron + ручной запуск)
exec 9>/var/lock/joplin-backup.lock
if ! flock -n 9; then
    echo "[$(date +'%F %T')] другой бэкап уже идёт, пропускаю"
    exit 0
fi

# Логировать сбой с timestamp + строкой, на которой упало
trap 'echo "[$(date +"%F %T")] backup FAILED on line $LINENO (exit $?)" >&2' ERR

cd /opt/joplin

# Загрузить переменные из .env
set -a
# shellcheck disable=SC1091
source .env
set +a

# Защита от пустых значений в .env
: "${POSTGRES_USER:?POSTGRES_USER не задан в .env}"
: "${POSTGRES_DB:?POSTGRES_DB не задан в .env}"

START=$(date +%s)
TS=$(date +%Y-%m-%d_%H%M)
BACKUP_DIR=/var/backups/joplin
DUMP="${BACKUP_DIR}/joplin-${TS}.dump.gz"
TMP="${DUMP}.partial"

# Если скрипт упадёт — удалить незавершённый файл, не оставлять мусор
cleanup_partial() { rm -f "$TMP"; }
trap 'cleanup_partial; echo "[$(date +"%F %T")] backup FAILED on line $LINENO (exit $?)" >&2' ERR

echo "[$(date +'%F %T')] backup starting → $DUMP"

# === Дамп в .partial ===
docker compose exec -T db \
    pg_dump -U "$POSTGRES_USER" -Fc "$POSTGRES_DB" \
    | gzip > "$TMP"

# === Проверка целостности gzip ===
gunzip -t "$TMP"

# === Проверка структуры pg_dump (ловит обрыв в середине дампа) ===
gunzip -c "$TMP" | docker compose exec -T db pg_restore --list >/dev/null

# === Проверка минимального размера (пустой дамп — подозрительно) ===
if [[ "$(stat -c%s "$TMP")" -lt 1024 ]]; then
    echo "[$(date +'%F %T')] backup FAILED: дамп слишком маленький ($(stat -c%s "$TMP") байт)" >&2
    exit 1
fi

# === Атомарно переименовать в финальное имя ===
mv "$TMP" "$DUMP"
SIZE=$(du -h "$DUMP" | cut -f1)
ELAPSED=$(( $(date +%s) - START ))
echo "[$(date +'%F %T')] backup OK: $DUMP ($SIZE) за ${ELAPSED}s"

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
