#!/bin/sh
set -eu

: "${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD chua duoc dat}"
: "${MYSQL_DATABASE:?MYSQL_DATABASE chua duoc dat}"

BACKUP=/backup
KEEP_DAYS=7
STAMP=$(date +%F_%H-%M-%S)
OUT="$BACKUP/moodle_${STAMP}.sql"
LATEST="$BACKUP/moodle_latest.sql"

mkdir -p "$BACKUP"
umask 077

if ! MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysqldump -u root \
    --default-character-set=utf8mb4 --single-transaction --quick \
    --set-gtid-purged=OFF \
    "$MYSQL_DATABASE" > "$OUT"; then
    rm -f "$OUT"
    echo "[db] dump that bai, giu nguyen ban cu" >&2
    exit 1
fi

[ -s "$OUT" ] || { rm -f "$OUT"; echo "[db] dump rong" >&2; exit 1; }

cp "$OUT" "$LATEST.tmp"
mv "$LATEST.tmp" "$LATEST"

if ! chown --reference="$BACKUP" "$OUT" "$LATEST"; then
    echo "[db] canh bao: khong doi duoc chu so huu tep dump" >&2
fi

echo "[db] xong $OUT ($(du -h "$OUT" | cut -f1))"

echo "[db] don ban cu, giu $KEEP_DAYS ngay"
find "$BACKUP" -maxdepth 1 -type f -name 'moodle_*.sql' \
    ! -name 'moodle_latest.sql' -mtime +$((KEEP_DAYS - 1)) -delete

echo "[db] cac ban con lai:"
ls -1t "$BACKUP"/moodle_*.sql 2>/dev/null | head -8
