#!/bin/sh
# Nạp image từ tệp đã xuất để chạy offline, không build và không pull.
#
# Usage: sh scripts/images-load.sh [input.tar.gz]
# Default input: backup/images/moodle-images.tar.gz
set -eu

cd "$(dirname "$0")/.."

IN="${1:-backup/images/moodle-images.tar.gz}"
[ -f "$IN" ] || {
    echo "Không tìm thấy $IN" >&2
    exit 1
}

command -v docker >/dev/null 2>&1 || {
    echo "Cần docker trong PATH." >&2
    exit 1
}

echo "Đang kiểm tra tệp $IN ..."
case "$IN" in
    *.gz) gzip -t "$IN" ;;
    *.bz2) bzip2 -t "$IN" ;;
    *.xz) xz -t "$IN" ;;
esac

echo "Đang nạp image từ $IN ..."
case "$IN" in
    *.gz) gzip -dc "$IN" | docker load ;;
    *.bz2) bzip2 -dc "$IN" | docker load ;;
    *.xz) xz -dc "$IN" | docker load ;;
    *) docker load -i "$IN" ;;
esac

echo "Kiểm tra image theo docker compose:"
IMAGES="$(docker compose config --images)"
missing=0
for img in $IMAGES; do
    if docker image inspect "$img" >/dev/null 2>&1; then
        echo "  - có: $img"
    else
        echo "  - thiếu: $img" >&2
        missing=1
    fi
done
if [ "$missing" -ne 0 ]; then
    echo "Thiếu image. Kiểm tra COMPOSE_PROJECT_NAME trong .env." >&2
    echo "Image moodle hiện có:" >&2
    docker images --format '  - {{.Repository}}:{{.Tag}}' | grep -i moodle >&2 || true
    exit 1
fi

echo "Khởi động lại stack bằng image local (không build):"
docker compose up -d --no-build

echo "Xong. Kiểm tra: docker compose ps"
