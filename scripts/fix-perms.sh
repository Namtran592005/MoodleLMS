#!/bin/sh
# Usage: sh scripts/fix-perms.sh
# Chuẩn hóa owner về user SSH hiện tại; .env phải thuộc user này để đọc được
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

for f in .env docker-compose.yml Caddyfile; do
  [ -f "$f" ] || continue
  echo "  - $f"
  sudo chown "${U}:${G}" "$f"
done
[ -f .env ] && sudo chmod 600 .env

# thu muc 755, file 644; giu nguyen thu muc 700 (vd moodledata/sessions)
for d in moodle moodledata; do
  [ -d "$d" ] || continue
  find "$d" -perm -o+w -type d -exec chmod 755 {} +
  find "$d" -perm -o+w -type f -exec chmod u+rwX,go+r-w {} +
done

echo "Xong. Kiem tra:  ls -ln moodledata | head"
