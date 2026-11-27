#!/bin/bash
set -e

# Usage: bash scripts/restic-restore.sh [snapshot] [--in-place]
#   snapshot    latest (mac dinh) hoac ID lay tu "restic snapshots"
#   --in-place  chep de len moodledata/ ngay, co dung site trong luc chep
#
# Mac dinh chi phuc hoi ra backup/restore_<thoi-gian>, khong dung du lieu that.
# Chay tren host, trong thu muc project.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

SNAP=latest
IN_PLACE=0
WANT_DB=0
WANT_FILES=0
for arg in "$@"; do
  case "$arg" in
    --in-place) IN_PLACE=1 ;;
    --db) WANT_DB=1 ;;
    --files) WANT_FILES=1 ;;
    -*) echo "Tuy chon khong hop le: $arg" >&2; exit 1 ;;
    *) SNAP="$arg" ;;
  esac
done

if [ "$WANT_DB" -eq 0 ] && [ "$WANT_FILES" -eq 0 ]; then
  WANT_DB=1
  WANT_FILES=1
fi

docker inspect -f '{{.State.Running}}' moodle_web 2>/dev/null | grep -q true \
  || { echo "Container moodle_web khong chay" >&2; exit 1; }

docker exec moodle_web sh -c 'test -n "$RESTIC_PASSWORD"' \
  || { echo "Thieu RESTIC_PASSWORD trong .env" >&2; exit 1; }

STAMP=$(date +%F_%H-%M-%S)
TARGET_CT="/backup/restore_${STAMP}"
TARGET_HOST="backup/restore_${STAMP}"
DUMP_HOST=""  # se tim sau khi phuc hoi

INCLUDES=()
[ "$WANT_FILES" -eq 1 ] && INCLUDES+=(--include /var/www/moodledata)
[ "$WANT_DB" -eq 1 ] && INCLUDES+=(--include /backup/dbdump)

echo "Snapshot: $SNAP"
docker exec moodle_web restic snapshots --latest 4

echo
echo "Phuc hoi ra $TARGET_HOST (khong dung du lieu that)"
if [ "$SNAP" = latest ]; then
  if [ "$WANT_DB" -eq 1 ]; then
    docker exec moodle_web restic restore latest \
      --tag db --target "$TARGET_CT"
  fi
  if [ "$WANT_FILES" -eq 1 ]; then
    docker exec moodle_web restic restore latest \
      --tag files --target "$TARGET_CT"
  fi
else
  docker exec moodle_web restic restore "$SNAP" \
    --target "$TARGET_CT"
fi
docker exec moodle_web chown -R www-data:www-data "$TARGET_CT"

# Dam bao thu muc tam doc duoc boi tai khoan host (uid/gid hien tai), phong
# truong hop uid cua www-data trong container khac uid tai khoan host.
docker exec moodle_web chown -R "$(id -u):$(id -g)" "$TARGET_CT" 2>/dev/null || true
docker exec moodle_web chmod -R u+rX "$TARGET_CT" 2>/dev/null || true

# Tim file dump trong snapshot da phuc hoi (duong dan co the khac nhau
# tuy phien ban restic-job.sh). Tim theo ten moodle.sql, neu khong co thi tim *.sql.
if [ "$WANT_DB" -eq 1 ]; then
  DUMP_CT=$(docker exec moodle_web find "$TARGET_CT" -type f -name "moodle.sql" 2>/dev/null | head -n 1)
  if [ -z "$DUMP_CT" ]; then
    DUMP_CT=$(docker exec moodle_web find "$TARGET_CT" -type f -name "*.sql" 2>/dev/null | head -n 1)
  fi
  if [ -z "$DUMP_CT" ]; then
    echo "Khong tim thay dump SQL trong snapshot. Cau truc da phuc hoi:" >&2
    docker exec moodle_web find "$TARGET_CT" -type f 2>/dev/null | head -20 >&2
    exit 1
  fi
  DUMP_HOST="${DUMP_CT#/}"
  echo "Tim thay dump: $DUMP_HOST"
fi

if [ "$WANT_FILES" -eq 1 ]; then
  RESTORED=$(docker exec moodle_web find "$TARGET_CT/var/www/moodledata/filedir" -type f 2>/dev/null | wc -l)
  CURRENT=$(find moodledata/filedir -type f | wc -l)
  echo
  echo "Tep trong ban phuc hoi: $RESTORED"
  echo "Tep dang dung:           $CURRENT"
  echo "Duong dan:               $TARGET_HOST/var/www/moodledata"
fi

if [ "$WANT_DB" -eq 1 ]; then
  if [ ! -f "$DUMP_HOST" ]; then
    # Thu tim tren host (phong truong hop duong dan khac)
    FOUND_HOST=$(find "$TARGET_HOST" -type f -name "moodle.sql" 2>/dev/null | head -n 1)
    if [ -n "$FOUND_HOST" ]; then
      DUMP_HOST="$FOUND_HOST"
    else
      echo "Khong thay dump trong snapshot: $DUMP_HOST" >&2
      echo "Cau truc thu muc da phuc hoi:" >&2
      find "$TARGET_HOST" -type f 2>/dev/null | head -20 >&2
      exit 1
    fi
  fi
  echo
  echo "Dump co so du lieu:       $DUMP_HOST ($(du -h "$DUMP_HOST" | cut -f1))"
fi

if [ "$IN_PLACE" -eq 0 ]; then
  cat <<EOF

Chua dung vao du lieu that. Khi can phuc hoi that:

  docker compose stop moodle cron
EOF
  if [ "$WANT_DB" -eq 1 ]; then
    cat <<EOF
  sed -E '/^SET @@GLOBAL\\.GTID_PURGED/d' $DUMP_HOST \\
    | docker exec -i moodle_db sh -c 'MYSQL_PWD="\$MYSQL_ROOT_PASSWORD" mysql -u root --default-character-set=utf8mb4 "\$MYSQL_DATABASE"'
EOF
  fi
  if [ "$WANT_FILES" -eq 1 ]; then
    cat <<EOF
  cp -a $TARGET_HOST/var/www/moodledata/. moodledata/
EOF
  fi
  cat <<EOF
  bash scripts/fix-perms.sh
  docker compose start moodle cron
  docker exec -u www-data moodle_web php /var/www/html/admin/cli/purge_caches.php

Hoac chay lai voi --in-place de tu dong dung site va phuc hoi.
EOF
  exit 0
fi

WHAT=""
[ "$WANT_DB" -eq 1 ] && WHAT="DB"
[ "$WANT_FILES" -eq 1 ] && WHAT="${WHAT:+$WHAT + }tep"
echo
read -p "Phuc hoi $WHAT tu $SNAP? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[yY]$ ]] || { echo "Da huy."; exit 0; }

echo
echo "Dung site trong luc phuc hoi"
docker compose stop moodle cron

if [ "$WANT_DB" -eq 1 ]; then
  echo "Import co so du lieu"
  sed -E '/^SET @@GLOBAL\.GTID_PURGED/d' "$DUMP_HOST" \
    | docker exec -i moodle_db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -u root --default-character-set=utf8mb4 "$MYSQL_DATABASE"'
fi

if [ "$WANT_FILES" -eq 1 ]; then
  echo "Chep tep"
  cp -a "$TARGET_HOST/var/www/moodledata/." moodledata/

  if find moodledata -not -user "$(id -u)" -print -quit | grep -q .; then
    echo "Canh bao: con tep khong thuoc $(id -un), chay: bash scripts/fix-perms.sh" >&2
  fi
fi

echo "Khoi dong lai"
docker compose start moodle cron
STATUS=unknown
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
EOF
