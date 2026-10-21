#!/bin/sh
# Dua toan bo file ve dung user SSH hien tai (PUID/PGID).
#
# Dung khi:
#   - Nang cap tu ban cu dung chmod 777 / owner www-data (uid 33)
#   - Doi user trien khai / doi PUID-PGID trong .env
#   - Sau khi giai nen archive tu may khac
#
# Usage:  sh scripts/fix-perms.sh
set -e
cd "$(dirname "$0")/.."

U="$(id -u)"
G="$(id -g)"
echo "Chuan hoa quyen ve ${U}:${G} ($(id -un))"

for d in moodle moodledata logs backup; do
  [ -d "$d" ] || continue
  echo "  - $d"
  sudo chown -R "${U}:${G}" "$d"
done

# Tep cau hinh: neu duoc tao bang sudo thi owner la root, khi do moi lenh doc
# .env (docker compose, script backup) deu bao "Permission denied".
for f in .env docker-compose.yml Caddyfile; do
  [ -f "$f" ] || continue
  echo "  - $f"
  sudo chown "${U}:${G}" "$f"
done
[ -f .env ] && sudo chmod 600 .env

# Thu hoi quyen ghi cua group/other o cac file/thu muc con 777 (ban cu):
# thu muc -> 755, file -> 644. Thu muc 700 (vd moodledata/sessions) giu nguyen.
for d in moodle moodledata; do
  [ -d "$d" ] || continue
  find "$d" -perm -o+w -type d -exec chmod 755 {} +
  find "$d" -perm -o+w -type f -exec chmod u+rwX,go+r-w {} +
done

echo "Xong. Kiem tra:  ls -ln moodledata | head"
