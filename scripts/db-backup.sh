#!/bin/bash
set -e
# Usage: bash scripts/db-backup.sh
# Doc bien moi truong tu container, khong doc .env tren host

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

mkdir -p backup
STAMP=$(date +%F_%H-%M)
OUT="backup/moodle_${STAMP}.sql"
LATEST="backup/moodle_latest.sql"

if ! docker exec moodle_db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysqldump -u root --default-character-set=utf8mb4 --single-transaction --quick "$MYSQL_DATABASE"' > "$OUT"; then
  rm -f "$OUT"
  echo "Backup that bai: kiem tra container moodle_db" >&2
  exit 1
fi

[ -s "$OUT" ] || { echo "Backup rong: $OUT" >&2; rm -f "$OUT"; exit 1; }

cp "$OUT" "$LATEST"
echo "Done: $OUT ($(du -h "$OUT" | cut -f1)) + $LATEST"
