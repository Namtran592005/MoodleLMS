#!/bin/bash
set -e
# Restore DB tu file sql (mac dinh: backup/moodle_latest.sql)
# Usage: bash scripts/db-restore.sh [path/to/file.sql]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

[ -f .env ] || { echo "Missing .env"; exit 1; }
set -a; source .env; set +a

FILE="${1:-backup/moodle_latest.sql}"
[ -f "$FILE" ] || { echo "Not found: $FILE"; exit 1; }

read -p "Restore $FILE -> DB $MOODLE_DB_NAME? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[yY]$ ]] || { echo "Cancelled."; exit 0; }

docker exec -i moodle_db mysql -u root -p"$MYSQL_ROOT_PASSWORD" \
  --default-character-set=utf8mb4 "$MOODLE_DB_NAME" < "$FILE"

echo "Done: restored $FILE"
