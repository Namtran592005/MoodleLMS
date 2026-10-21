#!/bin/bash
set -e

# UID/GID: uu tien PUID/PGID, neu khong tu do owner moodle/ hoac moodledata/
detect_ids() {
  if [ -n "${PUID:-}" ] && [ -n "${PGID:-}" ]; then
    echo "${PUID} ${PGID}"
    return
  fi
  for d in /var/www/html /var/www/moodledata /backup; do
    [ -d "$d" ] || continue
    u="$(stat -c %u "$d")"
    g="$(stat -c %g "$d")"
    # bo qua root va UID he thong (< 1000) cua ban cu dung 777
    if [ "$u" -ge 1000 ] 2>/dev/null; then
      echo "${u} ${g}"
      return
    fi
  done
  echo "1000 1000"
}

read -r U G <<< "$(detect_ids)"

if [ "$(id -u www-data)" != "$U" ] || [ "$(id -g www-data)" != "$G" ]; then
  echo "Chinh www-data -> ${U}:${G} (khop tai khoan host)"
  groupmod -o -g "$G" www-data
  usermod -o -u "$U" -g "$G" www-data
fi
echo "www-data = $(id -u www-data):$(id -g www-data)"

mkdir -p /var/www/moodledata /var/log/moodle /var/log/php \
         /logs/caddy /logs/mysql /logs/redis

# /logs/mysql va /logs/redis do db/redis ghi; chi them group cua user host
chown -R "${U}:${G}" /logs/caddy /var/log/moodle /var/log/php 2>/dev/null || true
chown "${U}:${G}" /logs /backup 2>/dev/null || true
chown -R "${U}:${G}" /backup 2>/dev/null || true
find /backup -perm -o+w -type d -exec chmod 755 {} + 2>/dev/null || true
find /backup -perm -o+w -type f -exec chmod 644 {} + 2>/dev/null || true
for d in /logs/mysql /logs/redis; do
  if [ -d "$d" ]; then
    chgrp -R "${G}" "$d" 2>/dev/null || true
    chmod -R g+rwX "$d" 2>/dev/null || true
  fi
done
chmod -R a+rX /logs /var/log/moodle /var/log/php 2>/dev/null || true

# chi chown khi co file lech owner
ensure_owner() {
  dir="$1"
  [ -d "$dir" ] || return 0
  if [ -n "$(find "$dir" \( ! -user "$U" -o ! -group "$G" -o -perm -o+w \) -print -quit 2>/dev/null)" ]; then
    echo "Fixing ownership in $dir ..."
    chown -R "${U}:${G}" "$dir" || true
    # ha quyen 777 cua ban cu, khong dung toi thu muc 700 (vd sessions)
    find "$dir" -perm -o+w -type d -exec chmod 755 {} + 2>/dev/null || true
    find "$dir" -perm -o+w -type f -exec chmod u+rwX,go+r-w {} + 2>/dev/null || true
  fi
}
ensure_owner /var/www/html
ensure_owner /var/www/moodledata

if [ -f "/var/www/html/composer.json" ]; then
  echo "Installing Composer dependencies..."
  mkdir -p /tmp/composer && chown "${U}:${G}" /tmp/composer
  COMPOSER_HOME=/tmp/composer setpriv --reuid www-data --regid www-data --init-groups \
    composer install --no-dev --classmap-authoritative --no-interaction
fi

echo "Starting Apache..."
exec apache2-foreground
