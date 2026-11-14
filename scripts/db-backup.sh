#!/bin/bash
set -e
# Usage: bash scripts/db-backup.sh
# Chay tren host; viec dump thuc hien trong container moodle_db
# (noi co mysqldump va duong dan /backup).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

docker inspect -f '{{.State.Running}}' moodle_db 2>/dev/null | grep -q true \
  || { echo "Container moodle_db khong chay" >&2; exit 1; }

docker exec moodle_db sh /scripts/db-job.sh

echo
ls -lh backup/moodle_latest.sql
COUNT=$(find backup -maxdepth 1 -type f -name 'moodle_*.sql' ! -name 'moodle_latest.sql' | wc -l)
echo "Ban theo ngay: $COUNT"
du -ch backup/moodle_*.sql | tail -1
