#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

SNAP=latest
IN_PLACE=0
for arg in "$@"; do
  case "$arg" in
    --in-place) IN_PLACE=1 ;;
    -*) echo "Tuy chon khong hop le: $arg" >&2; exit 1 ;;
    *) SNAP="$arg" ;;
  esac
done

docker inspect -f '{{.State.Running}}' moodle_web 2>/dev/null | grep -q true \
  || { echo "Container moodle_web khong chay" >&2; exit 1; }

docker exec moodle_web sh -c 'test -n "$RESTIC_PASSWORD"' \
  || { echo "Thieu RESTIC_PASSWORD trong .env" >&2; exit 1; }

STAMP=$(date +%F_%H-%M-%S)
TARGET_CT="/backup/restore_${STAMP}"
TARGET_HOST="backup/restore_${STAMP}"

echo "Snapshot: $SNAP"
docker exec moodle_web restic snapshots --latest 1

echo
echo "Phuc hoi ra $TARGET_HOST (khong dung du lieu that)"
docker exec moodle_web restic restore "$SNAP" \
  --target "$TARGET_CT" \
  --include /var/www/moodledata
docker exec moodle_web chown -R www-data:www-data "$TARGET_CT"

RESTORED=$(docker exec moodle_web find "$TARGET_CT/var/www/moodledata/filedir" -type f | wc -l)
CURRENT=$(find moodledata/filedir -type f | wc -l)
echo
echo "Tep trong ban phuc hoi: $RESTORED"
echo "Tep dang dung:           $CURRENT"
echo "Duong dan:               $TARGET_HOST/var/www/moodledata"

if [ "$IN_PLACE" -eq 0 ]; then
  cat <<EOF

Chua dung vao moodledata/. Khi can phuc hoi that:

  docker compose stop moodle cron
  bash scripts/db-restore.sh backup/moodle_latest.sql
  cp -a $TARGET_HOST/var/www/moodledata/. moodledata/
  bash scripts/fix-perms.sh
  docker compose start moodle cron
  docker exec -u www-data moodle_web php /var/www/html/admin/cli/purge_caches.php

Hoac chay lai voi --in-place de tu dong dung site, chep tep va khoi dong lai.
EOF
  exit 0
fi

read -p "Chep $TARGET_HOST de len moodledata/? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[yY]$ ]] || { echo "Da huy."; exit 0; }

echo
echo "Dung site trong luc chep"
docker compose stop moodle cron

echo "Chep tep"
cp -a "$TARGET_HOST/var/www/moodledata/." moodledata/

if find moodledata -not -user "$(id -u)" -print -quit | grep -q .; then
  echo "Canh bao: con tep khong thuoc $(id -un), chay: bash scripts/fix-perms.sh" >&2
fi

echo "Khoi dong lai"
docker compose start moodle cron
for _ in $(seq 1 40); do
  STATUS=$(docker inspect -f '{{.State.Health.Status}}' moodle_web 2>/dev/null || echo unknown)
  [ "$STATUS" = healthy ] && break
  sleep 3
done
echo "moodle_web: $STATUS"

docker exec -u www-data moodle_web php /var/www/html/admin/cli/purge_caches.php

cat <<EOF

Xong. Kiem tra site, sau do co the xoa ban tam:

  rm -rf $TARGET_HOST

Neu cung phuc hoi co so du lieu, chay:
  bash scripts/db-restore.sh backup/moodle_latest.sql
EOF
