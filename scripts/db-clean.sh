#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

DRY=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    *) echo "Tuy chon khong hop le: $arg" >&2; exit 1 ;;
  esac
done

[ -d backup ] || { echo "Khong co thu muc backup/"; exit 0; }

mapfile -t FILES < <(find backup -maxdepth 1 -type f -name 'moodle_*.sql' | sort)
[ "${#FILES[@]}" -gt 0 ] || { echo "Khong co ban dump nao trong backup/"; exit 0; }

echo "Se xoa ${#FILES[@]} tep:"
printf '  %s\n' "${FILES[@]}"
echo "Tong dung luong: $(du -ch "${FILES[@]}" | tail -1 | cut -f1)"

if [ "$DRY" -eq 1 ]; then
  echo "Dry-run: khong xoa gi."
  exit 0
fi

read -p "Go 'XOA' de xac nhan: " ANSWER
[ "$ANSWER" = "XOA" ] || { echo "Da huy."; exit 0; }

rm -f "${FILES[@]}"
echo "Da xoa ${#FILES[@]} tep."
find backup -maxdepth 1 -type f -name 'moodle_*.sql' | sort || true
