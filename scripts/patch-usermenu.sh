#!/bin/sh
# Vá lỗi usermenu trên trang guest của Moodle 5.3.
#
# Trên trang chưa đăng nhập, .usermenu không có .dropdown-menu. Khi resize,
# initTruncationTooltips() đọc classList của null và báo TypeError trong console.
# Script thêm null guard vào cả source và bản build AMD.
#
# Usage: sh scripts/patch-usermenu.sh [public_dir]
# Default public_dir: moodle/public
set -eu

cd "$(dirname "$0")/.."

PUBLIC_DIR="${1:-moodle/public}"
SRC="$PUBLIC_DIR/lib/amd/src/usermenu.js"
BUILD="$PUBLIC_DIR/lib/amd/build/usermenu.min.js"
BACKUP_DIR="backup/usermenu-patch"
STAMP="$(date +%Y%m%d-%H%M%S)"

[ -f "$SRC" ] || {
    echo "Không tìm thấy $SRC" >&2
    exit 1
}
[ -f "$BUILD" ] || {
    echo "Không tìm thấy $BUILD" >&2
    exit 1
}
command -v perl >/dev/null 2>&1 || {
    echo "Cần perl để vá tệp." >&2
    exit 1
}

mkdir -p "$BACKUP_DIR"

patch_one() {
    p_file="$1"
    p_old="$2"
    p_new="$3"
    p_label="$4"

    if grep -Fq "$p_new" "$p_file"; then
        echo "Đã có guard: $p_label"
        return 0
    fi
    if ! grep -Fq "$p_old" "$p_file"; then
        echo "Không tìm thấy mẫu cũ trong $p_file." >&2
        echo "Moodle có thể đã sửa lỗi hoặc đổi mã; không ghi đè." >&2
        return 1
    fi

    cp -a "$p_file" "$BACKUP_DIR/$(basename "$p_file").$STAMP"
    OLD="$p_old" NEW="$p_new" perl -0777 -i -pe 's/\Q$ENV{OLD}\E/$ENV{NEW}/' "$p_file"

    if ! grep -Fq "$p_new" "$p_file"; then
        echo "Vá thất bại: $p_file" >&2
        return 1
    fi
    echo "Đã vá: $p_label"
}

patch_one \
    "$SRC" \
    "if (!dropdownMenu.classList.contains('show')) {" \
    "if (!dropdownMenu || !dropdownMenu.classList.contains('show')) {" \
    "source"

patch_one \
    "$BUILD" \
    'if(!userMenu.querySelector(selectors_userMenuDropdown).classList.contains("show"))return;' \
    'const dropdownMenu=userMenu.querySelector(selectors_userMenuDropdown);if(!dropdownMenu||!dropdownMenu.classList.contains("show"))return;' \
    "build"

echo "Xong. Bản gốc được lưu trong $BACKUP_DIR (nếu có thay đổi)."
echo "Chạy tiếp: docker exec -u www-data moodle_web php /var/www/html/admin/cli/purge_caches.php"
