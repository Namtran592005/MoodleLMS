# Giới hạn đã biết

[English](LIMITATIONS.md) | **Tiếng Việt**

Danh sách thẳng thắn những gì bản triển khai này chưa làm được. Mức độ phản ánh
hậu quả khi sự cố xảy ra trong vận hành thật, không phải khả năng xảy ra. Hai trong
ba rủi ro lớn nhất đã sửa ngày 13-11-2026: Redis có volume dữ liệu và `moodledata`
được sao lưu bằng restic. Vòng đời backup được sửa tiếp ngày 14-11-2026: job giữ
7 ngày rồi dọn phần cũ. Rủi ro còn lại, bản sao ngoài máy chủ, vẫn đang mở.

## Ba rủi ro lớn nhất

| # | Rủi ro | Vì sao quan trọng |
|---|---|---|
| 1 | Backup `moodledata` — đã sửa 13-11-2026 | Trước đây: tệp người dùng, bài nộp, ảnh chỉ tồn tại trên ổ đĩa này |
| 2 | Volume Redis — đã sửa 13-11-2026 | Trước đây: tạo lại container là mọi người bị đăng xuất |
| 3 | Backup chỉ nằm trên ổ đĩa máy chủ | Hỏng đĩa là mất toàn bộ bản sao; snapshot bị dọn sau 7 ngày |

## Kiến trúc

| Hạn chế | Ảnh hưởng | Mức |
|---|---|---|
| Chỉ một máy chủ | Khởi động lại, Windows update hay WSL restart đều làm site dừng | Cao |
| Chạy trong WSL trên Desktop | Không UPS, IP tĩnh, truy cập từ xa hay giám sát phần cứng | Cao |
| `moodledata/` là bind mount cục bộ | Không thể nhân bản container `moodle` sang máy khác | Cao |
| Không có load balancer | Không failover, không rolling restart | Trung bình |
| Dùng chung CPU và RAM | Một lần import hay backup dài làm chậm mọi request | Trung bình |
| Chỉ có `restart: always` | Cứu tiến trình chết, không cứu được máy chết | Trung bình |

## Dữ liệu và phục hồi

| Hạn chế | Ảnh hưởng | Mức |
|---|---|---|
| Dump cơ sở dữ liệu mỗi ngày một lần | Mất tới 24 giờ dữ liệu; RPO khoảng 24 giờ | Cao |
| Backup tệp chậm hơn dump 19 giờ | Tệp tải lên sau lần dump thành mồ côi khi phục hồi, không mất | Thấp |
| Backup lưu cùng ổ đĩa | Hỏng đĩa hoặc ransomware là mất toàn bộ bản sao | Cao |
| Không bật binlog | Không phục hồi theo thời điểm, chỉ có bản dump cuối | Cao |
| Chưa từng diễn tập phục hồi | RTO thực tế chưa biết, ước tính 30 đến 60 phút | Trung bình |
| `innodb-flush-log-at-trx-commit=2`, `sync-binlog=0` | Mất điện có thể mất tới một giây giao dịch đã commit | Trung bình |
| Không có MySQL replica | Không có bản thứ hai để đọc hoặc nâng cấp dự phòng | Trung bình |

## Hiệu năng

| Hạn chế | Ảnh hưởng | Mức |
|---|---|---|
| Trần 4 GB RAM | Thoải mái tới khoảng 100 người dùng đồng thời, sau đó swap | Trung bình |
| 24 tiến trình PHP-FPM | Tăng đồng thời cần thêm RAM, không phải thêm thread | Trung bình |
| Buffer pool MySQL mặc định 128 MB | Đọc đĩa cho tới khi chỉnh lên 2 GB hoặc hơn | Trung bình |
| `opcache.validate_timestamps=0` | Sửa file PHP không có tác dụng tới khi restart container | Trung bình |
| `max_execution_time=300` so với `ProxyTimeout 900` | Tác vụ web có thể chết ở 300 giây dù proxy cho 900 giây | Thấp |
| Không CDN, không object storage | Mọi lưu lượng và tệp đều dồn vào một ổ đĩa, một CPU | Trung bình |
| Chỉ nén `gzip` | Không có brotli hay zstd cho HTML đi qua proxy, nên văn bản vẫn lớn hơn mức tốt nhất hiện có | Thấp |
| Chỉ HTTP/1.1 trên cổng 80 | Không có multiplexing; lần tải đầu bị giới hạn sáu kết nối song song mỗi host | Thấp |
| Không có search engine ngoài | Tìm kiếm toàn cục dùng DB, chậm dần khi dữ liệu lớn | Thấp |
| Upload 200 MB, RAM PHP 1 GB | Hai người upload lớn cùng lúc có thể hết RAM | Thấp |

## Bảo mật

| Hạn chế | Ảnh hưởng | Mức |
|---|---|---|
| Ofelia mount Docker socket | Quyền qua Docker API tương đương root trên host | Cao |
| Bí mật nằm dạng chữ trong `.env` | Không xoay vòng, không secrets manager, tài khoản triển khai đọc được | Trung bình |
| Không fail2ban, không WAF | Chỉ endpoint đăng nhập bị giới hạn; quét cổng và lạm dụng không bị chặn | Trung bình |
| Thẻ image động (`mysql:9`, `redis:latest`, `ofelia:latest`) | Rebuild không tái lập được, nâng cấp đến mà không báo trước | Trung bình |
| Không quét hay ký image | Image nền có lỗ hổng mà không biết | Trung bình |
| Không bắt buộc 2FA hay SSO | Chỉ mật khẩu, không có định danh tập trung | Trung bình |
| CSP vẫn cần `'unsafe-inline'` và `'unsafe-eval'` | Moodle in script nội tuyến và TinyMCE gọi `new Function`, nên script chèn trong trang không bị chặn | Trung bình |
| CSP chỉ cho phép YouTube | Vimeo, Google Drive và ảnh ngoài trong nội dung khóa học bị chặn có chủ đích | Thấp |
| Không antivirus cho tệp tải lên | Tệp độc hại được lưu và phục vụ | Thấp |
| Log chỉ nằm trên đĩa cục bộ | Kẻ xâm nhập có thể xóa dấu vết | Thấp |

## Vận hành

| Hạn chế | Ảnh hưởng | Mức |
|---|---|---|
| Nâng cấp thủ công | Downtime và sai sót con người ở mỗi bản phát hành | Cao |
| `.htaccess` có thể bị gói mới ghi đè | Schema bị tải xuống được cho tới khi khôi phục | Trung bình |
| `config.php` không nằm trong repo | Máy mới phải dựng lại bằng tay | Trung bình |
| `docs/` bị gitignore | Tri thức vận hành chỉ nằm trên một máy | Trung bình |
| Không monitoring, không alert | Người dùng phát hiện lỗi trước đội vận hành | Cao |
| Một scheduler cron duy nhất | Ofelia dừng là không task nào chạy và không ai biết | Trung bình |
| Chưa cấu hình SMTP | Đặt lại mật khẩu và thông báo không gửi được | Trung bình |
| Múi giờ đặt ở hai nơi | Cron và log lệch khi hai nơi khác nhau | Thấp |

## Mở rộng

Thiết kế chỉ mở rộng theo chiều dọc. Đạt khoảng 1000 người dùng đồng thời cần thay
đổi cấu trúc, không phải tinh chỉnh tham số:

1. Tách MySQL sang máy chủ riêng.
2. Chuyển `moodledata` sang S3 hoặc NFS dùng chung.
3. Đưa Redis ra ngoài hoặc chạy cluster.
4. Nhân bản `moodle` sau load balancer với session dùng chung.
5. Tách cron và backup khỏi container web.

## Điều gì chấp nhận được

Với phòng lab, bản demo hoặc triển khai nhỏ dưới khoảng 100 người dùng, phần lớn
đánh đổi trên là hợp lý cho một hệ thống khởi động bằng một lệnh. Những mục nên sửa
kể cả ở quy mô nhỏ là các mục mức Cao ở trên, bắt đầu từ rủi ro backup còn lại.
Phần còn lại có thể chờ tới khi hệ thống lớn hơn hoặc dữ liệu trở nên quan trọng.

## Sửa 1: sao lưu `moodledata` bằng restic (đã áp dụng)

**Trạng thái.** Đã áp dụng ngày 13-11-2026. Snapshot đầu có 5.671 tệp (50,1 MiB)
và chiếm 19,9 MiB trong kho; lần chạy thứ hai khi không có thay đổi chỉ thêm
680 byte trong hai giây. Phục hồi `filedir` cho ra 4.653 tệp, khớp chính xác với
bản gốc, và `restic check` không báo lỗi.

**Trước đây.** `scripts/db-backup.sh` chỉ dump MySQL. Tệp trong
`moodledata/filedir` chỉ tồn tại ở một nơi, còn nén toàn bộ bằng `tar` mỗi ngày sẽ
ghi lại khoảng 50 MB dữ liệu không đổi.

**Thay đổi.** Bốn chỗ nhỏ:

```text
php/Dockerfile        apt install restic
docker-compose.yml    mount ./scripts:/scripts:ro, truyen RESTIC_PASSWORD
                      va RESTIC_REPOSITORY, them job Ofelia luc 19:00 UTC
scripts/restic-job.sh     job that su: khoi tao kho, backup moodledata, loai tru rac
scripts/restic-backup.sh  wrapper tren host de chay tay
scripts/restic-restore.sh phuc hoi ra thu muc tam hoac --in-place
scripts/restic-clean.sh   xoa snapshot hoac ca kho
.env / .env.example   RESTIC_PASSWORD
```

Job chạy `nice -n 19 sh /scripts/restic-job.sh` trong container `moodle`.
Script khởi tạo `/backup/restic` ở lần đầu, sau đó sao lưu `/var/www/moodledata`
với host `moodle` và tag `files`. Nó loại trừ `cache`, `localcache`, `temp`,
`sessions`, `muc`, `environment`, `antivirus_quarantine` và `trashdir`, đều là
dữ liệu tái tạo được hoặc dùng xong có thể bỏ.

Vì `filedir` đặt tên tệp theo hash nội dung, tệp không đổi không bao giờ được lưu
hai lần. Kho tăng từ 0 lên 22 MB cho 50 MB dữ liệu.

**Kiểm tra.**

```bash
docker exec moodle_web restic snapshots
docker exec moodle_web restic stats --mode restore-size
docker exec moodle_web restic check --read-data-subset=5%
```

**Phục hồi.** `scripts/restic-restore.sh --in-place` hỏi xác nhận, dừng site, chép
snapshot đè lên `moodledata/` rồi khởi động lại. Sau đó phục hồi cơ sở dữ liệu và
xóa cache:

```bash
bash scripts/restic-restore.sh --in-place
bash scripts/db-restore.sh backup/moodle_latest.sql
docker exec -u www-data moodle_web php /var/www/html/admin/cli/purge_caches.php
```

Không có `--in-place`, cùng script đó chỉ phục hồi vào `backup/restore_<thời-gian>`
và in số tệp, nên chạy được cả khi site đang hoạt động.

**Đánh đổi.** Kho nằm trong `backup/` cùng ổ đĩa, nên nó cứu được sai sót và lỗi
phần mềm, không cứu được khi mất ổ đĩa. Job giữ 7 snapshot ngày rồi dọn phần cũ;
bản sao ngoài máy chủ là Sửa 3. `RESTIC_PASSWORD` giờ quan trọng ngang dữ liệu:
không có nó thì không mở được kho, nên phải giữ một bản ngoài máy chủ.

## Sửa 2: cấp volume dữ liệu cho Redis (đã áp dụng)

**Trạng thái.** Đã áp dụng ngày 13-11-2026. `redis_data` được mount tại `/data`;
một khóa kiểm tra vẫn còn sau `docker compose up -d --force-recreate redis`, và
site trả 200. Phần dưới ghi lại việc đã làm.

**Trước đây.** AOF đã bật (`appendonly yes`) nhưng `/data` không được mount. Tệp
AOF nằm trong lớp container, nên `docker compose down` rồi `up`, hoặc bất kỳ lần
rebuild nào, đều làm mất nó. Người dùng bị đăng xuất, cache trống.

**Thay đổi.** Trong `docker-compose.yml`:

```yaml
services:
  redis:
    volumes:
      - ./logs/redis:/var/log/redis
      - redis_data:/data

volumes:
  redis_data:
```

Đã áp dụng bằng cách tạo lại service một lần:

```bash
docker compose up -d redis
```

**Kiểm tra.** Ghi một khóa, tạo lại container, đọc lại:

```bash
docker exec moodle_redis sh -c 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli set volume_check ok'
docker compose up -d --force-recreate redis
docker exec moodle_redis sh -c 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli get volume_check'
```

Lệnh thứ hai phải in ra `ok`. Chỉ restart không đủ để kiểm tra, vì nó giữ nguyên
container và sẽ đạt kể cả khi không có volume.

**Đánh đổi.** Volume bị xóa bởi `docker compose down -v`, điều này đúng vì session
và cache dùng xong có thể bỏ. Nó không thay thế được phương án dự phòng session
trong DB. Cách khác: chuyển session của Moodle sang handler database, sống sót cả
khi mất Redis nhưng chậm hơn một chút.

## Sửa 3: dọn và đưa backup ra khỏi máy chủ

**Trạng thái.** Phần dọn đã áp dụng ngày 14-11-2026: job hằng ngày chạy
`restic forget --keep-daily 7 --prune` sau khi backup thành công. Bản sao ngoài
máy chủ vẫn chưa có, nên mục này còn mở.

**Trước đây.** Snapshot tăng mãi, nên `backup/` lớn dần không giới hạn.

**Việc còn lại.** Đưa cả dump lẫn kho restic ra nơi khác, ví dụ bằng rclone:

```bash
rclone copy backup/moodle_latest.sql remote:moodle/db/
rclone sync backup/restic remote:moodle/restic
```

Hai chi tiết quan trọng hơn câu lệnh cụ thể:

- Chỉ sao chép sau khi lần chạy tại chỗ thành công, nếu không bản trên remote cũ
  hơn bạn tưởng.
- Giữ thông tin đăng nhập rclone trong tệp quyền `600`, ngoài kho mã nguồn.

**Kiểm tra.** Xác nhận bản dump và snapshot mới nhất còn mới và đọc được:

```bash
ls -lh backup/moodle_latest.sql
head -5 backup/moodle_latest.sql
docker exec moodle_web restic snapshots --latest 1
rclone lsl remote:moodle/restic | tail -3
```

**Đánh đổi.** Lưu trữ remote tốn phí và thông tin đăng nhập rclone nằm trên host
(đặt trong tệp quyền `600`). Phục hồi từ remote phải tải về trước, làm tăng RTO.
Nên diễn tập phục hồi sau tháng đầu tiên.
