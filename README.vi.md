# Moodle LMS — Docker Skeleton

[English](README.md) | **Tiếng Việt**

Khung triển khai Moodle 5.x bằng Docker Compose: reverse proxy, TLS tự động, PHP
production, MySQL, Redis, cron và backup. Mục tiêu là dựng hệ thống LMS trên máy
chủ Linux bằng một lệnh khởi động. Mã nguồn hiện tại là Moodle 5.3.1 (build
20261112).

Kho chỉ chứa khung cấu hình và hai tệp của Moodle. Mã nguồn Moodle,
`moodledata/`, `backup/`, `logs/`, `.env` và tài liệu nội bộ không đưa vào kho
(xem `.gitignore`). Hai ngoại lệ là `moodle/public/.htaccess`, tệp cấu hình
Apache quan trọng, và `moodle/config.php`, tệp không chứa bí mật vì mật khẩu cơ
sở dữ liệu đọc từ `MOODLE_DB_PASSWORD`.

Phần tính toán RAM, tinh chỉnh và cách xử lý lỗi nằm trong
[NOTES.vi.md](NOTES.vi.md). Tệp này chỉ tập trung vào việc dựng hệ thống chạy được.

## Thành phần hệ thống

| Dịch vụ | Image | Vai trò | Cổng |
|---|---|---|---|
| `caddy` | build `./caddy` (`moodle-caddy:2.11`) | Reverse proxy (Caddy 2.11 + rate-limit), TLS tự động, header bảo mật | 80, 443, 443/udp |
| `db` | `mysql:9.7` | MySQL 9.7 LTS, `utf8mb4` | nội bộ 3306 |
| `redis` | `redis:8.10` | Cache và session, giới hạn 256 MB | nội bộ 6379 |
| `moodle` | build `./php` (`moodle-server-moodle:5.3`) | Apache 2.4 event MPM + PHP-FPM 8.5, webroot `/var/www/html/public` | nội bộ 80 |
| `socket-proxy` | build `./cetusguard` (`moodle-cetusguard:v1`) | Lọc Docker API, chỉ cho exec vào container Moodle | nội bộ 2375 |
| `cron` | `mcuadros/ofelia:0.3` | Cron Moodle, backup restic (cơ sở dữ liệu và tệp), xoay log | không mở |

Chỉ `caddy` mở cổng ra ngoài. `db`, `redis` và `moodle` chỉ truy cập được trong
`moodle_net`; `cron` và `socket-proxy` dùng chung mạng nội bộ riêng `socket_net`,
mạng này không có đường ra ngoài.

## Kiến trúc

Caddy nhận HTTPS và chuyển tiếp tới Apache/PHP trong `moodle_web`. PHP đọc ghi
`moodledata`, truy vấn MySQL và Redis rồi trả kết quả về Caddy. Apache dùng
`mpm_event` với thread, PHP 8.5 chạy trong các tiến trình PHP-FPM tách riêng.

Dữ liệu được phân bố như sau:

| Đường dẫn | Nội dung | Hình thức lưu trữ |
|---|---|---|
| `moodle/` | Mã nguồn Moodle | Bind mount |
| `moodledata/` | Tệp người dùng, cache, session | Bind mount |
| `backup/` | Kho restic (bản dump cơ sở dữ liệu và `moodledata`) | Bind mount |
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
| `MOODLE_DB_HOST` | Tên máy chủ cơ sở dữ liệu, mặc định `db` |
| `MOODLE_DB_NAME` | Tên cơ sở dữ liệu |
| `MOODLE_DB_USER` | Tài khoản MySQL dành cho Moodle |
| `MOODLE_DB_PASSWORD` | Mật khẩu của tài khoản trên |
| `MOODLE_WWWROOT` | Địa chỉ công khai của Moodle, mặc định `http://localhost` |
| `MOODLE_SSLPROXY` | `true` khi Caddy kết thúc TLS, mặc định `false` |
| `REDIS_PASSWORD` | Mật khẩu Redis |
| `RESTIC_PASSWORD` | Mật khẩu mã hóa kho restic |
| `RESTIC_REPOSITORY` | Tùy chọn, mặc định `/backup/restic` |
| `TZ` | Múi giờ, mặc định `Asia/Ho_Chi_Minh` |
| `APP_ENV` | `production` |
| `PUID`, `PGID` | UID/GID cho `www-data`, mặc định `1000` |
| `APACHE_MAX_REQUEST_WORKERS`, `APACHE_START_SERVERS` | Số thread và process Apache, để trống thì tự tính |
| `PHP_FPM_MAX_CHILDREN` | Số tiến trình PHP-FPM, mặc định `24` |
| `MOODLE_WORKER_MEM_MB`, `MOODLE_MEM_RESERVE_MB` | RAM cho mỗi worker và RAM chừa cho dịch vụ khác |
| `COMPOSE_PROJECT_NAME` | Giữ tên volume và network ổn định |

Cách tính worker, hành vi bộ nhớ và giá trị theo tải có trong
[NOTES.vi.md](NOTES.vi.md#ram-và-worker).

### 2. Đặt mã nguồn Moodle

Giải nén Moodle 5.x vào `moodle/`. Gói phát hành không có `config.php`, nên bản
đang được theo dõi trong repo vẫn giữ nguyên:

```bash
mkdir -p moodle
tar -xzf moodle-5.x.tgz -C moodle --strip-components=1
```

```php
$CFG->dbtype    = 'mysqli';
$CFG->dbhost    = getenv('MOODLE_DB_HOST') ?: 'db';
$CFG->dbname    = getenv('MOODLE_DB_NAME') ?: 'moodle';
$CFG->dbuser    = getenv('MOODLE_DB_USER') ?: 'moodle_user';
$CFG->dbpass    = getenv('MOODLE_DB_PASSWORD') ?: '';
$CFG->wwwroot   = getenv('MOODLE_WWWROOT') ?: 'http://localhost';
$CFG->dataroot  = '/var/www/moodledata';
$CFG->directorypermissions = 0755;
```

Mọi giá trị cơ sở dữ liệu và địa chỉ công khai đều đọc từ `.env`, nên bộ
`MOODLE_DB_*` khác hoặc tên miền thật không cần sửa tệp này. Chỉ sửa `.env` rồi
tạo lại container:

```bash
docker compose up -d moodle
```

Giữ bản `moodle/public/.htaccess` trong repo; gói Moodle mới có thể ghi đè bằng
bản mặc định. Cách khôi phục nằm trong
[NOTES.vi.md](NOTES.vi.md#htaccess-của-webroot).

### 3. Tải image và khởi động

```bash
docker compose pull db redis cron
docker compose up -d --build
```

Ba image nền (`mysql:9.7`, `redis:8.10`, `mcuadros/ofelia:0.3`) được pull trực
tiếp; `moodle`, `caddy` và `socket-proxy` build từ `./php`, `./caddy` và
`./cetusguard`, gắn tag `moodle-server-moodle:5.3`, `moodle-caddy:2.11` và
`moodle-cetusguard:v1`. Bản build Caddy bắt đầu từ `caddy:2.11-*`, bản build proxy
từ `hectorm/cetusguard:v1` và chỉ thêm busybox tĩnh cho healthcheck. Lần chạy đầu
mất 2 đến 10 phút vì phải khởi tạo MySQL, build image, chạy `composer install` và
đăng ký tác vụ Ofelia.

### 4. Cài đặt Moodle

Mở `http://<địa-chỉ-máy-chủ>`. `config.php` đã có sẵn thông tin cơ sở dữ liệu và
địa chỉ lấy từ `.env`, nên trình cài đặt bỏ qua phần cơ sở dữ liệu và chỉ hỏi tài
khoản quản trị cùng thông tin site. Thư mục dữ liệu vẫn là `/var/www/moodledata`.

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
| `logs/mysql`, `logs/redis` | user dịch vụ, group tài khoản triển khai | Đọc, ghi, xóa |
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

Một job chạy mỗi ngày lúc 00:00 theo múi giờ `Asia/Ho_Chi_Minh` và tạo hai
snapshot restic: bản dump cơ sở dữ liệu mang tag `db`, và `moodledata` mang tag
`files`. Ofelia gọi job này; chạy tay cũng dùng đúng job đó:

```bash
bash scripts/restic-backup.sh             # chạy backup ngay, không chờ lịch
```

Job dump cơ sở dữ liệu Moodle bằng `mysqldump --single-transaction` ra tệp tạm,
sao lưu tệp đó thành snapshot `db`, sao lưu `moodledata` thành snapshot `files`,
rồi xóa bản SQL gốc ngay khi restic xong. Không còn bản dump không mã hóa nằm
trong `backup/`. Kho nằm trong `backup/restic` và được mã hóa bằng
`RESTIC_PASSWORD`.

Restic chia dữ liệu thành từng khối, lưu mỗi khối một lần và nén lại, nên một bản
dump 22 MB gần như không đổi chỉ thêm khoảng 1 MB. Sau mỗi lần chạy thành công,
job giữ **2 snapshot `db`** và **7 snapshot `files` theo ngày**, rồi dọn những
khối không còn snapshot nào dùng. Dump hoặc backup lỗi không bao giờ xóa bản tốt
cuối cùng.

Hai script chia nhau công việc:

- `scripts/restic-backup.sh` chạy trên host, khởi động backup ngay, rồi in 3
  snapshot mới nhất và dung lượng kho.
- `scripts/restic-job.sh` là phần việc thật, chạy trong container; Ofelia gọi
  theo lịch nên không cần chạy trực tiếp.

Phục hồi được tách riêng để lấy cơ sở dữ liệu, tệp, hoặc cả hai:

```bash
docker exec moodle_web restic snapshots           # xem ID và ngày
bash scripts/restic-restore.sh                    # bản mới nhất, DB + tệp -> backup/restore_<thời-gian>
bash scripts/restic-restore.sh --db               # chỉ dump DB -> thư mục tạm
bash scripts/restic-restore.sh --files            # chỉ moodledata -> thư mục tạm
bash scripts/restic-restore.sh 9711dea3           # một bản cụ thể trong danh sách
bash scripts/restic-restore.sh --db --in-place    # import DB, có xác nhận
bash scripts/restic-restore.sh --files --in-place # chép moodledata, có xác nhận
bash scripts/restic-export.sh                     # dump thành SQL rời -> ~/moodle-dump_<thời-gian>.sql
```

`restic-export.sh` lấy dump từ snapshot `db` mới nhất ra một tệp SQL rời nằm ngoài
thư mục triển khai, mặc định `~/moodle-dump_<thời-gian>.sql`, để import ở máy khác
hoặc chép ra USB. Thêm `--out=/đường/dẫn/file.sql` để chọn chỗ ghi và một ID
snapshot để lấy bản cũ hơn. Tệp này không mã hóa: chuyển đi rồi xóa.

Không có `--in-place`, script chỉ ghi vào `backup/restore_<thời-gian>` và in số
tệp cùng đường dẫn dump, nên chạy lúc nào cũng an toàn. Có `--in-place`, script
dừng `moodle` và `cron`, import dump và/hoặc chép tệp, khởi động lại, chờ
healthcheck rồi xóa cache. Mất `RESTIC_PASSWORD` là mất khả năng đọc kho, nên
phải giữ một bản ngoài máy chủ. Quy trình từng bước và lưu ý về lock nằm trong
[NOTES.vi.md](NOTES.vi.md#sao-lưu-tệp-và-cơ-sở-dữ-liệu-bằng-restic).

Khi cần bỏ lịch sử restic, dùng `scripts/restic-clean.sh`: mặc định xóa toàn bộ
snapshot nhưng giữ kho và mật khẩu, `--repo` xóa cả thư mục kho, `--dry-run` chỉ
in ra sẽ làm gì. Cả hai chế độ xóa đều hỏi gõ `XOA` để xác nhận.

### Cron

Ofelia chạy `admin/cli/cron.php` mỗi phút bằng UID của tài khoản triển khai, với
`--keep-alive=0`, nên mỗi lần chạy kết thúc ngay sau khi xử lý task. Service
`cron` giới hạn 256 MB và tự khởi động lại nếu vượt giới hạn. Mọi job dùng múi
giờ `TZ` trong `.env`, mặc định `Asia/Ho_Chi_Minh`.

Ofelia không còn mount Docker socket. Nó gửi lệnh API tới `socket-proxy`
(CetusGuard) qua mạng riêng `socket_net`, và proxy chỉ cho exec bên trong
`moodle_web`. Tạo, khởi động hay xóa container đều bị trả `403`,
nên kẻ tấn công chiếm được scheduler cũng không lên được host. Proxy được kiểm
tra mỗi 30 giây qua `/_ping`, và Ofelia chờ healthcheck này trước khi khởi động.
Rủi ro còn lại và danh sách allowlist nằm trong
[NOTES.vi.md](NOTES.vi.md#scheduler-và-quyền-docker-api).

### Log

| Dịch vụ | Đường dẫn | Định dạng |
|---|---|---|
| Caddy | `logs/caddy/access.log` | JSON, xoay 100 MB, giữ 30 tệp trong 30 ngày |
| Apache | `logs/moodle/access-YYYY-MM-DD.log` | Tách theo ngày |
| PHP | `logs/php/error.log` | Lỗi; bản xoay vòng tách theo ngày |
| MySQL | `logs/mysql/error.log` | Chỉ log lỗi |
| Redis | `logs/redis/redis.log` | Mức notice |

`scripts/log-rotate.sh` chạy hằng ngày và giữ 30 ngày. `scripts/log-clean.sh`
dọn sạch mọi tệp log khi cần, giữ nguyên cây thư mục và truncate tệp còn đang mở
thay vì xóa. Log của Docker engine giới hạn 10 MB mỗi tệp, tối đa 3 tệp cho mỗi
container. Thời hạn giữ log trong Moodle và cách dọn dẹp có trong
[NOTES.vi.md](NOTES.vi.md#đĩa-và-log).

### Lệnh thường dùng

```bash
docker compose ps
docker compose logs -f moodle
docker compose restart moodle
docker compose down
docker compose up -d
```

Các quy trình khác — chạy offline bằng image, nhập gói ngôn ngữ tùy chỉnh, dọn
dẹp — nằm trong [NOTES.vi.md](NOTES.vi.md).

## TLS và tên miền

Trong `Caddyfile`, thay `:80` bằng tên miền:

```text
lms.example.vn {
```

Caddy tự xin và gia hạn chứng chỉ Let's Encrypt. Sau khi sửa Caddyfile, đặt địa
chỉ công khai và chế độ TLS trong `.env` rồi tạo lại container:

```bash
MOODLE_WWWROOT=https://lms.example.vn
MOODLE_SSLPROXY=true
docker compose up -d moodle
```

`MOODLE_SSLPROXY=true` là bắt buộc vì Caddy kết thúc TLS rồi chuyển tiếp HTTP
thường vào Apache. Sau đó thay URL trong cơ sở dữ liệu và xóa cache; không cần
sửa `config.php`.

## Bảo mật

- Chỉ mở cổng 22, 80 và 443. MySQL và Redis không mở ra Internet.
- Đăng nhập SSH bằng khóa, tắt xác thực mật khẩu và đăng nhập `root`.
- `.env` có quyền `600`; ba mật khẩu MySQL root, MySQL ứng dụng và Redis phải
  khác nhau.
- `config.php` đọc máy chủ, tên, tài khoản và mật khẩu cơ sở dữ liệu từ các biến
  `MOODLE_DB_*`, nên không có thông tin đăng nhập nào nằm trong tệp.
- Caddy gửi `Strict-Transport-Security` khi dùng HTTPS, đặt `Server: LMS-System`
  và thêm `Content-Security-Policy`, `X-Content-Type-Options`,
  `Referrer-Policy`, `Cross-Origin-Opener-Policy`, `Permissions-Policy`. Chính
  sách CSP chỉ cho `'self'` cộng các nguồn YouTube mà Moodle dùng. Apache bật
  `ServerTokens Prod` và `ServerSignature Off`.
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
