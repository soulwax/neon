#!/usr/bin/env bash
# Neon database backup — runs inside compute container via trust auth (loopback)
# Stores daily compressed dumps; keeps 14 days.
set -euo pipefail

BACKUP_DIR="/home/soulwax/neon/backups"
DATE=$(date +%Y%m%d-%H%M%S)
DAY_DIR="$BACKUP_DIR/$DATE"
COMPUTE="docker-compose-compute1-1"
PSQL="docker exec $COMPUTE psql -U cloud_admin -h 127.0.0.1 -p 55433"
PG_DUMP="docker exec $COMPUTE pg_dump -U cloud_admin -h 127.0.0.1 -p 55433 -Fc"
KEEP_DAYS=14

mkdir -p "$DAY_DIR"

# List non-template databases
DATABASES=$($PSQL postgres -tAc "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname;" 2>&1)

echo "[$(date -Is)] Starting backup to $DAY_DIR"
for db in $DATABASES; do
    echo "[$(date -Is)] Dumping: $db"
    $PG_DUMP -d "$db" > "$DAY_DIR/${db}.dump" 2>&1 && \
        echo "[$(date -Is)] OK: $db ($(du -sh "$DAY_DIR/${db}.dump" | cut -f1))" || \
        echo "[$(date -Is)] FAILED: $db"
done

# Rotate: remove backups older than KEEP_DAYS
find "$BACKUP_DIR" -maxdepth 1 -type d -mtime +$KEEP_DAYS -exec rm -rf {} + 2>/dev/null || true

echo "[$(date -Is)] Backup complete. Kept $KEEP_DAYS days of history."
