#!/bin/sh
# Xuất toàn bộ image của stack ra một tệp nén để nạp lại khi chạy offline.
#
# Usage: sh scripts/images-save.sh [output.tar.gz]
# Default output: backup/images/moodle-images.tar.gz
set -eu

cd "$(dirname "$0")/.."

OUT="${1:-backup/images/moodle-images.tar.gz}"
OUT_DIR="$(dirname "$OUT")"
mkdir -p "$OUT_DIR"

command -v docker >/dev/null 2>&1 || {
    echo "Cần docker trong PATH." >&2
    exit 1
}

# Lấy danh sách image từ compose để không bị lệch khi cấu hình dịch vụ đổi.
IMAGES="$(docker compose config --images)"
[ -n "$IMAGES" ] || {
    echo "Không đọc được danh sách image từ docker compose." >&2
    exit 1
}

echo "Image sẽ xuất:"
for img in $IMAGES; do
    echo "  - $img"
done

missing=0
for img in $IMAGES; do
    if ! docker image inspect "$img" >/dev/null 2>&1; then
        echo "Thiếu image: $img" >&2
        missing=1
    fi
done
if [ "$missing" -ne 0 ]; then
    echo "Chạy 'docker compose pull' và 'docker compose build' trước khi xuất." >&2
    exit 1
fi

# Nếu đích là .gz, ghi tar tạm rồi nén, để bắt được lỗi của docker save.
TAR_OUT="$OUT"
COMPRESS=0
case "$OUT" in
    *.gz)
        COMPRESS=1
        TAR_OUT="${OUT%.gz}.tmp.tar"
        command -v gzip >/dev/null 2>&1 || {
            echo "Cần gzip cho đích .gz." >&2
            exit 1
        }
        ;;
esac

echo "Đang xuất ra $OUT ..."
if ! docker save $IMAGES -o "$TAR_OUT"; then
    rm -f "$TAR_OUT"
    echo "docker save thất bại." >&2
    exit 1
fi

if [ "$COMPRESS" -eq 1 ]; then
    if ! gzip -6 -c "$TAR_OUT" > "$OUT"; then
        rm -f "$OUT" "$TAR_OUT"
        echo "Nén thất bại." >&2
        exit 1
    fi
    rm -f "$TAR_OUT"
fi

echo "Xong: $(du -h "$OUT" | cut -f1) $OUT"
if [ "$COMPRESS" -eq 1 ]; then
    echo "Kiểm tra tệp: gzip -t \"$OUT\""
fi
