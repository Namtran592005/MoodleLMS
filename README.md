# Moodle LMS — Docker Skeleton (Production)

Khung trien khai Moodle 5.x bang Docker Compose: Caddy (SSL tu dong) +
Apache PHP 8.4 (production) + MySQL 9 LTS + Redis + Ofelia (cron + backup).

Repo nay chi chua **khung cau hinh**. Source Moodle, `moodledata`,
backup SQL, log, file `.env` va docs noi bo khong commit
(xem `.gitignore`).

## Stack

| Service | Image | Vai tro |
|---|---|---|
| `setup` | `alpine` | Chay 1 lan: tao thu muc + chmod 777 bind mounts |
| `caddy` | `caddy:alpine` | Reverse proxy 80/443/udp, SSL Let's Encrypt tu dong |
| `db` | `mysql:9` | MySQL 9 LTS, utf8mb4, log error/slow/general |
| `redis` | `redis` | Cache + session, 256MB LRU |
| `moodle` | build `./php` | Apache + PHP 8.4, DocumentRoot `/public` |
| `cron` | `ofelia` | Cron Moodle 1p + backup DB daily + xoay log 0h VN |

## Cau truc

```text
├── docker-compose.yml
├── Caddyfile
├── .env.example            # copy thanh .env roi sua password
├── php/Dockerfile + entrypoint.sh
├── scripts/db-backup.sh    # backup tay
├── scripts/db-restore.sh   # restore tay
├── scripts/log-rotate.sh   # Ofelia goi moi dem
├── moodle/                 # source Moodle (tu tai, khong commit)
├── moodledata/             # dataroot (khong commit)
├── backup/                 # sql dump (khong commit)
└── logs/caddy,moodle,php,mysql,redis
```

## Chay nhanh

```bash
cp .env.example .env   # sua password
# Giai nen source Moodle 5.x vao ./moodle (giua lai config.php neu co)
docker compose up -d --build
```

Mo `http://localhost`, cai dat web voi: DB host `db`,
DB name/user/pass theo `.env`, data dir `/var/www/moodledata`.
`config.php` dung `dbtype = 'mysqli'`. MySQL tu tao `MYSQL_USER`
luc init volume lan dau.

Bat Redis: Admin → Site administration → Plugins → Caching →
Add instance (Server `redis`, password theo `.env`) → map
`Application` + `Session`.

## Backup / Restore

```bash
bash scripts/db-backup.sh          # -> backup/moodle_*.sql + moodle_latest.sql
bash scripts/db-restore.sh [file]  # mac dinh moodle_latest.sql
```

Ofelia tu dump `moodle_latest.sql` moi ngay.

## Logs

Moi service ghi log rieng duoi `logs/`, xoay moi dem luc 0h VN,
giu 30 ngay (Caddy dang JSON de parse). General log MySQL ton
disk — xoa 2 dong `general` trong `docker-compose.yml` neu khong
can audit query.

## Len domain

1. `Caddyfile`: doi `:80` thanh domain
2. `docker compose up -d` (port 443 mo san, cert luu o volume)
3. Replace URL cu sang domain + purge caches (xem Moodle docs
   `admin/tool/replace/cli`), bat `$CFG->sslproxy` neu sau proxy.

## Quyen

`setup` + `entrypoint.sh` tu mo 777 `moodle/ moodledata/ logs/
backup/` nen user host va `www-data` deu ghi duoc 2 chieu,
khong can `chown` tay. Them default ACL (hieu luc tren ext4/xfs)
cho file tao moi luc runtime.

## License

PolyForm Noncommercial 1.0.0 — xem `LICENSE-EE.md`.
Chi dung cho muc dich phi thuong mai.
