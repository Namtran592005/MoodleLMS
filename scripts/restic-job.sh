#!/bin/sh
# Sao luu moodledata bang restic.
# Chay trong container moodle: RESTIC_PASSWORD lay tu .env,
# repo dat tai /backup/restic (bind mount ./backup).
set -eu

: "${RESTIC_PASSWORD:?RESTIC_PASSWORD chua duoc dat trong .env}"

DATA=/var/www/moodledata
export RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-/backup/restic}"
export RESTIC_PASSWORD

case "$RESTIC_REPOSITORY" in
    /*) mkdir -p "$RESTIC_REPOSITORY" ;;
esac

if ! restic snapshots >/dev/null 2>&1; then
    echo "[restic] khoi tao repo $RESTIC_REPOSITORY"
    restic init
fi

echo "[restic] bat dau $(date -u '+%F %T UTC')"
restic backup "$DATA" \
    --host moodle \
    --tag files \
    --exclude=/var/www/moodledata/cache \
    --exclude=/var/www/moodledata/localcache \
    --exclude=/var/www/moodledata/temp \
    --exclude=/var/www/moodledata/sessions \
    --exclude=/var/www/moodledata/muc \
    --exclude=/var/www/moodledata/environment \
    --exclude=/var/www/moodledata/antivirus_quarantine \
    --exclude=/var/www/moodledata/trashdir

# Chi don sau khi backup thanh cong (set -e): giu 7 ban ngay gan nhat.
echo "[restic] don ban cu, giu 7 ngay"
restic forget \
    --host moodle \
    --tag files \
    --keep-daily 7 \
    --prune
echo "[restic] xong $(date -u '+%F %T UTC')"
