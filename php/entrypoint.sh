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

# Tinh MPM theo CPU/RAM de dung cho ca 4 GB/2 vCPU va 8 GB/4 vCPU.
# Co the ghi de bang APACHE_MAX_REQUEST_WORKERS hoac APACHE_START_SERVERS.
configure_apache_mpm() {
  conf=/etc/apache2/mods-enabled/mpm_prefork.conf
  [ -f "$conf" ] || return 0

  cpus="$(nproc 2>/dev/null || echo 2)"
  [ "$cpus" -ge 1 ] 2>/dev/null || cpus=2

  # Docker co the gioi han CPU bang cgroup; nproc chi thay affinity.
  if [ -r /sys/fs/cgroup/cpu.max ]; then
    read -r quota period < /sys/fs/cgroup/cpu.max || true
    if [ -n "${quota:-}" ] && [ "$quota" != "max" ] && [ "${period:-0}" -gt 0 ] 2>/dev/null; then
      cpus=$(( (quota + period - 1) / period ))
    fi
  elif [ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]; then
    quota="$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us 2>/dev/null || echo -1)"
    period="$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us 2>/dev/null || echo 0)"
    if [ "$quota" -gt 0 ] 2>/dev/null && [ "$period" -gt 0 ] 2>/dev/null; then
      cpus=$(( (quota + period - 1) / period ))
    fi
  fi
  [ "$cpus" -ge 1 ] 2>/dev/null || cpus=2

  host_mb="$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || true)"
  [ -n "$host_mb" ] && [ "$host_mb" -ge 512 ] 2>/dev/null || host_mb=4096

  # memory.max = gioi han container; "max" = dung RAM cua host.
  limit_mb="$host_mb"
  if [ -r /sys/fs/cgroup/memory.max ]; then
    limit="$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo max)"
    if [ "$limit" != "max" ] && [ "$limit" -gt 0 ] 2>/dev/null; then
      limit_mb=$(( limit / 1024 / 1024 ))
    fi
  elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
    limit="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || echo 0)"
    if [ "$limit" -gt 0 ] 2>/dev/null; then
      limit_mb=$(( limit / 1024 / 1024 ))
    fi
  fi
  if [ "$limit_mb" -le 0 ] || [ "$limit_mb" -gt $((host_mb * 4)) ]; then
    limit_mb="$host_mb"
  fi

  # Khong co mem_limit: giu lai RAM cho MySQL, Redis, Caddy, Ofelia va OS.
  if [ -n "${MOODLE_MEM_RESERVE_MB:-}" ]; then
    reserve_mb="$MOODLE_MEM_RESERVE_MB"
  elif [ "$limit_mb" -lt $((host_mb * 9 / 10)) ]; then
    reserve_mb=256
  else
    reserve_mb=$((host_mb / 4))
    [ "$reserve_mb" -lt 1536 ] && reserve_mb=1536
    [ "$reserve_mb" -gt 2048 ] && reserve_mb=2048
  fi
  [ "$reserve_mb" -ge 0 ] 2>/dev/null || reserve_mb=1536
  [ "$reserve_mb" -lt "$limit_mb" ] || reserve_mb=$((limit_mb / 4))

  worker_mb="${MOODLE_WORKER_MEM_MB:-64}"
  [ "$worker_mb" -ge 16 ] 2>/dev/null || worker_mb=64

  by_cpu=$((cpus * 16))
  by_mem=$(( (limit_mb - reserve_mb) / worker_mb ))
  [ "$by_mem" -ge 1 ] 2>/dev/null || by_mem=1

  max_workers="$by_mem"
  [ "$by_cpu" -lt "$max_workers" ] && max_workers="$by_cpu"
  [ "$max_workers" -gt 150 ] && max_workers=150
  [ "$max_workers" -ge 2 ] 2>/dev/null || max_workers=2

  if [ -n "${APACHE_MAX_REQUEST_WORKERS:-}" ]; then
    case "$APACHE_MAX_REQUEST_WORKERS" in
      *[!0-9]*|'')
        echo "[mpm] APACHE_MAX_REQUEST_WORKERS khong hop le, dung gia tri tu dong" >&2
        ;;
      *)
        max_workers="$APACHE_MAX_REQUEST_WORKERS"
        ;;
    esac
  fi
  [ "$max_workers" -ge 1 ] 2>/dev/null || max_workers=1

  start_servers=$((cpus * 2))
  [ "$start_servers" -lt 2 ] && start_servers=2
  if [ -n "${APACHE_START_SERVERS:-}" ]; then
    case "$APACHE_START_SERVERS" in
      *[!0-9]*|'')
        echo "[mpm] APACHE_START_SERVERS khong hop le, dung gia tri tu dong" >&2
        ;;
      *)
        start_servers="$APACHE_START_SERVERS"
        ;;
    esac
  fi
  [ "$start_servers" -gt "$max_workers" ] && start_servers="$max_workers"
  [ "$start_servers" -ge 1 ] 2>/dev/null || start_servers=1

  min_spare="$cpus"
  [ "$min_spare" -lt 2 ] && min_spare=2
  [ "$min_spare" -gt "$start_servers" ] && min_spare="$start_servers"

  max_spare=$((cpus * 4))
  [ "$max_spare" -lt 4 ] && max_spare=4
  [ "$max_spare" -gt "$max_workers" ] && max_spare="$max_workers"
  [ "$max_spare" -lt "$min_spare" ] && max_spare="$min_spare"

  sed -i -E \
    -e "s/^([[:space:]]*StartServers[[:space:]]+)[0-9]+/\1${start_servers}/" \
    -e "s/^([[:space:]]*MinSpareServers[[:space:]]+)[0-9]+/\1${min_spare}/" \
    -e "s/^([[:space:]]*MaxSpareServers[[:space:]]+)[0-9]+/\1${max_spare}/" \
    -e "s/^([[:space:]]*MaxRequestWorkers[[:space:]]+)[0-9]+/\1${max_workers}/" \
    "$conf"

  # MaxRequestWorkers > 256 can ServerLimit mac dinh cua prefork.
  if [ "$max_workers" -gt 256 ]; then
    if grep -qE '^[[:space:]]*ServerLimit[[:space:]]+' "$conf"; then
      sed -i -E "s/^([[:space:]]*ServerLimit[[:space:]]+)[0-9]+/\1${max_workers}/" "$conf"
    else
      sed -i "/^[[:space:]]*MaxRequestWorkers[[:space:]]/i\\
ServerLimit            ${max_workers}
" "$conf"
    fi
  fi

  echo "[mpm] CPU=${cpus}, RAM=${limit_mb}MB, du phong=${reserve_mb}MB, ${worker_mb}MB/worker"
  echo "[mpm] MaxRequestWorkers=${max_workers}, StartServers=${start_servers}, MinSpareServers=${min_spare}, MaxSpareServers=${max_spare}"

  if ! apache2ctl -t >/tmp/apache-config-test.log 2>&1; then
    echo "[mpm] Cau hinh Apache khong hop le:" >&2
    cat /tmp/apache-config-test.log >&2
    exit 1
  fi
  rm -f /tmp/apache-config-test.log
}

configure_apache_mpm

echo "Starting Apache..."
exec apache2-foreground
