# Moodle LMS — Docker Skeleton (Production)

Khung triển khai Moodle 5.x bằng Docker Compose: Caddy (SSL tự động) +
Apache PHP 8.4 (production) + MySQL 9 LTS + Redis + Ofelia (cron + backup).

Repo này chỉ chứa **khung cấu hình**. Source Moodle, `moodledata`,
backup SQL, log, file `.env` và docs nội bộ không commit
(xem `.gitignore`).

## Stack

| Service | Image | Vai trò |
|---|---|---|
| `setup` | `alpine` | Chạy 1 lần: tạo thư mục + chmod 777 bind mounts |
| `caddy` | `caddy:alpine` | Reverse proxy 80/443/udp, SSL Let's Encrypt tự động |
| `db` | `mysql:9` | MySQL 9 LTS, utf8mb4, log error/slow/general |
| `redis` | `redis` | Cache + session, 256MB LRU |
| `moodle` | build `./php` | Apache + PHP 8.4, DocumentRoot `/public` |
| `cron` | `ofelia` | Cron Moodle 1 phút + backup DB daily + xoay log 0h VN |

## Cấu trúc

```text
├── docker-compose.yml
├── Caddyfile
├── .env.example            # copy thành .env rồi sửa password
├── php/Dockerfile + entrypoint.sh
├── scripts/db-backup.sh    # backup thủ công
├── scripts/db-restore.sh   # restore thủ công
├── scripts/log-rotate.sh   # Ofelia gọi mỗi đêm
├── moodle/                 # source Moodle (tự tải, không commit)
├── moodledata/             # dataroot (không commit)
├── backup/                 # sql dump (không commit)
└── logs/caddy,moodle,php,mysql,redis
```

## Chạy nhanh

```bash
cp .env.example .env   # sửa password trước
# Giải nén source Moodle 5.x vào ./moodle (giữ lại config.php nếu có)
docker compose up -d --build
```

Mở `http://localhost`, cài đặt web với: DB host `db`,
DB name/user/pass theo `.env`, data dir `/var/www/moodledata`.
`config.php` dùng `dbtype = 'mysqli'`. MySQL tự tạo `MYSQL_USER`
lúc init volume lần đầu.

Bật Redis: Admin → Site administration → Plugins → Caching →
Add instance (Server `redis`, password theo `.env`) → map
`Application` + `Session`.

## Backup / Restore

```bash
bash scripts/db-backup.sh          # -> backup/moodle_*.sql + moodle_latest.sql
bash scripts/db-restore.sh [file]  # mặc định moodle_latest.sql
```

Ofelia tự dump `moodle_latest.sql` mỗi ngày.

## Logs

Mỗi service ghi log riêng dưới `logs/`, xoay mỗi đêm lúc 0h VN,
giữ 30 ngày (Caddy dạng JSON để parse). General log MySQL tốn
disk — xóa 2 dòng `general` trong `docker-compose.yml` nếu không
cần audit query.

## Lên domain

1. `Caddyfile`: đổi `:80` thành domain
2. `docker compose up -d` (port 443 mở sẵn, cert lưu ở volume)
3. Replace URL cũ sang domain + purge caches (xem Moodle docs
   `admin/tool/replace/cli`), bật `$CFG->sslproxy` nếu sau proxy.

## Quyền

`setup` + `entrypoint.sh` tự mở 777 `moodle/ moodledata/ logs/
backup/` nên user host và `www-data` đều ghi được 2 chiều,
không cần `chown` tay. Thêm default ACL (hiệu lực trên ext4/xfs)
cho file tạo mới lúc runtime.

## License

PolyForm Noncommercial 1.0.0 — xem `LICENSE-EE.md`.
Chỉ dùng cho mục đích phi thương mại.
