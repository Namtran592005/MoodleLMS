#!/bin/sh
# Sao luu co so du lieu MySQL.
# Chay trong container moodle_db (Ofelia goi) hoac qua scripts/db-backup.sh tren host.
# Moi lan tao mot ban theo ngay va cap nhat moodle_latest.sql, sau do giu 7 ngay.
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

# Container chay bang root; tra tep ve chu so huu cua thu muc backup
# de tai khoan trien khai doc va ghi de duoc.
if ! chown --reference="$BACKUP" "$OUT" "$LATEST"; then
    echo "[db] canh bao: khong doi duoc chu so huu tep dump" >&2
fi

echo "[db] xong $OUT ($(du -h "$OUT" | cut -f1))"

# Chi don sau khi dump thanh cong (set -e o tren): giu 7 ngay gan nhat.
echo "[db] don ban cu, giu $KEEP_DAYS ngay"
find "$BACKUP" -maxdepth 1 -type f -name 'moodle_*.sql' \
    ! -name 'moodle_latest.sql' -mtime +$((KEEP_DAYS - 1)) -delete

echo "[db] cac ban con lai:"
ls -1t "$BACKUP"/moodle_*.sql 2>/dev/null | head -8
