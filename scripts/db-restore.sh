#!/bin/bash
set -e
# Restore DB tu file sql (mac dinh: backup/moodle_latest.sql)
# Usage: bash scripts/db-restore.sh [path/to/file.sql]
#
# Khong doc .env tren host: lay thong tin ket noi tu environment cua container
# moodle_db. Nho vay script chay duoc ca khi .env thuoc user khac.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

FILE="${1:-backup/moodle_latest.sql}"
[ -f "$FILE" ] || { echo "Not found: $FILE" >&2; exit 1; }

DB=$(docker exec moodle_db sh -c 'printf %s "$MYSQL_DATABASE"')
[ -n "$DB" ] || { echo "Khong doc duoc MYSQL_DATABASE tu container moodle_db" >&2; exit 1; }

read -p "Restore $FILE -> DB $DB? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[yY]$ ]] || { echo "Cancelled."; exit 0; }

docker exec -i moodle_db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -u root --default-character-set=utf8mb4 "$MYSQL_DATABASE"' < "$FILE"

echo "Done: restored $FILE"
