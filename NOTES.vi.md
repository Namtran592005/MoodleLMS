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
MySQL; phải sao chép các phần đó và `backup/moodle_latest.sql` riêng. Tên image
đã cố định là `moodle-server-moodle:latest` và `moodle-caddy:latest` nên thư mục
dự án có thể đặt tên bất kỳ.

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

### Bản dump cơ sở dữ liệu

`scripts/db-job.sh` chạy trong `moodle_db`; Ofelia gọi lúc `@daily` (00:00 UTC).
Mỗi lần chạy ghi `backup/moodle_<thời-gian>.sql` với tên tới giây, cập nhật
`moodle_latest.sql` qua tệp tạm, rồi xóa các bản theo ngày cũ hơn 7 ngày:

```sh
find /backup -maxdepth 1 -type f -name 'moodle_*.sql' \
  ! -name 'moodle_latest.sql' -mtime +6 -delete
```

`-mtime +6` giữ hôm nay và 6 ngày trước đó. Bước dọn chạy sau khi dump thành công,
và `set -e` dừng script nếu `mysqldump` lỗi, nên lần chạy hỏng không bao giờ xóa
bản tốt cuối cùng.

Container cơ sở dữ liệu chạy bằng `root`, nên job đổi chủ sở hữu tệp mới về chủ
của `/backup`. Không có bước đó, tài khoản trên host đọc được nhưng không ghi đè
được `moodle_latest.sql` ở lần chạy tay sau. Bản mới có quyền `600` vì chứa dữ
liệu người dùng. Backup tay từ host cũng đi qua đúng job này:

```bash
bash scripts/db-backup.sh
```

Máy chủ bật GTID, nên job truyền `--set-gtid-purged=OFF`. Bản dump còn câu lệnh
`GTID_PURGED` không import được vào chính máy chủ đó: MySQL báo lỗi 3546 vì tập
GTID chồng lên `GTID_EXECUTED`. `scripts/db-restore.sh` cũng bỏ dòng đó, nên các
bản dump tạo trước thay đổi này vẫn phục hồi được.

Mỗi bản dump là tệp SQL khoảng 22 MB, nên 7 ngày tốn khoảng 154 MB. Khi muốn xóa
toàn bộ, kể cả `moodle_latest.sql`:

```bash
bash scripts/db-clean.sh --dry-run
bash scripts/db-clean.sh
```

Script liệt kê tệp và tổng dung lượng rồi hỏi gõ `XOA`. Nó không đụng tới
`backup/restic` hay `moodledata/`.

### Sao lưu tệp bằng restic

`moodledata` chứa nội dung thật của người dùng: bài nộp, ảnh, gói SCORM.
`filedir` là bất biến — tên tệp chính là hash nội dung — nên nén toàn bộ mỗi ngày
là chép lại đúng những byte cũ. Restic giữ một bản cho mỗi khối, nhờ vậy lần chạy
thứ hai khi dữ liệu không đổi chỉ thêm vài trăm byte.

Job trong `scripts/restic-job.sh` (Ofelia gọi qua `docker exec`) làm bốn việc:

1. Khởi tạo `backup/restic` nếu kho chưa có.
2. Chạy `restic backup /var/www/moodledata` với host `moodle` và tag `files`.
3. Loại trừ `cache`, `localcache`, `temp`, `sessions`, `muc`, `environment`,
   `antivirus_quarantine` và `trashdir`. Tất cả đều tái tạo được hoặc dùng xong
   có thể bỏ.
4. Chạy `restic forget --keep-daily 7 --prune`, chỉ giữ 7 ngày gần nhất.

Bước dọn chạy sau backup, và `set -e` dừng script nếu backup lỗi, nên một lần
chạy hỏng không bao giờ xóa bản tốt cuối cùng. Restic cũng giữ thêm snapshot cũ
nhất khi kho chưa đủ 7 ngày; sau một tuần số bản ổn định đúng bằng 7. Hiện kho
khoảng 22 MB cho 50 MB dữ liệu. Bản ngoài máy chủ là việc còn lại trong
[LIMITATIONS.vi.md](LIMITATIONS.vi.md#sửa-3-dọn-và-đưa-backup-ra-khỏi-máy-chủ).

Chạy backup bằng tay từ host, cùng luồng mà Ofelia dùng:

```bash
bash scripts/restic-backup.sh                 # backup ngay, rồi in 3 snapshot và dung lượng kho
docker exec moodle_web restic snapshots
docker exec moodle_web restic stats --mode restore-size
docker exec moodle_web restic check --read-data-subset=5%
```

`scripts/restic-backup.sh` kiểm tra `moodle_web` đang chạy rồi gọi
`sh /scripts/restic-job.sh` trong container, nơi có restic, `/backup/restic` và
`/var/www/moodledata`. Wrapper này để chạy tay không phải nhớ lệnh `docker exec`
dài, và để lịch tự động với chạy tay dùng chung một đoạn mã.

### Dọn kho restic

`scripts/restic-clean.sh` xóa lịch sử backup có chủ đích; không dùng trong vận
hành bình thường. Mặc định script chạy
`restic forget --keep-last 0 --prune --unsafe-allow-remove-all`, xóa mọi snapshot
tag `files` của host `moodle` nhưng giữ kho và mật khẩu trong `.env`. `--repo` xóa
luôn thư mục `backup/restic`, nên lần backup sau sẽ khởi tạo kho mới. `--dry-run`
chỉ in ra sẽ xóa gì.

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
Nếu nó lỗi vì đầy ổ, snapshot vẫn nguyên; giải phóng chỗ rồi chạy lại:

```bash
docker exec moodle_web restic forget --host moodle --tag files --keep-daily 7 --prune
```

### Phục hồi tệp

`scripts/restic-restore.sh` chạy trên host và có hai chế độ.

Mặc định là phục hồi ra thư mục tạm: ghi vào `backup/restore_<thời-gian>`, đổi chủ
sở hữu để tài khoản triển khai đọc được, rồi in số tệp của bản phục hồi bên cạnh số
tệp đang dùng. Không đụng gì trong `moodledata/`.

```bash
docker exec moodle_web restic snapshots     # tim ID can dung
bash scripts/restic-restore.sh              # ban moi nhat
bash scripts/restic-restore.sh 9711dea3     # mot ban cu the
```

`--in-place` là phục hồi thật: hỏi xác nhận, dừng `moodle` và `cron`, chép tệp đè
lên `moodledata/`, cảnh báo nếu còn tệp không thuộc tài khoản triển khai, khởi động
lại, chờ health check và xóa cache.

```bash
bash scripts/restic-restore.sh --in-place
bash scripts/db-restore.sh backup/moodle_latest.sql
docker exec -u www-data moodle_web php /var/www/html/admin/cli/purge_caches.php
```

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

### Định dạng lịch của Ofelia

Ofelia 0.3.x, bản đứng sau tag `latest`, vẫn bắt buộc trường giây ở đầu:
`0 0 19 * * *` là 19:00:00 UTC, còn `0 19 * * *` là mỗi giờ vào phút 19. Dạng
năm trường trông hợp lệ và không báo lỗi, nên một job hằng ngày âm thầm thành
mỗi giờ một lần.

```text
0 0 17 * * *   xoay log      (00:00 giờ VN)
0 0 19 * * *   sao lưu tệp   (02:00 giờ VN)
@daily         dump mysql
@every 1m      cron moodle
```

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

### Tệp thuộc root

Triệu chứng: Moodle báo không ghi được cache, hoặc tệp mới trong `moodle/` thuộc
`root`. Nguyên nhân: chạy `docker exec` mà thiếu `-u www-data`.

```bash
bash scripts/fix-perms.sh
docker exec -u www-data moodle_web php /var/www/html/admin/cli/purge_caches.php
```

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

### Site lỗi sau khi nâng cấp

```bash
docker exec -u www-data moodle_web php /var/www/html/admin/cli/maintenance.php --enable
docker exec -u www-data moodle_web php /var/www/html/admin/cli/upgrade.php --non-interactive
docker exec -u www-data moodle_web php /var/www/html/admin/cli/purge_caches.php
docker exec -u www-data moodle_web php /var/www/html/admin/cli/maintenance.php --disable
```

Giữ lại `config.php` và `moodle/public/.htaccess` khi giải nén mã nguồn mới. Sao
lưu cơ sở dữ liệu trước khi nâng cấp.

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

### Sai múi giờ

Container dùng `TZ` trong `.env`. Moodle có mặc định riêng trong **Site
administration → Location → Location settings**. Hai nơi phải trùng nhau, nếu
không lịch cron và mốc thời gian trong log sẽ lệch.

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
- Xác nhận hệ điều hành đã cập nhật bảo mật.
