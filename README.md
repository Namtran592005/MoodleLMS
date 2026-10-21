# Moodle LMS — Docker Skeleton

Khung triển khai Moodle 5.x bằng Docker Compose, bao gồm reverse proxy, TLS tự
động, PHP production, MySQL, Redis, cron và backup. Mục tiêu là rút gọn việc
dựng một hệ thống LMS trên máy chủ Linux xuống còn một lệnh khởi động, đồng
thời giữ cấu hình đủ chặt để vận hành thực tế.

Kho mã nguồn chỉ chứa khung cấu hình. Mã nguồn Moodle, `moodledata/`,
`backup/`, `logs/`, `.env` và tài liệu nội bộ không được đưa vào kho (xem
`.gitignore`).

## Thành phần hệ thống

| Dịch vụ | Image | Vai trò | Cổng |
|---|---|---|---|
| `caddy` | `caddy:alpine` | Reverse proxy, TLS tự động, header bảo mật | 80, 443, 443/udp |
| `db` | `mysql:9` | Cơ sở dữ liệu MySQL 9 LTS, `utf8mb4` | nội bộ 3306 |
| `redis` | `redis:latest` | Cache và session, giới hạn 256 MB | nội bộ 6379 |
| `moodle` | build `./php` | Apache 2.4, PHP 8.4, DocumentRoot `/public` | nội bộ 80 |
| `cron` | `mcuadros/ofelia` | Cron Moodle, backup hằng ngày, xoay log | không mở |

Chỉ `caddy` mở cổng ra ngoài. Các dịch vụ còn lại chỉ truy cập được trong mạng
`moodle_net`.

## Kiến trúc

Yêu cầu từ trình duyệt được Caddy tiếp nhận qua HTTPS và chuyển tiếp tới
Apache/PHP trong `moodle_web`. PHP đọc ghi thư mục `moodledata`, truy vấn MySQL
và Redis, sau đó trả kết quả về Caddy.

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

Tệp `.env` phải thuộc tài khoản triển khai. Nếu được tạo bằng `sudo`, owner là
`root` và `docker compose` cũng như các script backup sẽ báo `Permission denied`:

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
$CFG->dbpass    = '<mật khẩu trong .env>';
$CFG->wwwroot   = 'http://localhost';
$CFG->dataroot  = '/var/www/moodledata';
$CFG->directorypermissions = 0755;
```

### 3. Tải image và khởi động

```bash
docker compose pull
docker compose up -d --build
```

`docker compose pull` tải bốn image nền. Dịch vụ `moodle` được build từ
`./php` nên không có image để tải.

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

## Vận hành

### Backup và phục hồi

```bash
bash scripts/db-backup.sh            # tạo backup/moodle_<thời-gian>.sql và moodle_latest.sql
bash scripts/db-restore.sh <tệp.sql> # phục hồi, có bước xác nhận
```

Ofelia chạy `mysqldump` hằng ngày và ghi đè `backup/moodle_latest.sql`. Bản
backup nằm trên cùng máy chủ nên cần đồng bộ ra ngoài bằng rsync, rclone hoặc
lưu trữ đối tượng.

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

Ofelia chạy `admin/cli/cron.php` mỗi phút bằng UID của tài khoản triển khai,
nên tệp cache và session do cron tạo không gây lỗi quyền cho các tiến trình
khác.

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
liệu. Sau khi dọn, chạy `docker compose pull` và `docker compose up -d --build`
để dựng lại.

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
- `.env` có quyền `600`.
- Caddy gửi kèm `Strict-Transport-Security` khi dùng HTTPS,
  `Content-Security-Policy`, `X-Content-Type-Options`, `Permissions-Policy` và
  ẩn header `Server` của Apache.
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
| Apache `MaxRequestWorkers` | mặc định | 300 đến 500 | cấu hình Apache bổ sung |

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
