#!/bin/sh
set -eu

: "${RESTIC_PASSWORD:?RESTIC_PASSWORD chua duoc dat trong .env}"
: "${MOODLE_DB_HOST:?MOODLE_DB_HOST chua duoc dat}"
: "${MOODLE_DB_NAME:?MOODLE_DB_NAME chua duoc dat}"
: "${MOODLE_DB_USER:?MOODLE_DB_USER chua duoc dat}"
: "${MOODLE_DB_PASSWORD:?MOODLE_DB_PASSWORD chua duoc dat}"

DATA=/var/www/moodledata
DUMP_DIR=/backup/dbdump
DUMP="$DUMP_DIR/moodle.sql"
TMP="$DUMP.tmp"
export RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-/backup/restic}"
export RESTIC_PASSWORD

case "$RESTIC_REPOSITORY" in
    /*) mkdir -p "$RESTIC_REPOSITORY" ;;
esac

mkdir -p "$DUMP_DIR"
umask 077
trap 'rm -f "$TMP" "$DUMP"' EXIT INT TERM

if ! restic snapshots >/dev/null 2>&1; then
    echo "[restic] khoi tao repo $RESTIC_REPOSITORY"
    restic init
fi

echo "[restic] dump $MOODLE_DB_NAME tu $MOODLE_DB_HOST"
if ! MYSQL_PWD="$MOODLE_DB_PASSWORD" mysqldump \
    -h "$MOODLE_DB_HOST" -u "$MOODLE_DB_USER" --skip-ssl \
    --default-character-set=utf8mb4 --single-transaction --quick \
    --skip-lock-tables --no-tablespaces --routines --events \
    --triggers "$MOODLE_DB_NAME" > "$TMP"; then
    echo "[restic] dump that bai, giu nguyen ban cu" >&2
    exit 1
fi

if [ ! -s "$TMP" ] || ! grep -q 'CREATE TABLE' "$TMP"; then
    echo "[restic] dump rong hoac thieu bang, giu nguyen ban cu" >&2
    exit 1
fi
mv "$TMP" "$DUMP"
echo "[restic] dump xong $(du -h "$DUMP" | cut -f1)"

echo "[restic] bat dau $(date -u '+%F %T UTC')"
restic backup "$DATA" "$DUMP_DIR" \
    --host moodle \
    --tag full \
    --exclude=/var/www/moodledata/cache \
    --exclude=/var/www/moodledata/localcache \
    --exclude=/var/www/moodledata/temp \
    --exclude=/var/www/moodledata/sessions \
    --exclude=/var/www/moodledata/muc \
    --exclude=/var/www/moodledata/environment \
    --exclude=/var/www/moodledata/antivirus_quarantine \
    --exclude=/var/www/moodledata/trashdir

echo "[restic] don ban cu, giu 7 ngay"
restic forget \
    --host moodle \
    --group-by host \
    --keep-daily 7 \
    --prune
echo "[restic] xong $(date -u '+%F %T UTC')"
