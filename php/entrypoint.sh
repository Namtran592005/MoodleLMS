#!/bin/bash
set -e

# ---------------------------------------------------------------------------
# Tu dong xac dinh UID/GID cua tai khoan Linux mac dinh (tai khoan SSH):
# lay owner cua ./moodle hoac ./moodledata — chinh la user da giai nen source
# / tao thu muc. Bo qua root va UID he thong (< 1000) cua ban cu dung 777.
# Dat PUID/PGID trong .env chi khi muon ep buoc gia tri khac.
# ---------------------------------------------------------------------------
detect_ids() {
  if [ -n "${PUID:-}" ] && [ -n "${PGID:-}" ]; then
    echo "${PUID} ${PGID}"
    return
  fi
  for d in /var/www/html /var/www/moodledata /backup; do
    [ -d "$d" ] || continue
    u="$(stat -c %u "$d")"
    g="$(stat -c %g "$d")"
    # Bo qua root (0) va UID he thong (< 1000, vd www-data 33 cua ban cu
    # dung 777): chi lay UID cua tai khoan nguoi dung that.
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

# Log + backup: thuoc user host -> doc/xoa/xoay thoai mai.
# KHONG doi owner /logs/mysql, /logs/redis (db/redis can ghi bang user rieng),
# chi them group cua user host de ban van doc/xoa duoc.
chown -R "${U}:${G}" /logs/caddy /var/log/moodle /var/log/php 2>/dev/null || true
chown "${U}:${G}" /logs /backup 2>/dev/null || true
chown -R "${U}:${G}" /backup 2>/dev/null || true
# Ban cu: backup co the con 777 -> ha ve 755/644
find /backup -perm -o+w -type d -exec chmod 755 {} + 2>/dev/null || true
find /backup -perm -o+w -type f -exec chmod 644 {} + 2>/dev/null || true
for d in /logs/mysql /logs/redis; do
  if [ -d "$d" ]; then
    chgrp -R "${G}" "$d" 2>/dev/null || true
    chmod -R g+rwX "$d" 2>/dev/null || true
  fi
done
chmod -R a+rX /logs /var/log/moodle /var/log/php 2>/dev/null || true

# Chi chown lai khi phat hien file lech owner (lan dau / sau khi di tru
# tu ban cu dung 777). Cac lan sau chi ton 1 lan quet, khong ghi gi.
ensure_owner() {
  dir="$1"
  [ -d "$dir" ] || return 0
  if [ -n "$(find "$dir" \( ! -user "$U" -o ! -group "$G" -o -perm -o+w \) -print -quit 2>/dev/null)" ]; then
    echo "Fixing ownership in $dir ..."
    chown -R "${U}:${G}" "$dir" || true
    # Ban cu dung 777 -> thu hoi quyen ghi cua group/other: thu muc 755, file
    # 644. Chi dong vao file/thu muc dang 777, khong dung toi thu muc 700
    # (vd moodledata/sessions) cua Moodle.
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
