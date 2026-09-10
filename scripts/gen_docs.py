#!/usr/bin/env python3
"""Sinh 3 file docs tiếng Việt đầy đủ (UTF-8) cho hệ thống LMS.

Usage:  python scripts/gen_docs.py
Ghi đè: docs/deploy.md, docs/migrate.md, docs/upgrade.md
Tên file giữ ASCII để tránh lỗi font trên PowerShell/WSL.
"""

from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"

DEPLOY = """\
# Triển khai LMS (Moodle 5.x + Docker)

Stack: Caddy (80/443/udp, SSL tự động) + Apache PHP 8.4 (production) +
MySQL 9 LTS + Redis + Ofelia (cron 1 phút, backup DB hằng ngày).

## 1. Cấu trúc

```text
├── docker-compose.yml  # setup, caddy, db, redis, moodle, cron (+phpmyadmin)
├── Caddyfile           # :80 (dev) | domain (prod, tự cấp SSL)
├── .env                # MYSQL_*, REDIS_*, TZ, APP_ENV
├── php/                # Dockerfile + entrypoint.sh (777 tự động)
├── moodle/             # source (không commit vì nặng)
├── moodledata/         # dataroot (không commit)
├── backup/             # sql dump (không commit)
├── logs/caddy, logs/moodle, logs/php, logs/mysql, logs/redis
├── scripts/db-backup.sh, scripts/db-restore.sh, scripts/log-rotate.sh
└── docs/
```

## 2. Chạy nhanh

```powershell
Copy-Item .env.example .env   # sửa password trước
docker compose up -d --build
```

Service `setup` tự tạo thư mục còn thiếu + chmod 777 `logs/`,
`backup/`, `moodledata/` trước khi db/redis/moodle start —
không cần set quyền tay.

Mở `http://localhost`, thông số cài đặt web:

| Thông số | Giá trị |
|---|---|
| DB host | `db` |
| DB name / user / pass | theo `.env` |
| Data dir | `/var/www/moodledata` |

MySQL image tự tạo `MYSQL_USER` lúc init volume lần đầu.
`moodle/config.php` dùng `dbtype = 'mysqli'`.

## 3. Bật Redis

Admin → Site administration → Plugins → Caching → Configuration
→ Add instance (Redis): Server `redis`, password theo `.env`
→ Map `Application` + `Session` sang instance vừa tạo.

## 4. Lên domain (production)

1. `Caddyfile`: đổi `:80` thành domain (ví dụ `lms.example.vn`)
2. `docker compose up -d` (port 443/udp mở sẵn, cert lưu ở `caddy_data`)
3. Đổi `wwwroot` + replace URL cũ:
```bash
docker exec -it moodle_web php /var/www/html/public/admin/tool/replace/cli/replace.php --search=http://localhost --replace=https://lms.example.vn --shorten --non-interactive
docker exec moodle_web php /var/www/html/admin/cli/purge_caches.php
```
4. Trong `config.php` bật `$CFG->sslproxy = true` nếu sau proxy.

## 5. Backup / Restore

Tự động: Ofelia dump `moodle_latest.sql` mỗi ngày.
Thủ công:
```bash
bash scripts/db-backup.sh
bash scripts/db-restore.sh [file.sql]
```

## 6. Logs (mỗi ngày, giữ 30 ngày, giờ UTC)

| Service | File | Ghi chú |
|---|---|---|
| Caddy | `logs/caddy/access-YYYY-MM-DD.log` | JSON, dễ parse/thống kê |
| Apache | `logs/moodle/access-*.log`, `error-*.log` | rotatelogs tự cắt theo ngày |
| PHP | `logs/php/error-*.log` | `display_errors=Off`, chỉ ghi file |
| MySQL | `logs/mysql/error/slow/general-*.log` | general log tốn disk, xóa 2 dòng general trong compose nếu không cần |
| Redis | `logs/redis/redis-*.log` | loglevel notice |

Ofelia chạy `scripts/log-rotate.sh` lúc 0h VN (17h UTC):
copy file đang ghi sang file ngày + xóa file quá 30 ngày.
Caddy có thêm roll nội bộ (100MB/30 file) chống tràn disk.

## 7. Ghi chú

- Quyền 777 cho `moodle/` + `moodledata/` do `entrypoint.sh` tự set
  mỗi lần container start — không `chown` tay. Thêm default ACL
  (hiệu lực trên ext4/xfs) để file tạo mới ghi được 2 chiều
  host ↔ container mà không cần restart.
- PHP prod: `display_errors=Off`, log về `logs/php/error.log`,
  `opcache.validate_timestamps=0` (đổi code phải restart container).
- phpMyAdmin chỉ để debug: uncomment trong compose rồi `up -d`.
"""

MIGRATE = """\
# Di trú LMS sang máy khác

## 1. Máy cũ

```bash
bash scripts/db-backup.sh   # ra backup/moodle_*.sql + moodle_latest.sql
tar -czf /mnt/c/Users/<user>/Desktop/moodle_move.tar.gz \\
  --exclude=./logs \\
  --exclude=./backup/moodle_20*.sql \\
  --exclude=./moodledata/sessions \\
  --exclude=./moodledata/cache \\
  --exclude=./moodledata/localcache \\
  --exclude=./moodledata/temp \\
  --exclude=./moodledata/muc \\
  .
```

Nén 1 file cho nhanh (source Moodle hàng chục nghìn file nhỏ).
Bỏ `logs` (tự tạo lại) + cache/session/temp (Moodle tự tạo lại,
tránh lỗi permission file session 600). `charset utf8mb4` đã nằm
sẵn trong script. Không cần `sudo` (quyền đã mở sẵn).

## 2. Máy mới

```bash
mkdir -p ~/projects/moodle-server && cd ~/projects/moodle-server
sudo tar -xzf /mnt/c/Users/<user>/Desktop/moodle_move.tar.gz -C .
docker compose up -d --build
sleep 15
bash scripts/db-restore.sh            # mặc định moodle_latest.sql
```

## 3. Đổi URL nếu khác (ví dụ localhost → domain)

```bash
docker exec -it moodle_web php /var/www/html/public/admin/tool/replace/cli/replace.php --search=http://localhost --replace=https://lms.example.vn --shorten --non-interactive
docker exec moodle_web php /var/www/html/admin/cli/purge_caches.php
```

Quyền 777 + `composer install` do `entrypoint.sh` tự lo.
Caddy tự chạy, không cần cấu hình SSL tay.
"""

UPGRADE = """\
# Nâng cấp Moodle 5.x

Làm giờ thấp điểm. Backup bắt buộc.

## 1. Backup

```bash
bash scripts/db-backup.sh
sudo tar -czf ~/Desktop/moodle_before_upgrade.tar.gz .
```

## 2. Thay source mới

```bash
docker compose down
mv moodle moodle-old
mkdir moodle
sudo tar -xzf /mnt/c/Users/<user>/Desktop/moodle-5.x.tgz -C moodle --strip-components=1
cp moodle-old/config.php moodle/config.php   # kiểm tra dbtype='mysqli'
# cp lại plugin/theme tùy chỉnh nếu có
```

## 3. Upgrade database

```bash
docker compose up -d --build
sleep 15
docker exec -it moodle_web php /var/www/html/admin/cli/upgrade.php
docker exec -it moodle_web php /var/www/html/admin/cli/purge_caches.php
docker exec -it moodle_web php /var/www/html/admin/cli/maintenance.php --disable
```

Thành công khi báo `Upgrade completed successfully!`.

## 4. Kiểm tra

Dashboard/khóa học, theme, Redis (Plugins → Caching),
upload file lớn, ngôn ngữ VI/KM.

## 5. Rollback

```bash
docker compose down
rm -rf moodle && mv moodle-old moodle
docker compose up -d --build
bash scripts/db-restore.sh backup/moodle_<stamp>.sql
```

Ổn định 1–2 ngày thì xóa `moodle-old` + backup tạm.
"""


def main() -> None:
    DOCS.mkdir(parents=True, exist_ok=True)
    files = {
        "deploy.md": DEPLOY,
        "migrate.md": MIGRATE,
        "upgrade.md": UPGRADE,
    }
    for name, content in files.items():
        path = DOCS / name
        path.write_text(content, encoding="utf-8")
        print(f"wrote {path} ({len(content)} chars)")


if __name__ == "__main__":
    main()
