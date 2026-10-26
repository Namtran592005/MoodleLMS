# Moodle LMS — Docker Skeleton

Khung triển khai Moodle 5.x bằng Docker Compose, bao gồm reverse proxy, TLS tự
động, PHP production, MySQL, Redis, cron và backup. Mục tiêu là dựng một hệ thống
LMS trên máy chủ Linux bằng một lệnh khởi động, với cấu hình đủ chặt để vận hành
thực tế.

Kho mã nguồn chỉ chứa khung cấu hình. Mã nguồn Moodle, `moodledata/`, `backup/`,
`logs/`, `.env` và tài liệu nội bộ không được đưa vào kho (xem `.gitignore`).

## Thành phần hệ thống

| Dịch vụ | Image | Vai trò | Cổng |
|---|---|---|---|
| `caddy` | build `./caddy` | Reverse proxy (Caddy latest + rate-limit), TLS tự động, header bảo mật | 80, 443, 443/udp |
| `db` | `mysql:9` | MySQL 9.7 LTS, `utf8mb4` | nội bộ 3306 |
| `redis` | `redis:latest` | Cache và session, giới hạn 256 MB | nội bộ 6379 |
| `moodle` | build `./php` | Apache 2.4 event MPM + PHP-FPM 8.5, webroot `/var/www/html` | nội bộ 80 |
| `cron` | `mcuadros/ofelia` | Cron Moodle, backup hằng ngày, xoay log | không mở |

Chỉ `caddy` mở cổng ra ngoài. Các dịch vụ còn lại chỉ truy cập được trong mạng
`moodle_net`.

## Kiến trúc

Yêu cầu từ trình duyệt được Caddy tiếp nhận qua HTTPS và chuyển tiếp tới
Apache/PHP trong `moodle_web`. PHP đọc ghi thư mục `moodledata`, truy vấn MySQL
và Redis, sau đó trả kết quả về Caddy.

PHP 8.5 chạy trong các tiến trình PHP-FPM, tách khỏi tiến trình Apache. Apache
dùng `mpm_event` với thread nên một tiến trình phục vụ được nhiều kết nối mà
không cấp thêm RAM cho từng kết nối. Entrypoint tự tính số worker theo CPU và RAM
rồi ghi vào `mpm_event.conf` và cấu hình PHP-FPM. Apache mặc định 40 thread, còn
PHP-FPM mặc định tối đa 24 tiến trình để giới hạn RAM; hai mức này chỉnh riêng
bằng `APACHE_MAX_REQUEST_WORKERS` và `PHP_FPM_MAX_CHILDREN` trong `.env`. Quá
trình build cũng dùng `-j$(nproc)` khi biên dịch extension.

Dữ liệu được phân bố như sau:

| Đường dẫn | Nội dung | Hình thức lưu trữ |
|---|---|---|
| `moodle/` | Mã nguồn Moodle | Bind mount |
| `moodledata/` | Tệp người dùng, cache, session | Bind mount |
| `backup/` | Bản dump cơ sở dữ liệu | Bind mount |
| `logs/` | Log của từng dịch vụ | Bind mount |
| `moodle_db_data` | Dữ liệu MySQL | Named volume |
| `caddy_data`, `caddy_config` | Chứng chỉ và cấu hình Caddy | Named volume |

Hệ thống không có dịch vụ khởi tạo riêng. Mỗi container tự tạo thư mục và đặt
quyền trong entrypoint của mình, nên việc xóa toàn bộ image không làm mất bước
khởi tạo. Tổng cộng năm image.

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
ls -ln .env
```

Tệp `.env` phải thuộc tài khoản triển khai. Nếu được tạo bằng `sudo`, đổi lại
owner trước khi chạy Compose:

```bash
sudo chown "$USER":"$USER" .env
chmod 600 .env
```

Các biến cần điền:

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
| `COMPOSE_PROJECT_NAME` | Giữ tên volume và network ổn định |

### 2. Đặt mã nguồn Moodle

Giải nén Moodle 5.x vào `moodle/`, giữ lại `config.php` nếu đã có:

```bash
mkdir -p moodle
tar -xzf moodle-5.x.tgz -C moodle --strip-components=1
```

Cấu hình tối thiểu trong `moodle/config.php`:

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

`docker compose pull db redis cron` tải ba image nền (`mysql:9`, `redis:latest`,
`mcuadros/ofelia:latest`). Hai dịch vụ `moodle` và `caddy` được build từ `./php`
và `./caddy`. Caddy dùng base tag `latest` và được build lại để thêm module
rate-limit, nên mỗi lần build sẽ lấy bản Caddy mới nhất.

Lần khởi động đầu tiên thực hiện tuần tự: tạo volume và mạng, khởi tạo MySQL,
khởi động Redis, build image PHP, chuẩn hóa quyền, chạy `composer install` nếu
có, khởi động Apache, đăng ký tác vụ Ofelia và khởi động Caddy. Thời gian hoàn
tất từ 2 đến 10 phút.

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

Trong phần quản trị, vào **Site administration → Plugins → Caching →
Configuration**, thêm một instance Redis với server `redis` và mật khẩu trong
`.env`, sau đó gán instance này cho **Application** và **Session**.

Kiểm tra:

```bash
docker exec moodle_redis sh -c 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli ping'
```

Kết quả mong đợi: `PONG`.

## Phân quyền

Hệ thống không sử dụng `chmod 777`. Quyền được xử lý bằng cách đồng nhất UID
giữa tài khoản triển khai trên máy chủ và tài khoản `www-data` trong container.

Entrypoint của `moodle` đọc owner của `./moodle` và `./moodledata`, sau đó chỉnh
`www-data` cho khớp. Apache, PHP và cron đều chạy bằng UID đó. Owner `root` và
các UID hệ thống nhỏ hơn 1000 không được dùng làm căn cứ; trường hợp đó áp dụng
mặc định 1000.

| Đường dẫn | Owner | Quyền của tài khoản triển khai |
|---|---|---|
| `moodle/`, `moodledata/` | tài khoản triển khai | Đọc, ghi, xóa |
| `logs/caddy`, `logs/moodle`, `logs/php` | tài khoản triển khai | Đọc, ghi, xóa |
| `logs/mysql`, `logs/redis` | user dịch vụ, group tài khoản triển khai | Đọc, xóa |
| `backup/` | tài khoản triển khai | Đọc, ghi, xóa |

Quyền tệp tiêu chuẩn: thư mục `755`, tệp `644`. Trong `config.php`, đặt
`$CFG->directorypermissions = 0755` để Moodle không tạo thư mục với quyền ghi
cho mọi tài khoản.

Khi cần ép UID/GID khác, điền `PUID` và `PGID` trong `.env` rồi chạy
`docker compose up -d --build`.

`docker exec` mặc định chạy bằng `root`. Để tạo hoặc sửa tệp trong container
bằng đúng UID của Moodle:

```bash
docker exec -it -u www-data moodle_web bash
```

Các lệnh `php admin/cli/...` cũng nên chạy bằng `-u www-data` để tệp cache
không thuộc `root`:

```bash
docker exec -u www-data moodle_web php /var/www/html/admin/cli/purge_caches.php
```

Nếu đã có tệp thuộc `root`, chuẩn hóa lại quyền bằng
`bash scripts/fix-perms.sh`.

## Vận hành

### Backup và phục hồi

```bash
bash scripts/db-backup.sh            # tạo backup/moodle_<thời-gian>.sql và moodle_latest.sql
bash scripts/db-restore.sh <tệp.sql> # phục hồi, có bước xác nhận
```

Ofelia chạy `mysqldump` hằng ngày và ghi đè `backup/moodle_latest.sql`. Bản
backup nằm trên cùng máy chủ nên cần đồng bộ ra ngoài bằng rsync, rclone hoặc
lưu trữ đối tượng.

### Xuất và nhập image để chạy offline

Dùng khi máy chủ mới không có Internet hoặc muốn tránh build và pull image mỗi
lần dựng lại:

```bash
# Trên máy đang chạy ổn định
cd /duong-dan/moodle-server
mkdir -p backup/images
docker save $(docker compose config --images) \
  | gzip -6 > backup/images/moodle-images.tar.gz

# Trên máy mới, sau khi đã sao chép mã nguồn, moodledata, .env và backup/
gunzip -c backup/images/moodle-images.tar.gz | docker load
docker compose up -d --no-build
```

Hoặc dùng script:

```bash
sh scripts/images-save.sh
sh scripts/images-load.sh
```

Tệp image chỉ chứa image Docker, không chứa `moodle/`, `moodledata/`, `.env`
hay dữ liệu MySQL. Cần sao chép các phần đó và `backup/moodle_latest.sql` để
hệ thống chạy đúng. Tên image đã cố định là `moodle-server-moodle:latest` và
`moodle-caddy:latest`, nên thư mục dự án có thể đặt tên bất kỳ. Biến
`COMPOSE_PROJECT_NAME` chỉ dùng để giữ tên volume và network ổn định.

### Log

| Dịch vụ | Đường dẫn | Định dạng |
|---|---|---|
| Caddy | `logs/caddy/access.log` | JSON, xoay nội bộ 100 MB, giữ 30 tệp |
| Apache | `logs/moodle/access-YYYY-MM-DD.log` | Tách theo ngày |
| PHP | `logs/php/error-YYYY-MM-DD.log` | Tách theo ngày |
| MySQL | `logs/mysql/error.log` | Chỉ log lỗi |
| Redis | `logs/redis/redis.log` | Mức notice |

`scripts/log-rotate.sh` chạy lúc 0 giờ mỗi ngày và giữ log trong 30 ngày. Log
của Docker engine được giới hạn 10 MB mỗi tệp, tối đa 3 tệp cho mỗi container.

MySQL chỉ bật `--log-error`. Khi cần phân tích truy vấn chậm, thêm tạm ba tham
số vào `command:` của dịch vụ `db`:

```text
--slow-query-log=1 --slow-query-log-file=/var/log/mysql/slow.log --long-query-time=2
```

### Cron

Ofelia chạy `admin/cli/cron.php` mỗi phút bằng UID của tài khoản triển khai, với
`--keep-alive=0` để mỗi lần chạy kết thúc ngay sau khi xử lý task. Service `cron`
được giới hạn 256 MB và `restart: always` sẽ khởi động lại nếu vượt giới hạn.

### Vá usermenu

Repo không chứa source Moodle, nên sau khi cài hoặc nâng cấp, chạy script để vá
usermenu:

```bash
bash scripts/patch-usermenu.sh
docker exec -u www-data moodle_web php /var/www/html/admin/cli/purge_caches.php
```

Script lưu bản gốc vào `backup/usermenu-patch/` và không ghi đè nếu mã nguồn đã
thay đổi.

### Lệnh thường dùng

```bash
docker compose ps
docker compose logs -f moodle
docker compose restart moodle
docker compose down
docker compose up -d
```

### Dọn dẹp

```bash
docker system prune -a
```

Lệnh này xóa image không dùng và container đã dừng, không ảnh hưởng volume dữ
liệu. Sau khi dọn, chạy `docker compose pull db redis cron` và
`docker compose up -d --build` để dựng lại.

Hai lệnh sau xóa cả dữ liệu và chỉ được dùng khi đã có backup:

```bash
docker compose down -v
docker system prune -a --volumes
```

## TLS và tên miền

Trong `Caddyfile`, thay `:80` bằng tên miền:

```text
lms.example.vn {
```

Caddy tự xin và gia hạn chứng chỉ Let's Encrypt. Sau khi đổi tên miền, cập nhật
`$CFG->wwwroot`, bật `$CFG->sslproxy = true` nếu chạy sau proxy, chạy công cụ
thay URL trong cơ sở dữ liệu và xóa cache. Quy trình đầy đủ nằm trong tài liệu
đổi domain.

## Bảo mật

- Chỉ mở cổng 22, 80 và 443. MySQL và Redis không mở ra Internet.
- Đăng nhập SSH bằng khóa, tắt xác thực mật khẩu và đăng nhập `root`.
- `.env` có quyền `600`; ba mật khẩu MySQL root, MySQL ứng dụng và Redis
  phải khác nhau.
- `moodle/config.php` đọc mật khẩu cơ sở dữ liệu từ biến môi trường
  `MOODLE_DB_PASSWORD`, không lưu mật khẩu trong tệp.
- Caddy gửi kèm `Strict-Transport-Security` khi dùng HTTPS,
  `Content-Security-Policy`, `X-Content-Type-Options`, `Referrer-Policy`,
  `Cross-Origin-Opener-Policy`, `Permissions-Policy` và ẩn header `Server`
  của Apache. Apache bật `ServerTokens Prod` và `ServerSignature Off` nên
  không lộ phiên bản trong header hoặc trang lỗi.
- Caddy giới hạn 30 yêu cầu `POST` mỗi phút cho mỗi IP trên
  `/login/index.php` và `/login/token.php`, bổ sung cho chính sách khóa tài
  khoản của Moodle.
- Apache chặn các tệp schema và thư mục kiểm thử nằm trong webroot
  (`install.xml`, `environment.xml`, `*.schema.json`, `/lib/db/`,
  `/lib/tests/`, `/lib/phpunit/`).
- Bật cập nhật bảo mật tự động cho hệ điều hành và kiểm tra định kỳ.
- Duy trì backup ngoài máy chủ và kiểm tra khả năng phục hồi.

## Cấu hình theo tải

| Hạng mục | Khoảng 100 người dùng đồng thời | Khoảng 1000 người dùng đồng thời |
|---|---|---|
| CPU / RAM | 4 vCPU / 8 GB | 16 vCPU / 64 GB |
| Ổ đĩa | 100 GB | 500 GB |
| Mô hình | Một máy chủ | Một máy chủ lớn, hoặc tách web và cơ sở dữ liệu |

Tham số cần điều chỉnh:

| Tham số | 100 người dùng | 1000 người dùng | Vị trí |
|---|---|---|---|
| `innodb_buffer_pool_size` | 2 GB | 16 đến 24 GB | `command:` của `db` |
| Redis `maxmemory` | 256 đến 512 MB | 2 GB | `command:` của `redis` |
| `opcache.memory_consumption` | 256 MB | 512 MB | `php/Dockerfile` |
| Apache `MaxRequestWorkers` (thread, event MPM) | tự động 32–64 | 300 đến 500 (đặt `APACHE_MAX_REQUEST_WORKERS`) | `php/entrypoint.sh` hoặc `.env` |
| PHP-FPM `pm.max_children` | 24 (mặc định) | 300 đến 500 (đặt `PHP_FPM_MAX_CHILDREN`) | `php/entrypoint.sh` hoặc `.env` |

`MaxRequestWorkers` được entrypoint tính theo công thức:

```text
min(nproc * 16, (RAM_khả_dụng - dự_phòng) / 64 MB, 150)
```

Dự phòng 1,5 GB cho host 4 GB và 2 GB cho host 8 GB, dành cho MySQL, Redis,
Caddy, Ofelia và hệ điều hành. `MaxRequestWorkers` là số thread của event MPM,
không phải số tiến trình: entrypoint đặt `ThreadsPerChild = 10`,
`ServerLimit = ceil(worker / 10)` và `MaxRequestWorkers` được làm tròn lên bội
số của 10. Vì vậy 40 worker tương ứng 4 tiến trình Apache, mỗi tiến trình 10
thread.

PHP-FPM có giới hạn riêng, mặc định `pm.max_children = 24`, đặt bằng
`PHP_FPM_MAX_CHILDREN` và không vượt quá số worker Apache. Các tham số còn lại
là `pm.start_servers = 2 * nproc`, `pm.min_spare_servers = nproc`,
`pm.max_spare_servers = 4 * nproc` (không vượt quá `pm.max_children`) và
`pm.max_requests = 500`. Với container có `mem_limit` hoặc `cpus`, entrypoint
đọc giới hạn cgroup thay vì dùng toàn bộ RAM/CPU của host.

RAM thực tế do PHP-FPM quyết định, vì mỗi worker PHP là một tiến trình riêng;
event MPM chỉ giảm phần overhead của Apache. Trên máy 4 GB nên giữ
`APACHE_MAX_REQUEST_WORKERS=40`, `PHP_FPM_MAX_CHILDREN=24` và theo dõi bộ nhớ
trước khi tăng.

Khi vượt ngưỡng trên, tách MySQL sang máy chủ riêng bằng cách đổi host cơ sở dữ
liệu, sau đó nhân bản container `moodle` phía sau bộ cân bằng tải.

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
