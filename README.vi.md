# Moodle LMS — Docker Skeleton

[Tiếng Anh](README.md) | **Tiếng Việt**

Bộ khung triển khai Moodle 5.x bằng Docker Compose: reverse proxy, TLS tự động,
PHP production, MySQL, Redis, cron và backup. Mục tiêu: dựng LMS trên máy chủ
Linux bằng một lệnh khởi động.

Repo chỉ chứa bộ khung cấu hình và hai tệp Moodle. Mã nguồn Moodle,
`moodledata/`, `backup/`, `logs/`, `.env` và tài liệu nội bộ không nằm trong repo
(xem `.gitignore`). Hai ngoại lệ là `moodle/public/.htaccess` (cấu hình Apache
quan trọng) và `moodle/config.php` (không chứa bí mật: mật khẩu DB đọc từ
`MOODLE_DB_PASSWORD`).

Hiệu năng, tinh chỉnh và xử lý sự cố xem [NOTES.vi.md](NOTES.vi.md). Giới hạn
đã biết và đề xuất sửa xem [LIMITATIONS.vi.md](LIMITATIONS.vi.md). Hướng dẫn
chi tiết (tiếng Việt, lệnh copy-paste) nằm trong `docs/`.

## Thành phần

| Dịch vụ | Image | Vai trò | Cổng |
|---|---|---|---|
| `caddy` | build `./caddy` (`moodle-caddy:2.11`) | Reverse proxy (Caddy 2.11 + rate limit), TLS tự động, header bảo mật | 80, 443, 443/udp |
| `db` | `mysql:9.7` | MySQL 9.7 LTS, `utf8mb4` | nội bộ 3306 |
| `redis` | `redis:8.12` | Cache và session, giới hạn 256 MB | nội bộ 6379 |
| `moodle` | build `./php` (`moodle-web:5.3`) | Apache 2.4 event MPM + PHP-FPM 8.5, webroot `/var/www/html/public` | nội bộ 80 |
| `socket-proxy` | build `./cetusguard` (`moodle-cetusguard:v1`) | Lọc Docker API, chỉ cho exec trong container Moodle | nội bộ 2375 |
| `cron` | `mcuadros/ofelia:0.3` | Cron Moodle, backup restic (DB và tệp), xoay log | không mở |

Chỉ `caddy` mở cổng ra ngoài. `db`, `redis`, `moodle` chỉ truy cập được trong
`moodle_net`; `cron` và `socket-proxy` dùng mạng nội bộ `socket_net` riêng.

## Khởi động nhanh

```bash
cp .env.example .env
# sửa .env: mật khẩu, MOODLE_WWWROOT, PUID/PGID (khớp `id -u` trên host)
chmod 600 .env
docker compose build
docker compose up -d
```

Đợi tất cả dịch vụ `healthy` (`docker compose ps`), sau đó mở URL site. Hướng dẫn
từng bước, lệnh kiểm tra và xử lý sự cố xem
[docs/HƯỚNG DẪN TRIỂN KHAI HỆ THỐNG LMS.md](docs/HƯỚNG%20DẪN%20TRIỂN%20KHAI%20HỆ%20THỐNG%20LMS.md).

## Lệnh thường dùng

```bash
docker compose ps                          # trạng thái
docker compose logs -f moodle              # log
docker compose restart moodle              # khởi động lại một dịch vụ
bash scripts/restic-backup.sh             # backup ngay
bash scripts/fix-perms.sh --check          # kiểm tra quyền
```

Tham chiếu đầy đủ: [NOTES.vi.md](NOTES.vi.md).

## Tài liệu

- [NOTES.vi.md](NOTES.vi.md) — hiệu năng, tinh chỉnh, xử lý sự cố, backup/restore.
- [LIMITATIONS.vi.md](LIMITATIONS.vi.md) — giới hạn đã biết và đề xuất sửa.
- `docs/` — hướng dẫn tiếng Việt (triển khai, cấu trúc, nâng cấp, di trú, đổi domain, vá bảo mật nhanh, nâng cấp bằng Git).

## Giấy phép

PolyForm Noncommercial 1.0.0. Xem `LICENSE-EE.md`. Chỉ dùng phi thương mại.