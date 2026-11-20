#!/bin/sh
set -e
cd "$(dirname "$0")/.."

CHECK=0
OWNER_USER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1; shift ;;
    --user) OWNER_USER="${2:?--user can ten tai khoan}"; shift 2 ;;
    -h|--help)
      echo "Dung: sh scripts/fix-perms.sh [--check] [--user <tai khoan>]"
      echo "  --check  chi liet ke muc tai khoan host khong doc duoc"
      echo "  --user   chi dung khi chay bang root, mac dinh lay SUDO_USER"
      exit 0 ;;
    *) echo "Tham so khong hop le: $1" >&2; exit 2 ;;
  esac
done

if [ "$(id -u)" -eq 0 ]; then
  OWNER_USER="${OWNER_USER:-${SUDO_USER:-}}"
  if [ -z "$OWNER_USER" ]; then
    echo "Dang chay bang root: them --user <tai khoan> hoac chay bang sudo tu tai khoan do." >&2
    exit 2
  fi
  if ! command -v setpriv >/dev/null 2>&1; then
    echo "Thieu setpriv (goi util-linux) de kiem tra quyen." >&2
    exit 2
  fi
  SUDO=""
else
  if [ -n "$OWNER_USER" ] && [ "$OWNER_USER" != "$(id -un)" ]; then
    echo "--user chi dung khi chay bang root." >&2
    exit 2
  fi
  OWNER_USER="$(id -un)"
  SUDO="sudo"
fi

U="$(id -u "$OWNER_USER")"
G="$(id -g "$OWNER_USER")"

# Chay lenh kiem tra bang dung tai khoan host, ke ca khi script dang la root.
run_as_owner() {
  if [ "$(id -u)" -eq 0 ]; then
    setpriv --reuid "$U" --regid "$G" --clear-groups "$@"
  else
    "$@"
  fi
}

# Liet ke muc tai khoan host khong doc duoc, tra ve so luong qua COUNT.
check_unreadable() {
  LIST="$(mktemp)"
  run_as_owner find moodle moodledata backup logs -xdev ! -readable -print \
    > "$LIST" 2>/dev/null || true
  COUNT="$(wc -l < "$LIST" | tr -d ' ')"
  if [ "$COUNT" -gt 0 ]; then
    echo "Khong doc duoc ${COUNT} muc (hien thi toi da 20):"
    head -20 "$LIST" | sed 's/^/  /'
  else
    echo "Moi muc deu doc duoc boi ${OWNER_USER}."
  fi
  rm -f "$LIST"
}

if [ "$CHECK" -eq 1 ]; then
  check_unreadable
  [ "$COUNT" -eq 0 ]
  exit
fi

echo "Chuan hoa quyen ve ${U}:${G} (${OWNER_USER})"

# 1. Source, du lieu Moodle va backup thuoc tai khoan host. Gom ca backup/restic:
#    restic chay bang root trong container nen tep repo do root tao, chown lai
#    de tar/copy khong can sudo (root van ghi duoc sau do).
for d in moodle moodledata backup; do
  [ -d "$d" ] || continue
  echo "  - $d"
  $SUDO chown -R "${U}:${G}" "$d"
done

# 2. Log: MySQL va Redis tu chown thu muc cua chung luc khoi dong, nen chi mo
#    quyen doc cho nhom host thay vi doi chu so huu.
for d in logs/caddy logs/php logs/moodle; do
  [ -d "$d" ] || continue
  echo "  - $d"
  $SUDO chown -R "${U}:${G}" "$d"
done
if [ -d logs ]; then
  $SUDO chown "${U}:${G}" logs
fi
for d in logs/mysql logs/redis; do
  [ -d "$d" ] || continue
  echo "  - $d (giu chu so huu cua container, mo quyen doc cho nhom ${G})"
  $SUDO chgrp -R "$G" "$d" 2>/dev/null || true
  $SUDO chmod -R g+rX "$d" 2>/dev/null || true
done

for f in .env docker-compose.yml Caddyfile; do
  [ -f "$f" ] || continue
  echo "  - $f"
  $SUDO chown "${U}:${G}" "$f"
done
[ -f .env ] && $SUDO chmod 600 .env

# 3. Bo quyen ghi cho nguoi khac. moodledata va backup khong mo cho other doc,
#    vi chung chua tep nguoi dung va ban dump co mat khau bam.
find moodle -perm -o+w -type d -exec $SUDO chmod 755 {} +
find moodle -perm -o+w -type f -exec $SUDO chmod u+rwX,go+r-w {} +
find moodledata -perm -o+w -type d -exec $SUDO chmod 750 {} +
find moodledata -perm -o+w -type f -exec $SUDO chmod u+rwX,go-w,o-rwx {} +
find backup -perm -o+w -type d -exec $SUDO chmod 700 {} +
find backup -perm -o+w -type f -exec $SUDO chmod u+rwX,go-rwx {} +

echo
check_unreadable
[ "$COUNT" -eq 0 ]
