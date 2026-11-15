#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

DRY=0
REPO=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    --repo) REPO=1 ;;
    -*) echo "Tuy chon khong hop le: $arg" >&2; exit 1 ;;
    *) echo "Tham so khong hop le: $arg" >&2; exit 1 ;;
  esac
done

RUNNING=0
docker inspect -f '{{.State.Running}}' moodle_web 2>/dev/null | grep -q true && RUNNING=1 || true

if [ "$REPO" -eq 1 ]; then
  SIZE="?"
  if [ "$RUNNING" -eq 1 ]; then
    SIZE=$(docker exec moodle_web du -sh /backup/restic 2>/dev/null | cut -f1 || echo "?")
  fi
  echo "Se xoa toan bo kho restic: backup/restic (${SIZE})"
  echo "Mat khau trong .env giu nguyen; lan backup sau se tao kho moi."
  if [ "$DRY" -eq 1 ]; then
    echo "Dry-run: khong xoa gi."
    exit 0
  fi
  read -p "Go 'XOA' de xac nhan: " ANSWER
  [ "$ANSWER" = "XOA" ] || { echo "Da huy."; exit 0; }
  if [ "$RUNNING" -eq 1 ]; then
    docker exec moodle_web rm -rf /backup/restic
  else
    sudo rm -rf backup/restic
  fi
  echo "Da xoa backup/restic."
  exit 0
fi

[ "$RUNNING" -eq 1 ] || { echo "Container moodle_web khong chay" >&2; exit 1; }
docker exec moodle_web sh -c 'test -n "$RESTIC_PASSWORD"' \
  || { echo "Thieu RESTIC_PASSWORD trong .env" >&2; exit 1; }

echo "Snapshot hien co:"
docker exec moodle_web restic snapshots

FORGET="restic forget --host moodle --tag files --keep-last 0 --prune --unsafe-allow-remove-all"
if [ "$DRY" -eq 1 ]; then
  echo
  echo "Dry-run: se xoa toan bo snapshot cua host moodle, tag files."
  docker exec moodle_web sh -c "$FORGET --dry-run"
  exit 0
fi

read -p "Go 'XOA' de xoa toan bo snapshot: " ANSWER
[ "$ANSWER" = "XOA" ] || { echo "Da huy."; exit 0; }

docker exec moodle_web sh -c "$FORGET"

echo
echo "Con lai:"
docker exec moodle_web restic snapshots || true
docker exec moodle_web du -sh /backup/restic
