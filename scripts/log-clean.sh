#!/bin/bash
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR" || exit 1

LOG_DIR="logs"

DRY=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    -*) echo "Tuy chon khong hop le: $arg" >&2; exit 1 ;;
    *) echo "Tham so khong hop le: $arg" >&2; exit 1 ;;
  esac
done

[ -d "$LOG_DIR" ] || { echo "Khong co thu muc $LOG_DIR/"; exit 0; }

# Dung ngay cua container de khop ten tep log dang mo, phong khi TZ khac host.
TODAY=$(date +%F)
if [ "$(docker inspect -f '{{.State.Running}}' moodle_web 2>/dev/null)" = "true" ]; then
  TODAY=$(docker exec moodle_web date +%F 2>/dev/null || date +%F)
fi

mapfile -d '' FILES < <(find "$LOG_DIR" -mindepth 2 -type f -print0 | sort -z)

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "Khong co tep log nao trong $LOG_DIR/."
  exit 0
fi

# Tep dang mo phai truncate, khong duoc xoa: xoa se lam mat dung luong cho toi khi
# tien trinh dong file. Tep da xoay vong thi xoa han cho sach thu muc.
is_active() {
  local f="$1" name stem age
  name=$(basename "$f")
  stem="${name%.gz}"

  case "$name" in
    *.gz) return 1 ;;
  esac

  # Khong co ngay YYYY-MM-DD: day la log goc dang duoc ghi.
  if ! [[ "$stem" =~ [0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
    return 0
  fi

  # Ten co ngay hom nay: file cua hom nay dang duoc ghi.
  case "$stem" in
    *"$TODAY"*) return 0 ;;
  esac

  # Vua duoc ghi trong 24 gio: coi nhu con mo, truncate cho an toan.
  age=$(( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || echo 0) ))
  [ "$age" -lt 86400 ]
}

TRUNC=0
DELETE=0
BYTES=0
ERRORS=0
LIST=()

for f in "${FILES[@]}"; do
  size=$(stat -c %s "$f" 2>/dev/null || echo 0)
  BYTES=$((BYTES + size))
  if is_active "$f"; then
    TRUNC=$((TRUNC + 1))
    LIST+=("truncate  $f")
  else
    DELETE=$((DELETE + 1))
    LIST+=("xoa       $f")
  fi
done

echo "Thu muc: $LOG_DIR/  (ngay container: $TODAY)"
echo "Se truncate $TRUNC tep dang ghi, xoa $DELETE tep da xoay vong."
echo "Dung luong hien tai: $(du -sh "$LOG_DIR" 2>/dev/null | cut -f1), tong ${BYTES} byte."

if [ "$DRY" -eq 1 ]; then
  echo
  printf '  %s\n' "${LIST[@]}"
  echo
  echo "Dry-run: khong thay doi gi."
  exit 0
fi

read -p "Go 'XOA' de xac nhan: " ANSWER
[ "$ANSWER" = "XOA" ] || { echo "Da huy."; exit 0; }

for f in "${FILES[@]}"; do
  if is_active "$f"; then
    if ! truncate -s 0 "$f" 2>/dev/null; then
      echo "Khong truncate duoc: $f" >&2
      ERRORS=$((ERRORS + 1))
    fi
  else
    if ! rm -f "$f" 2>/dev/null; then
      echo "Khong xoa duoc: $f" >&2
      ERRORS=$((ERRORS + 1))
    fi
  fi
done

echo
echo "Da don xong. Dung luong con lai: $(du -sh "$LOG_DIR" 2>/dev/null | cut -f1)."
[ "$ERRORS" -eq 0 ] || echo "Co $ERRORS tep khong xu ly duoc (kiem tra quyen)." >&2
echo "Thu muc con giu nguyen:"
find "$LOG_DIR" -mindepth 1 -maxdepth 1 -type d | sort
