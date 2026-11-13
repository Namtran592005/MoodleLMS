# Giới hạn đã biết

[English](LIMITATIONS.md) | **Tiếng Việt**

Danh sách thẳng thắn những gì bản triển khai này chưa làm được. Mức độ phản ánh
hậu quả khi sự cố xảy ra trong vận hành thật, không phải khả năng xảy ra. Ba rủi ro
lớn nhất có kèm cách sửa đề xuất; chưa có thay đổi nào được áp dụng, hệ thống vẫn
chạy y như trước.

## Ba rủi ro lớn nhất

| # | Rủi ro | Vì sao quan trọng |
|---|---|---|
| 1 | `moodledata/` không được sao lưu | Tệp người dùng, bài nộp, ảnh chỉ tồn tại trên ổ đĩa này |
| 2 | Redis không có volume dữ liệu | Tạo lại container là mọi người bị đăng xuất |
| 3 | Backup nằm cùng ổ đĩa và không bao giờ hết hạn | Hỏng đĩa là mất cả dữ liệu lẫn bản sao; thư mục tăng vô hạn |

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
| `moodledata/` không nằm trong script backup | Mất tệp tải lên dù cơ sở dữ liệu còn nguyên | Cao |
| Backup lưu cùng ổ đĩa | Hỏng đĩa hoặc ransomware là mất toàn bộ bản sao | Cao |
| Không bật binlog | Không phục hồi theo thời điểm, chỉ có bản dump cuối | Cao |
| Bản backup không bao giờ được dọn | `backup/` tăng tới khi đầy ổ | Trung bình |
| Chưa từng diễn tập phục hồi | RTO thực tế chưa biết, ước tính 30 đến 60 phút | Trung bình |
| `innodb-flush-log-at-trx-commit=2`, `sync-binlog=0` | Mất điện có thể mất tới một giây giao dịch đã commit | Trung bình |
| Dữ liệu Redis nằm trong lớp container | `down`/`up` hoặc rebuild là mất session và cache | Trung bình |
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
| Không antivirus cho tệp tải lên | Tệp độc hại được lưu và phục vụ | Thấp |
| Log chỉ nằm trên đĩa cục bộ | Kẻ xâm nhập có thể xóa dấu vết | Thấp |

## Vận hành

| Hạn chế | Ảnh hưởng | Mức |
|---|---|---|
| Nâng cấp thủ công | Downtime và sai sót con người ở mỗi bản phát hành | Cao |
| Vá usermenu sửa core | Dễ vỡ hoặc bị ghi đè khi nâng cấp | Trung bình |
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
kể cả ở quy mô nhỏ là ba mục đầu. Phần còn lại có thể chờ tới khi hệ thống lớn hơn
hoặc dữ liệu trở nên quan trọng.

## Sửa 1: sao lưu `moodledata`

**Hiện trạng.** `scripts/db-backup.sh` chỉ dump MySQL. Tệp trong
`moodledata/filedir` chỉ tồn tại ở một nơi.

**Đề xuất.** Thêm `scripts/files-backup.sh` và một job Ofelia thứ hai:

```bash
#!/bin/bash
set -e
cd "$(dirname "$0")/.."
mkdir -p backup
STAMP=$(date +%F_%H-%M)
tar -czf "backup/moodledata_${STAMP}.tar.gz" \
  --exclude='moodledata/cache' \
  --exclude='moodledata/localcache' \
  --exclude='moodledata/temp' \
  moodledata
echo "Done: backup/moodledata_${STAMP}.tar.gz"
```

Đặt lịch khoảng 30 phút sau lần dump cơ sở dữ liệu. Chạy backup tệp sau: một tệp
được tải lên giữa hai job sẽ thành mồ côi, vô hại; nếu làm ngược lại, một dòng
trong DB có thể trỏ tới tệp không còn.

**Quy trình phục hồi.**

```bash
docker compose stop moodle cron
bash scripts/db-restore.sh backup/moodle_latest.sql
tar -xzf backup/moodledata_YYYY-MM-DD_HH-MM.tar.gz -C .
bash scripts/fix-perms.sh
docker compose start moodle cron
docker exec -u www-data moodle_web php /var/www/html/admin/cli/purge_caches.php
```

**Kiểm tra.** So sánh số tệp trước và sau:

```bash
find moodledata/filedir -type f | wc -l
tar -tzf backup/moodledata_YYYY-MM-DD_HH-MM.tar.gz | wc -l
```

**Đánh đổi.** Tệp nén lớn bằng `moodledata` (hiện khoảng 100 MB) và việc nén tốn
CPU trong khung giờ backup. Nếu vượt vài GB, chuyển sang snapshot bằng
`rsync --link-dest` để tệp không đổi được hard-link.

## Sửa 2: cấp volume dữ liệu cho Redis

**Hiện trạng.** AOF đã bật (`appendonly yes`) nhưng `/data` không được mount. Tệp
AOF nằm trong lớp container, nên `docker compose down` rồi `up`, hoặc bất kỳ lần
rebuild nào, đều làm mất nó. Người dùng bị đăng xuất, cache trống.

**Đề xuất.** Trong `docker-compose.yml`:

```yaml
services:
  redis:
    volumes:
      - ./logs/redis:/var/log/redis
      - redis_data:/data

volumes:
  redis_data:
```

Sau đó tạo lại service một lần:

```bash
docker compose up -d redis
```

**Kiểm tra.** Ghi một khóa, restart, đọc lại:

```bash
docker exec moodle_redis sh -c 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli set healthcheck ok'
docker compose restart redis
docker exec moodle_redis sh -c 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli get healthcheck'
```

**Đánh đổi.** Volume bị xóa bởi `docker compose down -v`, điều này đúng vì session
và cache dùng xong có thể bỏ. Nó không thay thế được phương án dự phòng session
trong DB. Cách khác: chuyển session của Moodle sang handler database, sống sót cả
khi mất Redis nhưng chậm hơn một chút.

## Sửa 3: dọn và đưa backup ra khỏi máy chủ

**Hiện trạng.** `scripts/db-backup.sh` ghi một bản dump có mốc thời gian mỗi lần
chạy, cộng thêm `moodle_latest.sql`, và không bao giờ xóa gì. Tất cả nằm cùng ổ
đĩa với cơ sở dữ liệu.

**Đề xuất.** Giữ 14 bản ngày, một bản tuần, và đưa cả DB lẫn tệp ra nơi khác:

```bash
# sau khi dump thành công
find backup -maxdepth 1 -name 'moodle_*.sql' -mtime +14 -delete
if [ "$(date +%u)" = "7" ]; then
  cp backup/moodle_latest.sql "backup/weekly_$(date +%F).sql"
fi
find backup -maxdepth 1 -name 'weekly_*.sql' -mtime +56 -delete

rclone copy backup/moodle_latest.sql remote:moodle/db/
rclone copy backup/moodledata_latest.tar.gz remote:moodle/files/
```

Hai chi tiết quan trọng hơn con số cụ thể:

- Chỉ dọn sau khi bản dump mới thành công, nếu không một lần lỗi sẽ xóa mất bản
  tốt cuối cùng.
- Sao chép ra ngoài sau khi dọn, để bản trên remote chính là bản vừa kiểm tra.

**Kiểm tra.** Xác nhận bản mới nhất còn mới và đọc được:

```bash
ls -lh backup/moodle_latest.sql
head -5 backup/moodle_latest.sql
rclone lsl remote:moodle/db/ | tail -3
```

**Đánh đổi.** Lưu trữ remote tốn phí và thông tin đăng nhập rclone nằm trên host
(đặt trong tệp quyền `600`). Phục hồi từ remote phải tải về trước, làm tăng RTO.
Nên diễn tập phục hồi sau tháng đầu tiên.
