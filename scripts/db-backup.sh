#!/bin/bash
set -e
# Backup DB -> backup/moodle_YYYY-MM-DD_HH-MM.sql + moodle_latest.sql
# Usage: bash scripts/db-backup.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

[ -f .env ] || { echo "Missing .env"; exit 1; }
set -a; source .env; set +a

mkdir -p backup
STAMP=$(date +%F_%H-%M)
OUT="backup/moodle_${STAMP}.sql"
LATEST="backup/moodle_latest.sql"

docker exec moodle_db mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" \
  --default-character-set=utf8mb4 --single-transaction --quick \
  "$MOODLE_DB_NAME" > "$OUT"

cp "$OUT" "$LATEST"
echo "Done: $OUT ($(du -h "$OUT" | cut -f1)) + $LATEST"
