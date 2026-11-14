# Moodle LMS — Docker Skeleton

[English](README.md) | **Tiếng Việt**

Khung triển khai Moodle 5.x bằng Docker Compose: reverse proxy, TLS tự động, PHP
production, MySQL, Redis, cron và backup. Mục tiêu là dựng hệ thống LMS trên máy
chủ Linux bằng một lệnh khởi động.

Kho chỉ chứa khung cấu hình. Mã nguồn Moodle, `moodledata/`, `backup/`, `logs/`,
`.env` và tài liệu nội bộ không đưa vào kho (xem `.gitignore`). Riêng
`moodle/public/.htaccess` được giữ lại vì là tệp cấu hình Apache quan trọng.

Phần tính toán RAM, tinh chỉnh và cách xử lý lỗi nằm trong
[NOTES.vi.md](NOTES.vi.md). Tệp này chỉ tập trung vào việc dựng hệ thống chạy được.

## Thành phần hệ thống

| Dịch vụ | Image | Vai trò | Cổng |
|---|---|---|---|
| `caddy` | build `./caddy` | Reverse proxy (Caddy latest + rate-limit), TLS tự động, header bảo mật | 80, 443, 443/udp |
| `db` | `mysql:9` | MySQL 9.7 LTS, `utf8mb4` | nội bộ 3306 |
| `redis` | `redis:latest` | Cache và session, giới hạn 256 MB | nội bộ 6379 |
| `moodle` | build `./php` | Apache 2.4 event MPM + PHP-FPM 8.5, webroot `/var/www/html/public` | nội bộ 80 |
| `cron` | `mcuadros/ofelia` | Cron Moodle, backup hằng ngày, xoay log | không mở |

Chỉ `caddy` mở cổng ra ngoài; các dịch vụ còn lại chỉ truy cập được trong mạng
`moodle_net`.

## Kiến trúc

Caddy nhận HTTPS và chuyển tiếp tới Apache/PHP trong `moodle_web`. PHP đọc ghi
`moodledata`, truy vấn MySQL và Redis rồi trả kết quả về Caddy. Apache dùng
`mpm_event` với thread, PHP 8.5 chạy trong các tiến trình PHP-FPM tách riêng.

Dữ liệu được phân bố như sau:

| Đường dẫn | Nội dung | Hình thức lưu trữ |
|---|---|---|
| `moodle/` | Mã nguồn Moodle | Bind mount |
| `moodledata/` | Tệp người dùng, cache, session | Bind mount |
| `backup/` | Bản dump cơ sở dữ liệu và kho restic | Bind mount |
| `logs/` | Log của từng dịch vụ | Bind mount |
| `moodle_db_data` | Dữ liệu MySQL | Named volume |
| `redis_data` | Dữ liệu Redis (AOF), session và cache | Named volume |
| `caddy_data`, `caddy_config` | Chứng chỉ và cấu hình Caddy | Named volume |

Không có dịch vụ khởi tạo riêng: mỗi container tự tạo thư mục và đặt quyền trong
entrypoint, nên xóa image không làm mất bước khởi tạo. Tổng cộng năm image.

## Cài đặt

### 1. Cấu hình môi trường

```bash
cp .env.example .env
chmod 600 .env
```

Tệp phải thuộc tài khoản triển khai. Nếu được tạo bằng `sudo`, đổi lại owner
trước khi chạy Compose:

```bash
sudo chown "$USER":"$USER" .env
chmod 600 .env
```

| Biến | Ý nghĩa |
|---|---|
| `MYSQL_ROOT_PASSWORD` | Mật khẩu root MySQL, chỉ dùng nội bộ |
| `MOODLE_DB_NAME` | Tên cơ sở dữ liệu |
| `MOODLE_DB_USER` | Tài khoản MySQL dành cho Moodle |
| `MOODLE_DB_PASSWORD` | Mật khẩu của tài khoản trên |
| `REDIS_PASSWORD` | Mật khẩu Redis |
| `RESTIC_PASSWORD` | Mật khẩu mã hóa kho restic |
| `RESTIC_REPOSITORY` | Tùy chọn, mặc định `/backup/restic` |
| `TZ` | Múi giờ, mặc định `Asia/Ho_Chi_Minh` |
| `APP_ENV` | `production` |
| `PUID`, `PGID` | Không bắt buộc, dùng khi cần ép UID/GID |
| `APACHE_MAX_REQUEST_WORKERS`, `PHP_FPM_MAX_CHILDREN` | Số worker, mặc định tự tính |
| `COMPOSE_PROJECT_NAME` | Giữ tên volume và network ổn định |

Cách tính worker, hành vi bộ nhớ và giá trị theo tải có trong
[NOTES.vi.md](NOTES.vi.md#ram-và-worker).

### 2. Đặt mã nguồn Moodle

Giải nén Moodle 5.x vào `moodle/`, giữ lại `config.php` nếu đã có:

```bash
mkdir -p moodle
tar -xzf moodle-5.x.tgz -C moodle --strip-components=1
```

```php
$CFG->dbtype    = 'mysqli';
$CFG->dbhost    = 'db';
$CFG->dbname    = 'moodle';
$CFG->dbuser    = 'moodle_user';
$CFG->dbpass    = getenv('MOODLE_DB_PASSWORD');
$CFG->wwwroot   = 'http://localhost';
$CFG->dataroot  = '/var/www/moodledata';
$CFG->directorypermissions = 0755;
```

Giữ bản `moodle/public/.htaccess` trong repo; gói Moodle mới có thể ghi đè bằng
bản mặc định. Cách khôi phục nằm trong
[NOTES.vi.md](NOTES.vi.md#htaccess-của-webroot).

### 3. Tải image và khởi động

```bash
docker compose pull db redis cron
docker compose up -d --build
```

Ba image nền (`mysql:9`, `redis:latest`, `mcuadros/ofelia:latest`) được pull; hai
dịch vụ `moodle` và `caddy` build từ `./php` và `./caddy`. Lần chạy đầu mất 2 đến
10 phút vì phải khởi tạo MySQL, build image, chạy `composer install` và đăng ký
tác vụ Ofelia.

### 4. Cài đặt Moodle

Mở `http://<địa-chỉ-máy-chủ>` và làm theo trình cài đặt:

| Trường | Giá trị |
|---|---|
| Database host | `db` |
| Database name | `MOODLE_DB_NAME` |
| Database user | `MOODLE_DB_USER` |
| Database password | `MOODLE_DB_PASSWORD` |
| Data directory | `/var/www/moodledata` |

### 5. Cấu hình Redis

Vào **Site administration → Plugins → Caching → Configuration**, thêm instance
Redis với server `redis` và mật khẩu trong `.env`, rồi gán cho **Application** và
**Session**. Kiểm tra:

```bash
docker exec moodle_redis sh -c 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli ping'
```

Kết quả mong đợi: `PONG`.

## Phân quyền

Không dùng `chmod 777`. Entrypoint đồng nhất UID của tài khoản triển khai với
`www-data` bằng cách đọc owner của `./moodle` và `./moodledata`; owner `root`
hoặc UID nhỏ hơn 1000 được thay bằng 1000.

| Đường dẫn | Owner | Quyền của tài khoản triển khai |
|---|---|---|
| `moodle/`, `moodledata/` | tài khoản triển khai | Đọc, ghi, xóa |
| `logs/caddy`, `logs/moodle`, `logs/php` | tài khoản triển khai | Đọc, ghi, xóa |
| `logs/mysql`, `logs/redis` | user dịch vụ, group tài khoản triển khai | Đọc, xóa |
| `backup/` | tài khoản triển khai | Đọc, ghi, xóa |

Thư mục `755`, tệp `644`. Khi cần ép UID/GID khác, điền `PUID` và `PGID` trong
`.env` rồi build lại.

`docker exec` mặc định chạy bằng `root`, nên lệnh PHP cần thêm `-u www-data`:

```bash
docker exec -u www-data moodle_web php /var/www/html/admin/cli/purge_caches.php
```

Nếu đã có tệp thuộc `root`, chạy `bash scripts/fix-perms.sh`; chi tiết trong
[NOTES.vi.md](NOTES.vi.md#tệp-thuộc-root).

## Vận hành

### Backup và phục hồi

Mỗi ngày có hai job, cơ sở dữ liệu trước rồi tới tệp:

```bash
bash scripts/db-backup.sh                 # dump vào backup/moodle_<thời-gian>.sql và moodle_latest.sql
docker exec moodle_web sh /scripts/restic-backup.sh   # backup tăng dần moodledata
```

Ofelia chạy dump lúc 00:00 UTC (07:00 giờ Việt Nam) và job restic lúc 19:00 UTC
(02:00 giờ Việt Nam), nên tệp được sao lưu sau cơ sở dữ liệu. Kho restic nằm trong
`backup/restic`, được mã hóa bằng `RESTIC_PASSWORD`, và chỉ lưu phần thay đổi so
với lần trước: chạy lại khi dữ liệu không đổi chỉ thêm vài trăm byte thay vì một
bản đầy đủ. Sau mỗi lần backup thành công, script giữ 7 bản ngày gần nhất rồi dọn
phần cũ; một lần backup lỗi không bao giờ xóa bản tốt cuối cùng.

```bash
docker exec moodle_web restic snapshots      # xem ID và ngày
bash scripts/restic-restore.sh              # bản mới nhất -> backup/restore_<thời-gian>
bash scripts/restic-restore.sh <snapshot>   # một bản cụ thể trong danh sách
bash scripts/restic-restore.sh --in-place   # bản mới nhất đè lên moodledata/, có xác nhận
```

Không có `--in-place`, script chỉ ghi vào `backup/restore_<thời-gian>` và in số tệp,
nên chạy lúc nào cũng an toàn. Có `--in-place`, script dừng `moodle` và `cron`, chép
tệp, kiểm tra quyền rồi khởi động lại. Phục hồi cơ sở dữ liệu dùng
`bash scripts/db-restore.sh <tệp.sql>`. Mất `RESTIC_PASSWORD` là mất khả năng đọc
kho, nên phải giữ một bản ngoài máy chủ. Quy trình từng bước và lưu ý về lock nằm
trong [NOTES.vi.md](NOTES.vi.md#sao-lưu-tệp-bằng-restic).

### Cron

Ofelia chạy `admin/cli/cron.php` mỗi phút bằng UID của tài khoản triển khai, với
`--keep-alive=0`, nên mỗi lần chạy kết thúc ngay sau khi xử lý task. Service
`cron` giới hạn 256 MB và tự khởi động lại nếu vượt giới hạn.

### Log

| Dịch vụ | Đường dẫn | Định dạng |
|---|---|---|
| Caddy | `logs/caddy/access.log` | JSON, xoay 100 MB, giữ 30 tệp |
| Apache | `logs/moodle/access-YYYY-MM-DD.log` | Tách theo ngày |
| PHP | `logs/php/error-YYYY-MM-DD.log` | Tách theo ngày |
| MySQL | `logs/mysql/error.log` | Chỉ log lỗi |
| Redis | `logs/redis/redis.log` | Mức notice |

`scripts/log-rotate.sh` chạy hằng ngày và giữ 30 ngày. Log của Docker engine
giới hạn 10 MB mỗi tệp, tối đa 3 tệp cho mỗi container. Thời hạn giữ log trong
Moodle và cách dọn dẹp có trong [NOTES.vi.md](NOTES.vi.md#đĩa-và-log).

### Lệnh thường dùng

```bash
docker compose ps
docker compose logs -f moodle
docker compose restart moodle
docker compose down
docker compose up -d
```

Các quy trình khác — chạy offline bằng image, vá usermenu, nhập gói ngôn ngữ tùy
chỉnh, dọn dẹp — nằm trong [NOTES.vi.md](NOTES.vi.md).

## TLS và tên miền

Trong `Caddyfile`, thay `:80` bằng tên miền:

```text
lms.example.vn {
```

Caddy tự xin và gia hạn chứng chỉ Let's Encrypt. Sau khi đổi, cập nhật
`$CFG->wwwroot`, bật `$CFG->sslproxy = true` nếu chạy sau proxy, thay URL trong
cơ sở dữ liệu và xóa cache.

## Bảo mật

- Chỉ mở cổng 22, 80 và 443. MySQL và Redis không mở ra Internet.
- Đăng nhập SSH bằng khóa, tắt xác thực mật khẩu và đăng nhập `root`.
- `.env` có quyền `600`; ba mật khẩu MySQL root, MySQL ứng dụng và Redis phải
  khác nhau.
- `config.php` đọc mật khẩu cơ sở dữ liệu từ `MOODLE_DB_PASSWORD`.
- Caddy gửi `Strict-Transport-Security`, `Content-Security-Policy`,
  `X-Content-Type-Options`, `Referrer-Policy`, `Cross-Origin-Opener-Policy` và
  `Permissions-Policy`, đồng thời ẩn header `Server`. Apache bật `ServerTokens
  Prod` và `ServerSignature Off`.
- Caddy giới hạn 30 yêu cầu `POST` mỗi phút cho mỗi IP trên `/login/index.php` và
  `/login/token.php`, bổ sung cho chính sách khóa tài khoản của Moodle.
- `moodle/public/.htaccess` giữ schema và thư mục phát triển ngoài webroot.
- Bật cập nhật bảo mật tự động cho hệ điều hành và kiểm tra khả năng phục hồi.

## Cấu hình

Mặc định đủ dùng cho máy 4 GB. Các nút chỉnh chính:

| Hạng mục | Mặc định | Vị trí |
|---|---|---|
| Thread Apache / tiến trình PHP-FPM | tự tính; 40 / 24 trên máy 4 GB | `.env` |
| Độ bền MySQL | `innodb-flush-log-at-trx-commit=2`, `sync-binlog=0` | `docker-compose.yml` |
| Giới hạn PHP | upload và post 200 MB, memory 1 GB, không giới hạn thời gian chạy | `php/` |
| Bộ nhớ Redis | 256 MB, `allkeys-lru` | `docker-compose.yml` |

Công thức, đánh đổi và giá trị theo tải có trong
[NOTES.vi.md](NOTES.vi.md#ram-và-worker) và
[NOTES.vi.md](NOTES.vi.md#tinh-chỉnh-mysql).

## Tài liệu

- [NOTES.vi.md](NOTES.vi.md) — hiệu năng, tinh chỉnh và xử lý sự cố.
- [LIMITATIONS.vi.md](LIMITATIONS.vi.md) — giới hạn đã biết và cách sửa đề xuất.
- Bộ tài liệu tiếng Việt trong `docs/` (không đưa vào kho):

| Tệp | Nội dung |
|---|---|
| `HƯỚNG DẪN TRIỂN KHAI HỆ THỐNG LMS.md` | Triển khai từ máy chủ trống đến production |
| `HƯỚNG DẪN THAY ĐỔI DOMAIN HỆ THỐNG LMS.md` | Đổi địa chỉ truy cập và bật HTTPS |
| `HƯỚNG DẪN NÂNG CẤP HỆ THỐNG LMS.md` | Nâng cấp phiên bản, kiểm tra và quay lui |
| `HƯỚNG DẪN DI TRÚ HỆ THỐNG LMS.md` | Chuyển hệ thống sang máy chủ mới |
| `CẤU TRÚC VÀ CẤU HÌNH HỆ THỐNG.md` | Cấu trúc thư mục và tệp cấu hình |

## Giấy phép

PolyForm Noncommercial 1.0.0. Xem `LICENSE-EE.md`. Chỉ sử dụng cho mục đích
phi thương mại.
