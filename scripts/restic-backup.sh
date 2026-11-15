#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

docker inspect -f '{{.State.Running}}' moodle_web 2>/dev/null | grep -q true \
  || { echo "Container moodle_web khong chay" >&2; exit 1; }

docker exec moodle_web sh /scripts/restic-job.sh

echo
docker exec moodle_web restic snapshots --latest 3
docker exec moodle_web du -sh /backup/restic
