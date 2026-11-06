# Moodle LMS — Docker Skeleton

Khung triển khai Moodle 5.x bằng Docker Compose: reverse proxy, TLS tự động, PHP
production, MySQL, Redis, cron và backup. Mục tiêu là dựng hệ thống LMS trên máy
chủ Linux bằng một lệnh khởi động, với cấu hình đủ chặt để vận hành thực tế.

Kho chỉ chứa khung cấu hình. Mã nguồn Moodle, `moodledata/`, `backup/`, `logs/`,
`.env` và tài liệu nội bộ không đưa vào kho (xem `.gitignore`). Riêng
`moodle/public/.htaccess` được giữ lại vì là tệp cấu hình Apache quan trọng.

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
`mpm_event` với thread, PHP 8.5 chạy trong các tiến trình PHP-FPM tách riêng;
số worker do entrypoint tính theo CPU và RAM, chi tiết ở mục **Cấu hình**.

Dữ liệu được phân bố như sau:

| Đường dẫn | Nội dung | Hình thức lưu trữ |
|---|---|---|
| `moodle/` | Mã nguồn Moodle | Bind mount |
| `moodledata/` | Tệp người dùng, cache, session | Bind mount |
| `backup/` | Bản dump cơ sở dữ liệu | Bind mount |
| `logs/` | Log của từng dịch vụ | Bind mount |
| `moodle_db_data` | Dữ liệu MySQL | Named volume |
| `caddy_data`, `caddy_config` | Chứng chỉ và cấu hình Caddy | Named volume |

Không có dịch vụ khởi tạo riêng: mỗi container tự tạo thư mục và đặt quyền trong
entrypoint, nên xóa image không làm mất bước khởi tạo. Tổng cộng năm image.

## Yêu cầu

| Hạng mục | Tối thiểu | Khuyến nghị |
|---|---|---|
| Hệ điều hành | Ubuntu 22.04 hoặc Debian 12 | Ubuntu 24.04 LTS |
| Docker | Engine 24 kèm Compose v2 | Bản mới nhất |
| CPU | 2 vCPU | 4 vCPU |
| RAM | 4 GB | 8 GB |
| Ổ đĩa | 50 GB SSD | 100 GB NVMe |
| Tên miền | Không bắt buộc khi chạy thử | Bắt buộc khi chạy production |

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
| `TZ` | Múi giờ, mặc định `Asia/Ho_Chi_Minh` |
| `APP_ENV` | `production` |
| `PUID`, `PGID` | Không bắt buộc, dùng khi cần ép UID/GID |
| `APACHE_MAX_REQUEST_WORKERS`, `PHP_FPM_MAX_CHILDREN` | Số worker, mặc định tự tính; xem mục **Worker và PHP-FPM** |
| `COMPOSE_PROJECT_NAME` | Giữ tên volume và network ổn định |

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

Hệ thống không dùng `chmod 777`. Quyền được xử lý bằng cách đồng nhất UID giữa
tài khoản triển khai và `www-data` trong container: entrypoint đọc owner của
`./moodle` và `./moodledata` rồi chỉnh `www-data` cho khớp. Owner `root` và UID
hệ thống nhỏ hơn 1000 không được dùng làm căn cứ; trường hợp đó áp dụng 1000.

| Đường dẫn | Owner | Quyền của tài khoản triển khai |
|---|---|---|
| `moodle/`, `moodledata/` | tài khoản triển khai | Đọc, ghi, xóa |
| `logs/caddy`, `logs/moodle`, `logs/php` | tài khoản triển khai | Đọc, ghi, xóa |
| `logs/mysql`, `logs/redis` | user dịch vụ, group tài khoản triển khai | Đọc, xóa |
| `backup/` | tài khoản triển khai | Đọc, ghi, xóa |

Quyền tệp tiêu chuẩn: thư mục `755`, tệp `644`. `$CFG->directorypermissions =
0755` để Moodle không tạo thư mục ghi cho mọi tài khoản. Khi cần ép UID/GID khác,
điền `PUID` và `PGID` trong `.env` rồi chạy `docker compose up -d --build`.

`docker exec` mặc định chạy bằng `root`, nên các lệnh PHP cần thêm `-u www-data`
để tệp cache không thuộc `root`:

```bash
docker exec -it -u www-data moodle_web bash
docker exec -u www-data moodle_web php /var/www/html/admin/cli/purge_caches.php
```

Nếu đã có tệp thuộc `root`, chuẩn hóa lại bằng `bash scripts/fix-perms.sh`.

## Vận hành

### Backup và phục hồi

```bash
bash scripts/db-backup.sh            # tạo backup/moodle_<thời-gian>.sql và moodle_latest.sql
bash scripts/db-restore.sh <tệp.sql> # phục hồi, có bước xác nhận
```

Ofelia chạy `mysqldump` hằng ngày và ghi đè `backup/moodle_latest.sql`. Bản
backup nằm cùng máy chủ nên cần đồng bộ ra ngoài bằng rsync, rclone hoặc lưu trữ
đối tượng.

### Chạy offline bằng image

Dùng khi máy chủ mới không có Internet:

```bash
# Trên máy đang chạy ổn định
mkdir -p backup/images
docker save $(docker compose config --images) \
  | gzip -6 > backup/images/moodle-images.tar.gz

# Trên máy mới, sau khi đã sao chép mã nguồn, moodledata, .env và backup/
gunzip -c backup/images/moodle-images.tar.gz | docker load
docker compose up -d --no-build
```

Hoặc dùng `sh scripts/images-save.sh` và `sh scripts/images-load.sh`. Tệp image
chỉ chứa image Docker, không chứa `moodle/`, `moodledata/`, `.env` hay dữ liệu
MySQL; phải sao chép các phần đó và `backup/moodle_latest.sql` riêng. Tên image
đã cố định là `moodle-server-moodle:latest` và `moodle-caddy:latest` nên thư mục
dự án có thể đặt tên bất kỳ.

### Log

| Dịch vụ | Đường dẫn | Định dạng |
|---|---|---|
| Caddy | `logs/caddy/access.log` | JSON, xoay nội bộ 100 MB, giữ 30 tệp |
| Apache | `logs/moodle/access-YYYY-MM-DD.log` | Tách theo ngày |
| PHP | `logs/php/error-YYYY-MM-DD.log` | Tách theo ngày |
| MySQL | `logs/mysql/error.log` | Chỉ log lỗi |
| Redis | `logs/redis/redis.log` | Mức notice |

`scripts/log-rotate.sh` chạy lúc 0 giờ mỗi ngày và giữ log trong 30 ngày. Log
của Docker engine giới hạn 10 MB mỗi tệp, tối đa 3 tệp cho mỗi container.

### Cron

Ofelia chạy `admin/cli/cron.php` mỗi phút bằng UID của tài khoản triển khai, với
`--keep-alive=0` để mỗi lần chạy kết thúc ngay sau khi xử lý task. Service `cron`
giới hạn 256 MB và `restart: always` sẽ khởi động lại nếu vượt giới hạn.

### Vá usermenu

Sau khi cài hoặc nâng cấp, chạy script để vá usermenu:

```bash
bash scripts/patch-usermenu.sh
docker exec -u www-data moodle_web php /var/www/html/admin/cli/purge_caches.php
```

Script lưu bản gốc vào `backup/usermenu-patch/` và không ghi đè nếu mã nguồn đã
thay đổi.

### Tệp .htaccess của webroot

`moodle/public/.htaccess` được giữ trong repo vì tệp bật router `r.php`, chặn
tải `install.xml`, `environment.xml`, `roles_schema.xml`, `*.schema.json` và các
thư mục `lib/db`, `lib/tests`, `lib/phpunit`.

Khi giải nén bản Moodle mới, tệp có thể bị ghi đè bằng bản mặc định. Khôi phục
bản trong repo rồi kiểm tra:

```bash
git checkout -- moodle/public/.htaccess
install -m 644 moodle/public/.htaccess /duong-dan/moodle/public/.htaccess
docker exec moodle_web apache2ctl -t
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost/theme/boost/style/moodle.css
```

### Nhập gói ngôn ngữ tùy chỉnh

Mở thẳng `/admin/tool/customlang/import.php?lng=vi` để vào form nhập ZIP. Mục
Import trên menu chạy checkout trước nên với gói lớn có thể mất vài phút; PHP-FPM
và Apache cho phép tối đa 900 giây cho một request và mỗi tab đang mở đều có thể
chạy lại checkout, nên chỉ mở một tab.

### Lệnh thường dùng

```bash
docker compose ps
docker compose logs -f moodle
docker compose restart moodle
docker compose down
docker compose up -d
```

### Dọn dẹp

`docker system prune -a` xóa image không dùng và container đã dừng, không ảnh
hưởng volume dữ liệu; sau đó chạy lại `docker compose up -d --build`. Hai lệnh
sau xóa cả dữ liệu và chỉ dùng khi đã có backup:

```bash
docker compose down -v
docker system prune -a --volumes
```

## TLS và tên miền

Trong `Caddyfile`, thay `:80` bằng tên miền:

```text
lms.example.vn {
```

Caddy tự xin và gia hạn chứng chỉ Let's Encrypt. Sau khi đổi, cập nhật
`$CFG->wwwroot`, bật `$CFG->sslproxy = true` nếu chạy sau proxy, chạy công cụ
thay URL trong cơ sở dữ liệu và xóa cache; quy trình đầy đủ nằm trong tài liệu
đổi domain.

## Bảo mật

- Chỉ mở cổng 22, 80 và 443. MySQL và Redis không mở ra Internet.
- Đăng nhập SSH bằng khóa, tắt xác thực mật khẩu và đăng nhập `root`.
- `.env` có quyền `600`; ba mật khẩu MySQL root, MySQL ứng dụng và Redis phải
  khác nhau.
- `config.php` đọc mật khẩu cơ sở dữ liệu từ `MOODLE_DB_PASSWORD`, không lưu
  mật khẩu trong tệp.
- Caddy gửi `Strict-Transport-Security` khi dùng HTTPS, `Content-Security-Policy`,
  `X-Content-Type-Options`, `Referrer-Policy`, `Cross-Origin-Opener-Policy`,
  `Permissions-Policy` và ẩn header `Server`. Apache bật `ServerTokens Prod` và
  `ServerSignature Off` nên không lộ phiên bản trong header hoặc trang lỗi.
- Caddy giới hạn 30 yêu cầu `POST` mỗi phút cho mỗi IP trên `/login/index.php` và
  `/login/token.php`, bổ sung cho chính sách khóa tài khoản của Moodle.
- Webroot không lộ schema hay thư mục phát triển, nhờ
  `moodle/public/.htaccess` (xem mục **Tệp .htaccess của webroot**).
- Bật cập nhật bảo mật tự động cho hệ điều hành và kiểm tra định kỳ.
- Duy trì backup ngoài máy chủ và kiểm tra khả năng phục hồi.

## Cấu hình

### MySQL

`db` chạy với `--innodb-flush-log-at-trx-commit=2` và `--sync-binlog=0` để các
tác vụ ghi hàng loạt không phải chờ `fsync` sau từng câu lệnh; checkout gói ngôn
ngữ giảm từ khoảng 320 giây xuống 25 giây. Đánh đổi: mất điện hoặc kernel panic
có thể mất tối đa một giây giao dịch vừa commit, dữ liệu vẫn nhất quán. Cần độ
bền tuyệt đối thì bỏ hai tham số này.

Về log, MySQL chỉ bật `--log-error` để ghi lỗi vào `logs/mysql/error.log`. Khi
cần tìm truy vấn chậm, thêm tạm vào `command:` của `db`:

```text
--slow-query-log=1 --slow-query-log-file=/var/log/mysql/slow.log --long-query-time=2
```

### Worker và PHP-FPM

Entrypoint tính `MaxRequestWorkers` theo công thức:

```text
min(nproc * 16, (RAM_khả_dụng - dự_phòng) / 64 MB, 150)
```

Dự phòng 1,5 GB cho host 4 GB và 2 GB cho host 8 GB. Đây là số thread của
`mpm_event`, không phải số tiến trình: `ThreadsPerChild = 10`, `ServerLimit =
ceil(worker / 10)` và làm tròn lên bội số 10, nên 40 worker là 4 tiến trình
Apache. PHP-FPM mặc định `pm.max_children = 24`, đặt bằng `PHP_FPM_MAX_CHILDREN`
và không vượt quá số worker Apache; các tham số còn lại là `pm.start_servers =
2 * nproc`, `pm.min_spare_servers = nproc`, `pm.max_spare_servers = 4 * nproc`
và `pm.max_requests = 500`. Container có `mem_limit` hoặc `cpus` được đọc giới
hạn cgroup thay vì dùng toàn bộ tài nguyên host.

RAM thực tế do PHP-FPM quyết định vì mỗi worker là một tiến trình; event MPM chỉ
giảm overhead của Apache. Trên máy 4 GB nên giữ `APACHE_MAX_REQUEST_WORKERS=40`,
`PHP_FPM_MAX_CHILDREN=24` và theo dõi bộ nhớ trước khi tăng.

### Theo tải

| Hạng mục | Khoảng 100 người dùng đồng thời | Khoảng 1000 người dùng đồng thời |
|---|---|---|
| CPU / RAM | 4 vCPU / 8 GB | 16 vCPU / 64 GB |
| Ổ đĩa | 100 GB | 500 GB |
| Mô hình | Một máy chủ | Một máy chủ lớn, hoặc tách web và cơ sở dữ liệu |

| Tham số | 100 người dùng | 1000 người dùng | Vị trí |
|---|---|---|---|
| `innodb_buffer_pool_size` | 2 GB | 16 đến 24 GB | `command:` của `db` |
| Redis `maxmemory` | 256 đến 512 MB | 2 GB | `command:` của `redis` |
| `opcache.memory_consumption` | 256 MB | 512 MB | `php/Dockerfile` |
| Apache `MaxRequestWorkers` (thread) | tự động 32–64 | 300 đến 500 | `APACHE_MAX_REQUEST_WORKERS` trong `.env` |
| PHP-FPM `pm.max_children` | 24 (mặc định) | 300 đến 500 | `PHP_FPM_MAX_CHILDREN` trong `.env` |

Khi vượt ngưỡng, tách MySQL sang máy chủ riêng bằng cách đổi host cơ sở dữ liệu,
sau đó nhân bản container `moodle` phía sau bộ cân bằng tải.

## Tài liệu

Bộ tài liệu tiếng Việt trong thư mục `docs/` (không đưa vào kho):

| Tệp | Nội dung |
|---|---|
| `HƯỚNG DẪN TRIỂN KHAI HỆ THỐNG LMS.md` | Triển khai từ máy chủ trống đến production |
| `HƯỚNG DẪN THAY ĐỔI DOMAIN HỆ THỐNG LMS.md` | Đổi địa chỉ truy cập và bật HTTPS |
| `HƯỚNG DẪN NÂNG CẤP HỆ THỐNG LMS.md` | Nâng cấp phiên bản, kiểm tra và quay lui |
| `HƯỚNG DẪN DI TRÚ HỆ THỐNG LMS.md` | Chuyển hệ thống sang máy chủ mới |
| `CẤU TRÚC VÀ CẤU HÌNH HỆ THỐNG.md` | Cấu trúc thư mục và toàn bộ tệp cấu hình để phục dựng |

## Giấy phép

PolyForm Noncommercial 1.0.0. Xem `LICENSE-EE.md`. Chỉ sử dụng cho mục đích
phi thương mại.
