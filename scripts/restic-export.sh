#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

SNAP=latest
OUT=""
for arg in "$@"; do
  case "$arg" in
    --out=*) OUT="${arg#*=}" ;;
    -*) echo "Tuy chon khong hop le: $arg" >&2; exit 1 ;;
    *) SNAP="$arg" ;;
  esac
done

docker inspect -f '{{.State.Running}}' moodle_web 2>/dev/null | grep -q true \
  || { echo "Container moodle_web khong chay" >&2; exit 1; }

docker exec moodle_web sh -c 'test -n "$RESTIC_PASSWORD"' \
  || { echo "Thieu RESTIC_PASSWORD trong .env" >&2; exit 1; }

STAMP=$(date +%F_%H-%M-%S)
OUT="${OUT:-$HOME/moodle-dump_${STAMP}.sql}"
case "$OUT" in
  /*) ;;
  *) OUT="$PWD/$OUT" ;;
esac
mkdir -p "$(dirname "$OUT")"

TMP_CT="/tmp/dbdump-export-${STAMP}"
trap 'docker exec moodle_web rm -rf "$TMP_CT" >/dev/null 2>&1 || true' EXIT

echo "Snapshot: $SNAP"
docker exec moodle_web restic snapshots --latest 2 --tag db

echo
echo "Trich dump ra $OUT"
if [ "$SNAP" = latest ]; then
  docker exec moodle_web restic restore latest \
    --tag db --target "$TMP_CT" --include /backup/dbdump
else
  docker exec moodle_web restic restore "$SNAP" \
    --target "$TMP_CT" --include /backup/dbdump
fi

DUMP_CT="$TMP_CT/backup/dbdump/moodle.sql"
docker exec moodle_web test -s "$DUMP_CT" \
  || { echo "Khong thay dump trong snapshot $SNAP" >&2; exit 1; }

docker exec moodle_web cat "$DUMP_CT" > "$OUT"
chmod 600 "$OUT"

if ! grep -q 'CREATE TABLE' "$OUT"; then
  echo "Canh bao: tep khong co CREATE TABLE, kiem tra lai" >&2
fi

echo
cat <<EOF

Tep SQL:     $OUT
Dung luong:  $(du -h "$OUT" | cut -f1)
Quyen:       $(ls -l "$OUT" | cut -d' ' -f1)

Import thu cong vao co so du lieu that (can than):

  docker exec -i moodle_db sh -c 'MYSQL_PWD="\$MYSQL_ROOT_PASSWORD" mysql -u root "\$MYSQL_DATABASE"' < "$OUT"

Neu import bao loi GTID, loc dong do truoc:

  sed -E '/^SET @@GLOBAL\.GTID_PURGED/d' "$OUT" > "$OUT.clean"

Tep nay khong ma hoa. Chuyen di roi xoa khoi may:

  rm -f "$OUT"
EOF
