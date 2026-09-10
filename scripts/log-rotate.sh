#!/bin/sh
set -e
# Xoay log hang ngay, giu 30 ngay. Chay trong container moodle
# qua Ofelia luc 0h VN (17h UTC). Copytruncate: an toan vi cac
# service deu ghi append (caddy/php/mysql/redis).
# Apache (rotatelogs) tu tao file theo ngay, chi can xoa cu.
# Usage: sh scripts/log-rotate.sh

D=$(date +%F)

# Mo log MySQL sinh ra voi quyen han che -> mo read de host doc duoc
chmod -R a+r /logs 2>/dev/null || true

rotate() {
  if [ -s "$1" ]; then
    cp "$1" "${1%.log}-$D.log"
    truncate -s 0 "$1"
  fi
}

rotate /logs/caddy/access.log
rotate /logs/php/error.log
rotate /logs/mysql/error.log
rotate /logs/mysql/slow.log
rotate /logs/mysql/general.log
rotate /logs/redis/redis.log

find /logs -name '*-*.log' -mtime +30 -delete
find /logs/caddy -name 'access.log.*' -mtime +30 -delete

echo "Done: logs rotated for $D, keep 30 days"
