#!/bin/sh
set -e
# Usage: sh scripts/log-rotate.sh
# copytruncate: cac service deu ghi append nen an toan

D=$(date +%F)

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
rotate /logs/redis/redis.log

find /logs -name '*-*.log' -mtime +30 -delete
find /logs/caddy -name 'access.log.*' -mtime +30 -delete

echo "Done: logs rotated for $D, keep 30 days"
