# Ghi chú: hiệu năng và xử lý sự cố

[English](NOTES.md) | **Tiếng Việt**

Tệp đi kèm [README.vi.md](README.vi.md). Không có mục nào bắt buộc để khởi động
hệ thống; đây là phần tính toán, tinh chỉnh, quy trình bảo trì và cách xử lý các
lỗi gặp trong vận hành.

## RAM và worker

### Cách entrypoint tính Apache

```text
MaxRequestWorkers = min(nproc * 16, (RAM_khả_dụng - dự_phòng) / 64 MB, 150)
```

Dự phòng 1,5 GB cho host 4 GB và 2 GB cho host 8 GB. Kết quả là số thread của
`mpm_event`, không phải số tiến trình:

```text
ThreadsPerChild = 10
ServerLimit     = ceil(worker / 10)   # làm tròn lên bội số 10
```

Vì vậy 40 worker là 4 tiến trình Apache, mỗi tiến trình 10 thread. Container có
`mem_limit` hoặc `cpus` đọc giới hạn cgroup thay vì dùng toàn bộ tài nguyên host.

Tham số PHP-FPM:

```text
pm.max_children      = 24               # PHP_FPM_MAX_CHILDREN, không vượt số worker Apache
pm.start_servers     = 2 * nproc
pm.min_spare_servers = nproc
pm.max_spare_servers = 4 * nproc
pm.max_requests      = 500
```

### Thành phần ngốn RAM

| Thành phần | Mức thường thấy | Ghi chú |
|---|---|---|
| Tiến trình PHP-FPM | 50 đến 90 MB mỗi tiến trình | Lớn nhất; mỗi tiến trình chạy cả Moodle |
| OPcache | khoảng 256 MB dùng chung | Một bản, mọi tiến trình chia sẻ |
| Apache | khoảng 150 đến 250 MB | Thread rất nhẹ, chỉ tiến trình tốn RAM |
| MySQL | 400 MB đến 1 GB | Phần lớn là `innodb_buffer_pool_size`, mặc định 128 MB |
| Redis | tối đa 256 MB | Chặn cứng bằng `allkeys-lru` |
| Hệ điều hành và Docker | khoảng 500 MB | Page cache có thể thu hồi |

Giới hạn thật nằm ở PHP-FPM: 24 tiến trình × 80 MB có thể lên khoảng 2 GB. Vì vậy
`PHP_FPM_MAX_CHILDREN` quan trọng hơn số thread Apache.

### Kiểm tra mức dùng thật

```bash
docker stats --no-stream
free -h
docker exec moodle_web ps -eo rss,args --sort=-rss | head -15
docker inspect -f '{{.State.OOMKilled}}' moodle_web
```

`rss` tính bằng KB. Chú ý các tiến trình `php-fpm: pool www` ở đầu; tiến trình
đầu tiên là master nên tốn ít hơn. Máy rảnh mà swap đã dùng vài MB nghĩa là số
worker đang quá cao.

### Triệu chứng và cách xử lý

| Triệu chứng | Nguyên nhân thường gặp | Cách xử lý |
|---|---|---|
| Thỉnh thoảng `502 Bad Gateway` | Tiến trình PHP-FPM bị kill hoặc crash | Giảm `PHP_FPM_MAX_CHILDREN`, kiểm tra `OOMKilled` |
| Một request treo rồi `504` | Request vượt `ProxyTimeout 900` | Không phải lỗi worker; xem task chạy quá lâu |
| Container tự khởi động lại, mã 137 | Bị OOM kill | Giảm số tiến trình hoặc thêm RAM |
| Site rất chậm, swap đang ghi đĩa | Cấp phát RAM quá tay | Giảm số tiến trình, sau đó thêm RAM |
| RAM cao nhưng site vẫn nhanh | OPcache và page cache | Bình thường, không cần chỉnh |

### Giá trị nên dùng

| Máy | `APACHE_MAX_REQUEST_WORKERS` | `PHP_FPM_MAX_CHILDREN` |
|---|---|---|
| 4 GB | 40 | 24 |
| 8 GB | 60 đến 80 | 40 |
| 16 GB trở lên | 120 đến 150 | 80 đến 100 |

Trên bản triển khai 4 GB này, entrypoint tính ra 40 / 24, đây là mức đã kiểm
chứng. Tăng từng nấc một và theo dõi `docker stats` trong một ngày.

## Tinh chỉnh MySQL

`db` khởi động với:

```text
--innodb-flush-log-at-trx-commit=2
--sync-binlog=0
```

Nhờ đó ghi hàng loạt không phải chờ `fsync` sau từng câu lệnh. Checkout gói ngôn
ngữ giảm từ khoảng 320 giây xuống 25 đến 37 giây. Đánh đổi: mất điện hoặc kernel
panic có thể mất tối đa một giây giao dịch vừa commit, dữ liệu vẫn phục hồi về
trạng thái nhất quán.

Muốn quay lại, bỏ hai tham số khỏi khối `command:` trong `docker-compose.yml` rồi
chạy `docker compose up -d db`. Kiểm tra lúc chạy:

```sql
SHOW VARIABLES LIKE 'innodb_flush_log_at_trx_commit';
SHOW VARIABLES LIKE 'sync_binlog';
```

Khi cần tìm truy vấn chậm, thêm tạm vào cùng khối `command:`:

```text
--slow-query-log=1 --slow-query-log-file=/var/log/mysql/slow.log --long-query-time=2
```

Log ghi vào `logs/mysql/slow.log`. Xong thì bỏ các tham số này; chúng tạo thêm I/O
cho mọi truy vấn vượt ngưỡng.

### Buffer pool theo tải

| Người dùng đồng thời | `innodb_buffer_pool_size` |
|---|---|
| đến 100 | 2 GB |
| khoảng 1000 | 16 đến 24 GB |

Đặt trong khối `command:` của `db` rồi khởi động lại container. Buffer pool nên
chứa được working set; cơ sở dữ liệu ở đây chỉ khoảng 44 MB nên 2 GB đã rất rộng.

## Cache phía trình duyệt và nén

Hai thiết lập quyết định việc trình duyệt có phải tải lại tài nguyên mỗi lần
chuyển trang hay không. Bản thân máy chủ vốn nhanh: trang chủ trả lời trong 80
đến 100 ms, trang đăng nhập 37 đến 51 ms. Cảm giác chậm khi chuyển trang đến từ
phía trình duyệt.

### Cache JavaScript

`moodle/config.php` đặt:

```php
$CFG->cachejs = true;
```

Nên giữ thiết lập này trong `config.php` thay vì trong cơ sở dữ liệu. Moodle ép
giá trị từ đó, và `admin/cli/cfg.php` từ chối thay đổi với thông báo
`The configuration variable $CFG->cachejs is set in config.php, unable to change.`
Trang quản trị cũng hiển thị thiết lập này ở trạng thái bị ép. Lợi ích là giá trị
vẫn còn sau khi phục hồi cơ sở dữ liệu.

Khi tắt cache, mọi URL tài nguyên chứa `-1` và header `Expires` chỉ hơn thời điểm
hiện tại hai giây, nên mỗi lần chuyển trang phải kiểm tra lại khoảng 76 tệp
JavaScript và ESM. Khi bật cache, URL mang revision của Moodle, tệp được gửi ở
dạng đã thu gọn, và header là:

| Tài nguyên | Header |
|---|---|
| `/lib/javascript.php/<rev>/...` | `Cache-Control: public, max-age=7776000, immutable` |
| `/core/esm/<rev>/...` | `Cache-Control: public, max-age=31536000, immutable` |

Sau khi đổi thiết lập, purge cache rồi khởi động lại container web:

```bash
docker compose exec -u www-data moodle php admin/cli/purge_caches.php
docker compose restart moodle
```

Bắt buộc phải khởi động lại. OPcache chạy với `opcache.validate_timestamps=0` nên
`config.php` vừa sửa bị bỏ qua cho tới khi PHP khởi động lại.

Đo trên máy này bằng trình duyệt:

| Chỉ số | Cache nguội | Cache ấm |
|---|---|---|
| DOMContentLoaded, trang chủ | 8,4 giây | 0,44 giây |
| Tài nguyên lấy từ cache trình duyệt | 0 trên 68 | 46 trên 46 |
| Dung lượng tài nguyên phải tải | khoảng 1,0 MB | 0 byte |
| DOMContentLoaded, trang khóa học | không áp dụng | 0,37 giây |
| DOMContentLoaded, trang đăng nhập | không áp dụng | 0,31 giây |

Trước khi đổi, mọi lần chuyển trang đều giống cột cache nguội. Lần tải đầu sau
khi purge vẫn nặng, vì Moodle gửi một gói `core/first.js` lớn; các lần sau lấy
lại từ cache trình duyệt.

### Nén phản hồi

`Caddyfile` nén phản hồi từ proxy:

```text
encode gzip
```

Chọn `gzip` có chủ đích. Bản Caddy này nén được tệp tĩnh bằng `zstd`, nhưng không
áp `zstd` cho HTML đi qua proxy, và với những tệp nó xử lý thì `zstd` lại cho kết
quả lớn hơn `gzip` (588 so với 543 byte với `slick.css`, 5553 so với 4557 với
`animate.css`). Với `gzip`, trang chủ giảm từ 93,5 KB xuống 14,3 KB, trang đăng
nhập từ 45 KB xuống khoảng 10 KB.

Apache đã nén CSS và JavaScript bằng `gzip`, nên Caddy chuyển tiếp nguyên trạng
thay vì nén hai lần.

## Header bảo mật

`Caddyfile` đặt header cho mọi trang: `Server`, `X-Content-Type-Options`,
`Referrer-Policy`, `Cross-Origin-Opener-Policy`, `Permissions-Policy` và
`Content-Security-Policy`. Hệ thống tự nhận là `LMS-System`. Chính sách chỉ dùng
`'self'` cho bản thân hệ thống, nên chạy được trên bất kỳ domain hay cổng nào mà
không phải sửa.

YouTube là nguồn ngoài duy nhất được phép. Trình phát videojs nạp
`https://www.youtube.com/iframe_api` dưới dạng script, hiện ảnh poster từ
`https://img.youtube.com`, và nhúng trình phát từ `youtube-nocookie.com` hoặc
`youtube.com`. Mọi nguồn khác bị chặn: Vimeo, Google Drive và ảnh ngoài trong nội
dung khóa học đều không tải được. Theme không nạp Google Fonts, nên
`fonts.googleapis.com` và `fonts.gstatic.com` không có trong chính sách.

`script-src` vẫn cần `'unsafe-inline'` và `'unsafe-eval'`. Moodle in script nội
tuyến trên mọi trang và TinyMCE gọi `new Function`, nên không thể dùng nonce nếu
không sửa core.

Muốn kiểm tra sau khi đổi, đặt một trang tạm trong webroot rồi xóa đi:

```html
<img src="https://example.com/logo.png">
<img src="https://img.youtube.com/vi/ID/0.jpg">
```

Ảnh thứ nhất phải bị chặn, ảnh thứ hai phải tải được. Console trình duyệt ghi rõ
từng tài nguyên bị chặn kèm directive đã từ chối nó.

## Quy mô theo tải

| Hạng mục | Khoảng 100 người dùng đồng thời | Khoảng 1000 người dùng đồng thời |
|---|---|---|
| Hệ điều hành | Ubuntu 26.04 LTS | Ubuntu 26.04 LTS |
| Docker | Engine 24 kèm Compose v2 | Engine 24 kèm Compose v2 |
| CPU / RAM | 4 vCPU / 8 GB | 16 vCPU / 64 GB |
| Ổ đĩa | 100 GB | 500 GB |
| Mô hình | Một máy chủ | Một máy chủ lớn, hoặc tách web và cơ sở dữ liệu |

| Tham số | 100 người dùng | 1000 người dùng | Vị trí |
|---|---|---|---|
| `innodb_buffer_pool_size` | 2 GB | 16 đến 24 GB | `command:` của `db` |
| Redis `maxmemory` | 256 đến 512 MB | 2 GB | `command:` của `redis` |
| `opcache.memory_consumption` | 256 MB | 512 MB | `php/Dockerfile` |
| Apache `MaxRequestWorkers` (thread) | tự động 32–64 | 300 đến 500 | `APACHE_MAX_REQUEST_WORKERS` |
| PHP-FPM `pm.max_children` | 24 (mặc định) | 300 đến 500 | `PHP_FPM_MAX_CHILDREN` |

Khi vượt một máy chủ, tách MySQL sang máy riêng bằng cách đổi host cơ sở dữ liệu,
sau đó nhân bản container `moodle` phía sau bộ cân bằng tải.

## Quy trình

### Chạy offline bằng image

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
MySQL; phải sao chép các phần đó riêng. Dữ liệu MySQL nằm trong volume
`moodle_db_data`, và `backup/restic` có sẵn một bản dump gần nhất. Tên image
đã cố định là `moodle-web:5.3`, `moodle-caddy:2.11` và
`moodle-cetusguard:v1` nên thư mục dự án có thể đặt tên bất kỳ.

### Sao lưu cả thư mục triển khai ra tệp tar

`backup/restic` do restic chạy bằng root tạo ra, và một lần `docker exec` thủ
công có thể để lại tệp root trong `moodledata`, nên tar chạy bằng tài khoản đăng
nhập sẽ dừng với `Cannot open: Permission denied`. Kiểm tra trước rồi sửa:

```bash
bash scripts/fix-perms.sh --check
bash scripts/fix-perms.sh
```

```bash
cd ~/moodle
sudo tar -czf /home/ubuntu/moodle_move.tar.gz \
  --exclude=./logs \
  --exclude=./backup/images \
  --exclude=./moodledata/sessions \
  --exclude=./moodledata/cache \
  --exclude=./moodledata/localcache \
  --exclude=./moodledata/temp \
  --exclude=./moodledata/muc \
  .
sudo chown "$USER:$USER" /home/ubuntu/moodle_move.tar.gz
chmod 600 /home/ubuntu/moodle_move.tar.gz
```

Giữ `./backup/restic` trong tệp nén. Dữ liệu MySQL nằm trong volume
`moodle-server_moodle_db_data` chứ không nằm trong thư mục, nên kho restic là
bản sao database duy nhất mà tệp tar mang theo. Bỏ `./backup/images` tiết kiệm
khoảng 640 MB; chỉ cần giữ lại khi máy mới không có mạng. Tệp nén chứa `.env`
với mật khẩu database và restic, nên để quyền `600` và không tải lên nơi công khai.

### Thử PHP 8.6

Đã thử ngày 2026-11-20. `php:8.6-fpm` có sẵn và Moodle 5.3 chạy được trên đó,
nhưng image chưa khởi động được:

- `phpredis` 6.3.0 không biên dịch được. `zval_dtor`, `XtOffsetOf`,
  `php_hash_bin2hex` và `ZEND_WRONG_PARAM_COUNT` đã bị gỡ khỏi PHP 8.6; chỉ
  master build được, nên Dockerfile phải ghim commit `a6ce1e6`.
- `composer.lock` của Moodle ghim `ezyang/htmlpurifier`, `lcobucci/jwt`,
  `league/oauth2-server`, `openspout/openspout` và `slim/slim`, tất cả giới hạn
  `~8.5.0`. Entrypoint chạy `composer install` lúc khởi động nên container
  restart liên tục trước khi Apache lên.

Bản thân mã PHP không lỗi: khi bỏ bước composer, cron, `purge_caches.php` và
`check_database_schema.php` đều chạy qua trên 8.6.

Để quay lại, khôi phục `php/Dockerfile` rồi chạy `docker compose up -d --no-build`
khi image cũ còn trên máy, hoặc nạp lại `backup/images/` như trên. Thử lại khi
bản Moodle mới cho phép 8.6 trong lock file và phpredis phát hành tag biên dịch
được trên 8.6.

### Gói ngôn ngữ tùy chỉnh

Mở thẳng `/admin/tool/customlang/import.php?lng=vi` để vào form nhập ZIP. Mục
Import trên menu chạy checkout trước, với gói lớn có thể mất vài phút.

- PHP-FPM `request_terminate_timeout` và Apache `ProxyTimeout` đều là 900 giây,
  đủ để một request chạy xong.
- Mỗi tab đang mở đều có thể khởi động một lần checkout; chỉ mở một tab.
- Trên máy tham chiếu, nhập gói `vi` mất khoảng 60 giây và checkin khoảng 5 giây.
- Kiểm tra không còn bản ghi chưa lưu:

```sql
SELECT COUNT(*) FROM mdl_tool_customlang WHERE modified = 1;
```

Bằng 0 nghĩa là đã nhập và checkin xong.

### .htaccess của webroot

`moodle/public/.htaccess` bật router `r.php`, chặn schema và thư mục phát triển.
Gói Moodle mới có thể ghi đè tệp này. Khôi phục:

```bash
git checkout -- moodle/public/.htaccess
install -m 644 moodle/public/.htaccess /duong-dan/moodle/public/.htaccess
docker exec moodle_web apache2ctl -t
```

Kết quả mong đợi sau khi thay:

| URL | Mã |
|---|---|
| `/install.xml` | 403 |
| `/lib/db/install.xml` | 403 |
| `/theme/boost/style/moodle.css` | 200 |
| `/login/index.php` | 200 |

### Sao lưu tệp và cơ sở dữ liệu bằng restic

Hai loại dữ liệu phải đi cùng nhau: bản ghi trong MySQL và tệp trong
`moodledata`. Một job chạy mỗi đêm nay chụp cả hai thành hai snapshot restic mang
tag `db` và `files`, nên từng phần phục hồi riêng được và có chính sách lưu trữ
riêng. Ofelia chạy `nice -n 19 sh /scripts/restic-job.sh` trong `moodle_web` lúc
00:00 (`Asia/Ho_Chi_Minh`).

Theo thứ tự, job làm như sau:

1. Khởi tạo `backup/restic` nếu kho chưa có.
2. Dump cơ sở dữ liệu Moodle ra `/backup/dbdump/moodle.sql` bằng
   `mysqldump --single-transaction --quick --skip-lock-tables`, kết nối tới
   `db` bằng tài khoản Moodle. Image PHP cài sẵn `default-mysql-client`; tệp
   dump có quyền `600`.
3. Dừng nếu dump rỗng hoặc không có `CREATE TABLE`, trước khi chạm vào kho, nên
   các snapshot cũ vẫn còn nguyên.
4. Sao lưu bản dump thành một snapshot với host `moodle` và tag `db`.
5. Sao lưu `/var/www/moodledata` thành snapshot thứ hai với host `moodle` và tag
   `files`, loại trừ `cache`, `localcache`, `temp`, `sessions`, `muc`,
   `environment`, `antivirus_quarantine` và `trashdir`. Tất cả đều tái tạo được
   hoặc dùng xong có thể bỏ.
6. Xóa tệp SQL gốc ngay khi restic xong, nên `backup/` không bao giờ giữ bản
   không mã hóa.
7. Dọn snapshot cũ rồi prune: `--tag db --keep-last 2` và
   `--tag files --keep-daily 7`, sau đó một lần `restic prune` để thật sự giải
   phóng các khối không còn snapshot nào dùng.
8. Trả lại quyền sở hữu kho cho tài khoản host. Job chạy bằng root nên kết thúc
   bằng `chown -R "${PUID}:${PGID}"` trên `backup/restic`, kể cả khi lỗi. Root
   vẫn đọc ghi bình thường; tài khoản host có thể tar hoặc copy thư mục mà không
   cần `sudo`.

Hai snapshot thay vì một chính là điều kiện để giới hạn 2 bản DB: một snapshot gộp
chỉ có thể giữ hoặc bỏ cả cụm, nên giữ 2 bản sẽ mất luôn phần tệp. Hai snapshot
cách nhau khoảng hai giây, nên chúng mô tả gần như cùng một thời điểm.

`--single-transaction` cho một ảnh chụp InnoDB nhất quán trong khi site vẫn
chạy. Tệp được đọc sau đó vài giây, nên một tệp tải lên giữa hai bước có thể mới
hơn bản ghi trỏ tới nó; tệp thừa không ảnh hưởng. Tệp bị xóa đúng trong khoảng
ngắn đó là điểm lệch nhỏ duy nhất phải chấp nhận.

Vì sao không copy thẳng volume MySQL bằng restic? InnoDB trải dữ liệu trên
tablespace, redo log và undo log; copy các tệp đó khi server đang chạy có thể ra
một bộ hỏng. Dump là cách được hỗ trợ để lấy bản nhất quán tại một thời điểm.

Restic chia dữ liệu thành từng khối, lưu mỗi khối một lần và nén lại, nên dung
lượng tự nó tăng chậm: `filedir` đặt tên tệp theo hash nội dung, và một bản dump
22 MB ít thay đổi chỉ thêm 8,7 MB dữ liệu đầu vào nhưng chỉ 1,0 MB được lưu trong
lần thử. Bản dump vẫn là một bản đầy đủ của cơ sở dữ liệu nằm trong snapshot, nên
lịch sử `db` bị giới hạn ở 2 thay vì 7. Job dùng client MariaDB có sẵn trên
Debian để nói chuyện với MySQL 9.7; bản dump phục hồi lại đúng server với đủ 499
bảng và cùng `mdl_config.version`.

Bước dọn chạy sau backup, và `set -e` dừng script nếu dump hoặc backup lỗi, nên
một lần chạy hỏng không bao giờ xóa các bản tốt cuối cùng. Restic giữ thêm
snapshot cũ nhất khi kho chưa đủ 7 ngày `files`; sau một tuần số bản ổn định đúng
bằng 7, còn `db` ổn định ở 2. Snapshot mang tag `full` của cách làm cũ không khớp
chính sách nào; xóa bản cuối bằng `restic forget <id> --prune`. Bản ngoài máy chủ
là việc còn lại trong
[LIMITATIONS.vi.md](LIMITATIONS.vi.md#sửa-3-dọn-và-đưa-backup-ra-khỏi-máy-chủ).

Chạy backup bằng tay từ host, cùng luồng mà Ofelia dùng:

```bash
bash scripts/restic-backup.sh                 # backup ngay, rồi in 3 snapshot và dung lượng kho
docker exec moodle_web restic snapshots
docker exec moodle_web restic ls latest --tag db /backup/dbdump
docker exec moodle_web restic stats --mode restore-size
docker exec moodle_web restic check --read-data-subset=5%
```

`scripts/restic-backup.sh` kiểm tra `moodle_web` đang chạy rồi gọi
`sh /scripts/restic-job.sh` trong container, nơi có restic, `mysqldump`,
`/backup/restic` và `/var/www/moodledata`. Wrapper này để chạy tay không phải nhớ
lệnh `docker exec` dài, và để lịch tự động với chạy tay dùng chung một đoạn mã.

### Dọn kho restic

`scripts/restic-clean.sh` xóa lịch sử backup có chủ đích; không dùng trong vận
hành bình thường. Mặc định script chạy
`restic forget --keep-last 0 --prune --unsafe-allow-remove-all`, xóa mọi snapshot
của host `moodle` — cả dump cơ sở dữ liệu lẫn tệp — nhưng giữ kho và mật khẩu
trong `.env`. `--repo` xóa luôn thư mục `backup/restic`, nên lần backup sau sẽ
khởi tạo kho mới. `--dry-run` chỉ in ra sẽ xóa gì.

```bash
bash scripts/restic-clean.sh --dry-run        # xem snapshot nao se bi xoa
bash scripts/restic-clean.sh                  # xoa snapshot, giu kho
bash scripts/restic-clean.sh --repo --dry-run # xem dung luong kho truoc khi xoa
bash scripts/restic-clean.sh --repo           # xoa ca backup/restic
```

Cả hai chế độ xóa đều hỏi gõ `XOA`. `--repo` chạy `rm -rf` bằng root trong
container, nên tệp do root tạo biến mất mà không cần `sudo`; nếu container đang
tắt, script lùi về `sudo rm -rf`. Sau khi dọn mặc định, kho còn vài tệp nhưng vẫn
hợp lệ, và lần backup sau ghi lại toàn bộ cây.

Prune phải ghi lại các pack, nên cần chỗ trống và chạy lâu hơn khi kho lớn dần.
Nếu nó lỗi vì đầy ổ, snapshot vẫn nguyên; giải phóng chỗ rồi chạy lại bước dọn:

```bash
docker exec moodle_web restic forget --host moodle --group-by host --tag db --keep-last 2
docker exec moodle_web restic forget --host moodle --group-by host --tag files --keep-daily 7
docker exec moodle_web restic prune
```

### Phục hồi cơ sở dữ liệu và tệp

`scripts/restic-restore.sh` chạy trên host và mặc định phục hồi cả hai phần.
`--db` chỉ phục hồi dump cơ sở dữ liệu, `--files` chỉ phục hồi `moodledata`, và
có thể dùng cả hai cờ cùng lúc.

Mặc định là phục hồi ra thư mục tạm: ghi vào `backup/restore_<thời-gian>`, đổi chủ
sở hữu để tài khoản triển khai đọc được, rồi in số tệp của bản phục hồi bên cạnh số
tệp đang dùng. Với cơ sở dữ liệu, script in đường dẫn dump và lệnh import. Không
đụng gì trong `moodledata/` hay cơ sở dữ liệu đang chạy.

```bash
docker exec moodle_web restic snapshots          # tìm ID cần dùng
bash scripts/restic-restore.sh                   # bản mới nhất, DB + tệp
bash scripts/restic-restore.sh --db              # chỉ dump cơ sở dữ liệu
bash scripts/restic-restore.sh --files           # chỉ moodledata
bash scripts/restic-restore.sh 9711dea3 --db     # một bản cụ thể, chỉ DB
```

Dump nằm tại `backup/restore_<thời-gian>/backup/dbdump/moodle.sql`. Đây là tệp SQL
không mã hóa, nên xóa thư mục tạm sau khi diễn tập hoặc phục hồi xong.

`--in-place` là phục hồi thật: hỏi xác nhận, dừng `moodle` và `cron`, import dump
và/hoặc chép tệp, khởi động lại, chờ health check và xóa cache.

```bash
bash scripts/restic-restore.sh --db --in-place     # chỉ cơ sở dữ liệu
bash scripts/restic-restore.sh --files --in-place  # chỉ tệp
bash scripts/restic-restore.sh --in-place          # cả hai
```

Bước import dùng tài khoản `root` trong `moodle_db`, nên vẫn chạy được khi cơ sở
dữ liệu đích hoặc quyền của tài khoản Moodle khác với dự kiến. Dump có
`DROP TABLE IF EXISTS` cho từng bảng đã chụp, nên mỗi bảng được thay đúng; bảng
chỉ có trong cơ sở dữ liệu đang chạy được giữ nguyên và Moodle bỏ qua. Script
cũng bỏ dòng `SET @@GLOBAL.GTID_PURGED` còn sót trước khi import, nên dump cũ vẫn
nạp được.

`--db` là lý do `moodle_db` không còn mount `/backup` hay `./scripts`, và Ofelia
không còn quyền exec trên container đó: lệnh import chạy từ host qua stdin.

Bản tạm được giữ lại có chủ đích, nên chỉ xóa `backup/restore_<thời-gian>` sau khi
đã kiểm tra site. Phục hồi chỉ chép tệp từ snapshot, không xóa tệp chỉ có trên đĩa;
những tệp đó thành mồ côi và Moodle bỏ qua. Tệp chép sang giữ UID của container nên
quyền vẫn đúng; nếu script cảnh báo chủ sở hữu khác, chạy `bash scripts/fix-perms.sh`.

Hai chi tiết dễ làm mất thời gian:

- Kho do `root` trong container ghi, nên đọc bằng `docker exec` hoặc `sudo` từ
  host.
- Nếu một lệnh restic bị ngắt giữa chừng (ví dụ pipe vào `head`), nó để lại lock
  và lần sau báo "repository is already locked". Chỉ gỡ khi không có backup nào
  đang chạy:

```bash
docker exec moodle_web restic unlock --remove-all
```

`RESTIC_PASSWORD` nằm trong `.env` và được truyền vào container. Không có nó thì
không mở được kho, nên phải giữ một bản ngoài máy chủ. Khi muốn chuyển kho đi nơi
khác, đặt `RESTIC_REPOSITORY` trong `.env` thành đích `s3:`, `rclone:` hoặc
`sftp:` rồi chạy `restic init` ở đó một lần.

### Xuất dump ra tệp SQL rời

`scripts/restic-export.sh` là đường thủ công. Script phục hồi snapshot `db` mới
nhất trong container, chép `moodle.sql` ra host bằng `docker exec cat`, rồi xóa
bản trong container. Mặc định ghi ra ngoài thư mục triển khai,
`~/moodle-dump_<thời-gian>.sql`, quyền `600`.

```bash
bash scripts/restic-export.sh                           # snapshot db mới nhất -> ~/moodle-dump_<thời-gian>.sql
bash scripts/restic-export.sh --out=/media/usb/moodle.sql
bash scripts/restic-export.sh 9711dea3 --out=~/old.sql  # một snapshot cụ thể
```

Kết quả là SQL thuần, client MySQL hay MariaDB nào cũng import được, và là cách
nhanh nhất để đưa bản sao cho người không có mật khẩu restic. Chuyển đi rồi xóa:
một cơ sở dữ liệu không mã hóa trên đĩa chính là thứ cách làm restic này tránh.

### Đổi RESTIC_PASSWORD

Mật khẩu mã hóa khóa của kho, nên chỉ sửa `RESTIC_PASSWORD` trong `.env` là các
snapshot cũ không còn đọc được. Có hai hướng.

Giữ snapshot và chỉ đổi mật khẩu, cần mật khẩu cũ một lần:

```bash
docker exec -it moodle_web restic key passwd
```

Sau đó ghi mật khẩu mới vào `.env` và tạo lại container để nó nhận giá trị:

```bash
docker compose up -d moodle
docker exec moodle_web restic snapshots
```

Làm lại từ đầu, phù hợp khi mất mật khẩu cũ hoặc không muốn giữ lịch sử:

```bash
# sửa RESTIC_PASSWORD trong .env trước
docker compose up -d moodle
mv backup/restic backup/restic-old     # tùy chọn, chỉ khi còn cần snapshot cũ
bash scripts/restic-clean.sh --repo    # xóa backup/restic, hỏi XOA
bash scripts/restic-backup.sh          # tạo kho mới và chụp bản đầu
docker exec moodle_web restic snapshots
docker exec moodle_web restic check
```

Kho cũ không mở được bằng mật khẩu mới, nên chép nó sang chỗ khác trước khi xóa
nếu còn giá trị. Chỉ `moodle_web` chạy restic và nó đọc giá trị từ `.env`, nên
không cần sửa chỗ nào khác.

### Scheduler và quyền Docker API

Ofelia chạy bằng tệp cấu hình, không dùng nhãn container:

```text
ofelia/config.ini   job và lịch
ofelia/rules.list   allowlist của CetusGuard
command: daemon --config=/etc/ofelia/config.ini
```

Nhãn đã được bỏ khỏi `db` và `moodle`. Chế độ nhãn cần `GET /containers/json`,
`GET /containers/{id}/json` và luồng sự kiện, tức là lộ biến môi trường của mọi
container trên host, kể cả `MYSQL_ROOT_PASSWORD` và `RESTIC_PASSWORD`. Chế độ
tệp chỉ cần `GET /_ping`, `GET /info` và các lệnh exec mà ba job thực sự gọi.

Chỉ `socket-proxy` mount `/var/run/docker.sock` ở dạng chỉ đọc. Ofelia gọi
`tcp://socket-proxy:2375` qua `socket_net`, mạng bridge đặt `internal: true`:
không mở cổng, không có đường ra ngoài Docker, và chỉ hai service này tham gia.

Image proxy được build tại chỗ từ `./cetusguard`, dựa trên
`hectorm/cetusguard:v1`. Image gốc là `scratch`, không có HTTP client;
Dockerfile chỉ copy thêm busybox tĩnh cho healthcheck. Healthcheck gọi
`GET /_ping` mỗi 30 giây, và `cron` chờ `service_healthy` rồi mới khởi động. Vì
là image build, nó không nằm trong `docker compose pull`;
`docker compose up -d --build` sẽ build nó.

`/_ping`, `/version`, `/info` do rule dựng sẵn của CetusGuard cho phép; phần còn
lại nằm trong `ofelia/rules.list`:

```text
POST %API_PREFIX%/containers/moodle_web/exec
POST %API_PREFIX%/exec/%CONTAINER_ID%/start
GET  %API_PREFIX%/exec/%CONTAINER_ID%/json
```

`POST /exec/{id}/start` nâng kết nối lên HTTP 101 để đọc output; CetusGuard xử
lý hijack. Đổi tên container trong `docker-compose.yml` thì phải đổi ở cả
`ofelia/config.ini` và `ofelia/rules.list`.

Những gì proxy từ chối, đo trên hệ thống đang chạy:

| Request | Kết quả |
|---|---|
| `GET /v1.51/info` | 200 |
| `GET /v1.51/containers/json` | 403 |
| `POST /v1.51/containers/create` | 403 |
| `POST /v1.51/containers/moodle_web/start` | 403 |
| `DELETE /v1.51/containers/moodle_web` | 403 |
| `POST /v1.51/containers/moodle_redis/exec` | 403 |
| `POST /v1.51/containers/moodle_web/exec` | 201 |
| `POST /v1.51/containers/moodle_db/exec` | 403 |

403 ở `containers/create` là điểm quan trọng nhất: với cấu hình proxy phổ biến
`CONTAINERS=1` + `POST=1`, lệnh đó được phép, và một container privileged mount
`/` biến quyền API thành root host.

**Rủi ro còn lại.** Ofelia vẫn quyết định *chạy gì* bên trong `moodle_web`.
Scheduler bị chiếm vẫn chạy được lệnh root trong đó, đọc `config.php`,
`MYSQL_ROOT_PASSWORD`, `RESTIC_PASSWORD`, sửa website và xóa kho restic. Thông tin
đăng nhập cơ sở dữ liệu cũng cho phép nó sửa dữ liệu qua mạng nội bộ, dù proxy
không còn cho exec trên `moodle_db`. Nó không tạo, khởi động, dừng hay xóa
container, không đọc image/volume/network, không chạm được filesystem host. Muốn
bỏ nốt rủi ro này thì phải bỏ scheduler, không phải siết proxy thêm.

Hai lưu ý vận hành:

- CetusGuard dùng image `scratch`, không có zoneinfo, nên log của chính nó theo
  UTC. Job vẫn do Ofelia lập lịch theo `Asia/Ho_Chi_Minh`.
- `socket_net` là ranh giới tin cậy. Không gắn container khác vào; container ở
  đó dùng được cùng allowlist.

Test tay một rule bằng client tạm nối vào `socket_net`:

```bash
docker run --rm --network moodle-server_socket_net curlimages/curl:8.11.1 \
  -s -o /dev/null -w '%{http_code}\n' \
  -X POST -H 'Content-Type: application/json' -d '{}' \
  http://socket-proxy:2375/v1.51/containers/create
```

Kết quả phải là `403`.

### Định dạng lịch của Ofelia

Ofelia 0.3.x, ghim ở `mcuadros/ofelia:0.3`, vẫn bắt buộc trường giây ở đầu:
`0 0 3 * * *` là 03:00:00, còn `0 3 * * *` là mỗi giờ vào phút 3. Dạng năm
trường trông hợp lệ và không báo lỗi, nên một job hằng ngày âm thầm thành mỗi
giờ một lần.

```text
0 0 0 * * *   dump cơ sở dữ liệu  (00:00)
0 0 0 * * *   xoay log            (00:00)
0 0 0 * * *   sao lưu tệp         (00:00)
@every 1m     cron moodle
```

Mọi mốc theo `Asia/Ho_Chi_Minh` vì mọi container nhận `TZ` từ `.env`. Đổi `TZ`
thì lịch cũng dịch theo. Ba job hằng ngày dùng chung mốc 00:00, nên bản dump và
bản sao tệp ứng với cùng một thời điểm.

Kiểm tra lịch đã đăng ký thật:

```bash
docker logs moodle_cron_scheduler 2>&1 | grep 'New job registered'
```

Mỗi dòng in kèm lịch, nên thấy `0 19 * * *` trong đó là đúng lỗi này.

## Xử lý sự cố

### 502 Bad Gateway

PHP-FPM đã dừng hoặc bị kill tiến trình.

```bash
docker compose ps
docker logs --tail 50 moodle_web
docker inspect -f '{{.State.OOMKilled}}' moodle_web
```

Nếu bị OOM kill, giảm `PHP_FPM_MAX_CHILDREN` trong `.env` rồi chạy
`docker compose up -d moodle`.

### 504 sau một request dài

`ProxyTimeout` là 900 giây. Lỗi 504 nghĩa là bản thân task chạy lâu hơn, không
phải hết worker. Xem log Apache và PHP, và chạy các tác vụ dài bằng CLI thay vì
trên trình duyệt.

### Container báo unhealthy

`docker compose ps` hiện `(unhealthy)` khi healthcheck lỗi. Healthcheck của
`moodle` gọi `/` và dự phòng `/install.php`, có `start_period` 120 giây và 5 lần
thử, nên một lần khởi động lại hoặc bảo trì ngắn không làm nó chuyển sang lỗi.
Caddy chỉ khởi động khi `moodle` báo khỏe.

Chạy thử tay khi vẫn unhealthy:

```bash
docker exec moodle_web curl -fsS -o /dev/null -w '%{http_code}\n' http://127.0.0.1/
docker inspect -f '{{json .State.Health}}' moodle_web
docker logs --tail 50 moodle_web
```

Bản cũ dùng `/login/index.php`. Trang này trả lỗi khi Moodle đang bảo trì hoặc
đang ở màn hình nâng cấp sau khi cập nhật phiên bản, nên container bị đánh dấu
unhealthy trong lúc nâng cấp. Chờ nâng cấp xong thay vì ép khởi động lại giữa
chừng.

### Tệp thuộc root

Triệu chứng: Moodle báo không ghi được cache, `tar` dừng với
`Cannot open: Permission denied` trên `backup/restic`, hoặc tệp mới trong
`moodle/` thuộc `root`. Nguyên nhân: chạy `docker exec` mà thiếu `-u www-data`,
và job restic chạy bằng root bên trong container.

```bash
bash scripts/fix-perms.sh --check   # liet ke muc tai khoan host khong doc duoc
bash scripts/fix-perms.sh           # sua roi bao cao lai
docker exec -u www-data moodle_web php /var/www/html/admin/cli/purge_caches.php
```

Script gọi `sudo`; khi chạy bằng root thì chỉ rõ chủ sở hữu:
`bash scripts/fix-perms.sh --user ubuntu`. Script giao `moodle`, `moodledata` và
`backup` (gồm cả kho restic) cho tài khoản host, giữ `logs/mysql` và `logs/redis`
thuộc container và chỉ thêm quyền đọc cho nhóm, đồng thời bỏ quyền ghi cho
`other` ở những tệp nó chạm tới. `--check` trả mã lỗi khi còn tệp không đọc được,
nên dùng được như bước chặn trước khi tar hoặc backup.

Job restic đã tự chown kho ở cuối mỗi lần chạy, nên trường hợp tar chỉ còn sau
một lần chạy tay bằng root. Khi đó chạy `bash scripts/fix-perms.sh` một lần.

### 403 với install.xml là đúng

Quy tắc webroot cố ý chặn `install.xml`, `environment.xml`, `roles_schema.xml`,
`*.schema.json` và các thư mục `lib/db`, `lib/tests`, `lib/phpunit`. 403 ở đó là
kết quả đúng. Cần đọc một trong các tệp đó để gỡ lỗi thì đọc bên trong container.

### Vòng lặp đăng nhập hoặc mất session

Session nằm trong Redis. Kiểm tra:

```bash
docker exec moodle_redis sh -c 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli ping'
docker compose restart redis
```

Redis khởi động lại thì người dùng bị đăng xuất một lần. Đồng thời kiểm tra cấu
hình cache vẫn trỏ tới `redis` trong **Plugins → Caching**.

### Liên kết và cookie trỏ về localhost

`config.php` lấy địa chỉ site từ `MOODLE_WWWROOT`, nên giá trị sai sẽ hiện thành
liên kết về `localhost`, chuyển hướng lỗi và cookie gắn sai máy chủ. Entrypoint
cảnh báo lúc khởi động khi `APP_ENV=production` mà địa chỉ vẫn là `localhost`
hoặc `127.0.0.1`:

```text
[canh bao] MOODLE_WWWROOT=http://localhost trong moi truong production: ...
```

Đặt địa chỉ thật trong `.env`, tạo lại container, rồi thay các URL đã lưu trong
cơ sở dữ liệu:

```bash
MOODLE_WWWROOT=https://lms.example.vn
MOODLE_SSLPROXY=true
docker compose up -d moodle
```

Nếu Caddy kết thúc TLS thì bắt buộc `MOODLE_SSLPROXY=true`; thiếu nó Moodle sinh
liên kết `http://` và có thể lặp chuyển hướng. Có thêm cảnh báo thứ hai khi
`MOODLE_SSLPROXY=true` nhưng `MOODLE_WWWROOT` không bắt đầu bằng `https://`.

### Site lỗi sau khi nâng cấp

```bash
docker exec -u www-data moodle_web php /var/www/html/admin/cli/maintenance.php --enable
docker exec -u www-data moodle_web php /var/www/html/admin/cli/upgrade.php --non-interactive
docker exec -u www-data moodle_web php /var/www/html/admin/cli/purge_caches.php
docker exec -u www-data moodle_web php /var/www/html/admin/cli/maintenance.php --disable
```

`config.php` và `moodle/public/.htaccess` đang được theo dõi trong git; giữ cả
hai khi giải nén mã nguồn mới. Sao lưu cơ sở dữ liệu trước khi nâng cấp.

### Đĩa và log

```bash
docker system df
du -sh moodledata/* backup logs 2>/dev/null
```

- Moodle giữ log hoạt động 180 ngày (`logstore_standard / retentiondays`); task
  dọn dẹp chạy hằng ngày. Có thể xóa tay các dòng cũ, nhưng không đụng vào
  `config_log`, `upgrade_log` hay `tool_customlang`.
- `scripts/log-rotate.sh` giữ log Apache, PHP, Caddy, MySQL và Redis trong 30
  ngày.
- `scripts/log-clean.sh` dọn sạch mọi thư mục con trong `logs/` nhưng giữ nguyên
  cây thư mục. Tệp có thể còn mở (không có ngày trong tên, ngày hôm nay, hoặc
  được ghi trong 24 giờ qua) được truncate để tiến trình đang chạy tiếp tục ghi
  đúng tệp; tệp đã xoay vòng thì xóa hẳn. Chạy `--dry-run` trước; script hỏi
  `XOA` trước khi thay đổi.
- `docker builder prune` thu hồi build cache; `docker system prune -a` xóa image
  không dùng và container đã dừng, không ảnh hưởng volume dữ liệu.
- `moodledata/temp`, thư mục mã nguồn cũ và các bản dump cũ xóa được sau khi đã
  có bản backup mới hơn.
- Chỉ hai lệnh sau xóa dữ liệu:

```bash
docker compose down -v
docker system prune -a --volumes
```

### Upload thất bại dù dưới giới hạn

PHP cho phép 200 MB mỗi tệp và 200 MB mỗi request:

```bash
docker exec moodle_web php -i | grep -E 'upload_max_filesize|post_max_size|memory_limit'
```

Moodle còn giới hạn riêng trong **Site administration → Security → Site
policies**. Lỗi 413 từ Caddy hoặc thất bại im lặng thường là request vượt
`post_max_size`.

### Scheduler không gọi được proxy

Ofelia đọc `ofelia/config.ini` một lần lúc khởi động, nên sửa xong phải khởi
động lại:

```bash
docker compose up -d --force-recreate socket-proxy cron
docker logs moodle_cron_scheduler 2>&1 | tail -n 20
docker logs moodle_socket_proxy 2>&1 | tail -n 20
```

`connection refused` là proxy chưa chạy hoặc không ở trên `socket_net`. Lỗi `403`
ở một job nghĩa là tên container trong `ofelia/config.ini` không khớp với
`ofelia/rules.list`, hoặc tệp rule đã sửa mà chưa tạo lại proxy. CetusGuard in
`forbidden` kèm method và path ở mức log 6; nâng `CETUSGUARD_LOG_LEVEL` lên `7`
để thấy đầy đủ dòng request.

### Sai múi giờ

`TZ` trong `.env` mặc định `Asia/Ho_Chi_Minh` và compose truyền cho mọi
container, nên Apache, PHP, MySQL, Redis, Caddy và Ofelia ghi mốc thời gian theo
giờ Việt Nam. CetusGuard là ngoại lệ: image `scratch` không có zoneinfo nên log
của chính nó theo UTC; job mà nó chuyển tiếp vẫn theo múi giờ của Ofelia. Moodle
có thiết lập riêng trong **Site administration → Location → Location settings**;
giữ cùng múi giờ. Nếu đổi `TZ`, đổi cả thiết lập của Moodle, nếu không giao diện
và log sẽ lệch nhau.

## Giới hạn đã biết

Phân tích đầy đủ nằm trong [LIMITATIONS.vi.md](LIMITATIONS.vi.md). Tóm tắt:

- Chỉ một máy chủ: không failover, không nâng cấp không gián đoạn.
- Restic sao lưu `moodledata/`, nhưng kho nằm cùng ổ đĩa máy chủ.
- Redis giữ AOF trong `redis_data`; `down -v` vẫn xóa session.
- Không monitoring, không alert; người dùng phát hiện lỗi trước.
- Thẻ image động nên rebuild không tái lập được.
- Nâng cấp thủ công.

Ba rủi ro lớn nhất có ghi chú trong
[LIMITATIONS.vi.md](LIMITATIONS.vi.md#ba-rủi-ro-lớn-nhất). Restic và volume Redis
đã áp dụng; việc dọn và đưa backup ra ngoài thì chưa.

## Việc cần làm định kỳ

Hằng tuần:

```bash
docker compose ps
docker stats --no-stream
docker exec moodle_db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot "$MYSQL_DATABASE" -e "SELECT COUNT(*) FROM mdl_logstore_standard_log;"'
docker exec moodle_web restic snapshots --latest 1
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost/
```

Hằng tháng:

- Sao chép bản dump mới nhất ra ngoài máy chủ và thử phục hồi.
- Chạy `restic check --read-data-subset=5%` và thử phục hồi một tệp.
- Kiểm tra dung lượng trống và `docker system df`.
- Xem `logs/php` và `logs/moodle` có lỗi lặp lại không.
- Chạy `bash scripts/log-clean.sh --dry-run`, dọn nếu `logs/` đã lớn.
- Xác nhận hệ điều hành đã cập nhật bảo mật.
