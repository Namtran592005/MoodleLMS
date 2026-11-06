# Moodle LMS — Docker Skeleton

**English** | [Tiếng Việt](README.vi.md)

A Moodle 5.x deployment skeleton built with Docker Compose: reverse proxy,
automatic TLS, production PHP, MySQL, Redis, cron and backups. The goal is to
stand up an LMS on a Linux server with a single start command, using a
configuration strict enough for real operation.

The repository holds only the configuration skeleton. Moodle source,
`moodledata/`, `backup/`, `logs/`, `.env` and internal documentation stay out of
the repo (see `.gitignore`). The one exception is `moodle/public/.htaccess`,
kept because it is an important Apache configuration file.

## Components

| Service | Image | Role | Ports |
|---|---|---|---|
| `caddy` | build `./caddy` | Reverse proxy (Caddy latest + rate limit), automatic TLS, security headers | 80, 443, 443/udp |
| `db` | `mysql:9` | MySQL 9.7 LTS, `utf8mb4` | internal 3306 |
| `redis` | `redis:latest` | Cache and sessions, 256 MB limit | internal 6379 |
| `moodle` | build `./php` | Apache 2.4 event MPM + PHP-FPM 8.5, webroot `/var/www/html/public` | internal 80 |
| `cron` | `mcuadros/ofelia` | Moodle cron, daily backup, log rotation | not exposed |

Only `caddy` publishes ports; the other services are reachable only inside
`moodle_net`.

## Architecture

Caddy terminates HTTPS and forwards to Apache/PHP in `moodle_web`. PHP reads and
writes `moodledata`, queries MySQL and Redis, then returns the response through
Caddy. Apache runs `mpm_event` with threads while PHP 8.5 runs in separate
PHP-FPM processes; the entrypoint sizes the worker count from CPU and RAM, see
**Configuration**.

Data is laid out as follows:

| Path | Contents | Storage |
|---|---|---|
| `moodle/` | Moodle source | Bind mount |
| `moodledata/` | User files, cache, sessions | Bind mount |
| `backup/` | Database dumps | Bind mount |
| `logs/` | Per-service logs | Bind mount |
| `moodle_db_data` | MySQL data | Named volume |
| `caddy_data`, `caddy_config` | Caddy certificates and config | Named volume |

There is no separate init service: each container creates its directories and
sets permissions in its entrypoint, so removing images does not skip the
initialization step. Five images in total.

## Requirements

| Item | Minimum | Recommended |
|---|---|---|
| Operating system | Ubuntu 22.04 or Debian 12 | Ubuntu 24.04 LTS |
| Docker | Engine 24 with Compose v2 | Latest release |
| CPU | 2 vCPU | 4 vCPU |
| RAM | 4 GB | 8 GB |
| Disk | 50 GB SSD | 100 GB NVMe |
| Domain | Optional for a trial run | Required in production |

## Installation

### 1. Configure the environment

```bash
cp .env.example .env
chmod 600 .env
```

The file must belong to the deployment account. If it was created with `sudo`,
change the owner back before running Compose:

```bash
sudo chown "$USER":"$USER" .env
chmod 600 .env
```

| Variable | Meaning |
|---|---|
| `MYSQL_ROOT_PASSWORD` | MySQL root password, internal use only |
| `MOODLE_DB_NAME` | Database name |
| `MOODLE_DB_USER` | MySQL account used by Moodle |
| `MOODLE_DB_PASSWORD` | Password for that account |
| `REDIS_PASSWORD` | Redis password |
| `TZ` | Time zone, defaults to `Asia/Ho_Chi_Minh` |
| `APP_ENV` | `production` |
| `PUID`, `PGID` | Optional, used to force a specific UID/GID |
| `APACHE_MAX_REQUEST_WORKERS`, `PHP_FPM_MAX_CHILDREN` | Worker counts, computed automatically by default; see **Workers and PHP-FPM** |
| `COMPOSE_PROJECT_NAME` | Keeps volume and network names stable |

### 2. Place the Moodle source

Unpack Moodle 5.x into `moodle/`, keeping an existing `config.php`:

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

### 3. Pull images and start

```bash
docker compose pull db redis cron
docker compose up -d --build
```

Three base images (`mysql:9`, `redis:latest`, `mcuadros/ofelia:latest`) are
pulled; `moodle` and `caddy` are built from `./php` and `./caddy`. The first run
takes 2 to 10 minutes because it initializes MySQL, builds images, runs
`composer install` and registers the Ofelia jobs.

### 4. Install Moodle

Open `http://<server-address>` and follow the installer:

| Field | Value |
|---|---|
| Database host | `db` |
| Database name | `MOODLE_DB_NAME` |
| Database user | `MOODLE_DB_USER` |
| Database password | `MOODLE_DB_PASSWORD` |
| Data directory | `/var/www/moodledata` |

### 5. Configure Redis

Go to **Site administration → Plugins → Caching → Configuration**, add a Redis
instance with server `redis` and the password from `.env`, then assign it to
**Application** and **Session**. Verify:

```bash
docker exec moodle_redis sh -c 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli ping'
```

Expected result: `PONG`.

## Permissions

The system does not use `chmod 777`. Permissions are handled by aligning the UID
of the deployment account with `www-data` in the container: the entrypoint reads
the owner of `./moodle` and `./moodledata` and adjusts `www-data` to match. An
owner of `root` or a system UID below 1000 is not used as a basis; in that case
1000 is applied.

| Path | Owner | Rights of the deployment account |
|---|---|---|
| `moodle/`, `moodledata/` | deployment account | Read, write, delete |
| `logs/caddy`, `logs/moodle`, `logs/php` | deployment account | Read, write, delete |
| `logs/mysql`, `logs/redis` | service user, deployment account group | Read, delete |
| `backup/` | deployment account | Read, write, delete |

Standard file modes: directories `755`, files `644`. `$CFG->directorypermissions
= 0755` keeps Moodle from creating world-writable directories. To force a
different UID/GID, set `PUID` and `PGID` in `.env` and run `docker compose up -d
--build`.

`docker exec` runs as `root` by default, so PHP commands need `-u www-data` to
keep cache files from being owned by `root`:

```bash
docker exec -it -u www-data moodle_web bash
docker exec -u www-data moodle_web php /var/www/html/admin/cli/purge_caches.php
```

If files are already owned by `root`, normalize them with `bash
scripts/fix-perms.sh`.

## Operations

### Backup and restore

```bash
bash scripts/db-backup.sh             # writes backup/moodle_<time>.sql and moodle_latest.sql
bash scripts/db-restore.sh <file.sql> # restore, with a confirmation step
```

Ofelia runs `mysqldump` daily and overwrites `backup/moodle_latest.sql`. The
backup lives on the same server, so sync it elsewhere with rsync, rclone or
object storage.

### Offline install from images

Use this when the new server has no Internet access:

```bash
# On a healthy running host
mkdir -p backup/images
docker save $(docker compose config --images) \
  | gzip -6 > backup/images/moodle-images.tar.gz

# On the new host, after copying source, moodledata, .env and backup/
gunzip -c backup/images/moodle-images.tar.gz | docker load
docker compose up -d --no-build
```

Or use `sh scripts/images-save.sh` and `sh scripts/images-load.sh`. The archive
holds only Docker images, not `moodle/`, `moodledata/`, `.env` or MySQL data;
copy those and `backup/moodle_latest.sql` separately. Image names are fixed as
`moodle-server-moodle:latest` and `moodle-caddy:latest`, so the project
directory can have any name.

### Logs

| Service | Path | Format |
|---|---|---|
| Caddy | `logs/caddy/access.log` | JSON, 100 MB internal rotation, 30 files kept |
| Apache | `logs/moodle/access-YYYY-MM-DD.log` | Split by day |
| PHP | `logs/php/error-YYYY-MM-DD.log` | Split by day |
| MySQL | `logs/mysql/error.log` | Errors only |
| Redis | `logs/redis/redis.log` | Notice level |

`scripts/log-rotate.sh` runs at midnight each day and keeps logs for 30 days.
Docker engine logs are capped at 10 MB per file, up to 3 files per container.

### Cron

Ofelia runs `admin/cli/cron.php` every minute as the deployment account's UID,
with `--keep-alive=0` so each run exits as soon as it finishes its tasks. The
`cron` service is limited to 256 MB and `restart: always` restarts it if it
exceeds that.

### usermenu patch

After install or upgrade, run the patch script:

```bash
bash scripts/patch-usermenu.sh
docker exec -u www-data moodle_web php /var/www/html/admin/cli/purge_caches.php
```

The script stores originals in `backup/usermenu-patch/` and refuses to overwrite
if the source has changed.

### Webroot .htaccess

`moodle/public/.htaccess` is kept in the repo because it enables the `r.php`
router and blocks downloads of `install.xml`, `environment.xml`,
`roles_schema.xml`, `*.schema.json` and the `lib/db`, `lib/tests`, `lib/phpunit`
directories.

Unpacking a new Moodle release can overwrite it with the default file. Restore
the repo copy and verify:

```bash
git checkout -- moodle/public/.htaccess
install -m 644 moodle/public/.htaccess /path/to/moodle/public/.htaccess
docker exec moodle_web apache2ctl -t
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost/theme/boost/style/moodle.css
```

### Import a custom language pack

Open `/admin/tool/customlang/import.php?lng=vi` directly to reach the ZIP upload
form. The Import item on the menu runs a checkout first, so large packs can take
minutes; PHP-FPM and Apache allow up to 900 seconds per request, and every open
tab can start another checkout, so keep a single tab open.

### Common commands

```bash
docker compose ps
docker compose logs -f moodle
docker compose restart moodle
docker compose down
docker compose up -d
```

### Cleanup

`docker system prune -a` removes unused images and stopped containers without
touching data volumes; run `docker compose up -d --build` afterwards. The next
two commands delete data as well and are only safe when a backup exists:

```bash
docker compose down -v
docker system prune -a --volumes
```

## TLS and domain

In `Caddyfile`, replace `:80` with your domain:

```text
lms.example.vn {
```

Caddy obtains and renews Let's Encrypt certificates automatically. After the
change, update `$CFG->wwwroot`, set `$CFG->sslproxy = true` when running behind a
proxy, run the URL replacement tool against the database and purge caches; the
full procedure is in the domain change guide.

## Security

- Only ports 22, 80 and 443 are open. MySQL and Redis are not exposed to the
  Internet.
- SSH uses key authentication; password login and `root` login are disabled.
- `.env` is mode `600`; the three passwords (MySQL root, MySQL application,
  Redis) must differ.
- `config.php` reads the database password from `MOODLE_DB_PASSWORD` and stores
  no password itself.
- Caddy sends `Strict-Transport-Security` over HTTPS,
  `Content-Security-Policy`, `X-Content-Type-Options`, `Referrer-Policy`,
  `Cross-Origin-Opener-Policy`, `Permissions-Policy` and hides the `Server`
  header. Apache sets `ServerTokens Prod` and `ServerSignature Off`, so no
  version leaks in headers or error pages.
- Caddy limits `POST` requests to 30 per minute per IP on `/login/index.php` and
  `/login/token.php`, complementing Moodle's account lockout policy.
- The webroot exposes no schema files or development directories, thanks to
  `moodle/public/.htaccess` (see **Webroot .htaccess**).
- Enable automatic security updates on the OS and check them regularly.
- Keep backups off the server and test restores.

## Configuration

### MySQL

`db` runs with `--innodb-flush-log-at-trx-commit=2` and `--sync-binlog=0` so
bulk writes do not wait for `fsync` after every statement; a language pack
checkout drops from about 320 seconds to 25 seconds. Trade-off: a power loss or
kernel panic can lose up to one second of committed transactions, while data
stays consistent. Remove both flags if you need absolute durability.

For logging, MySQL enables only `--log-error`, writing errors to
`logs/mysql/error.log`. To hunt slow queries, temporarily append to the `db`
`command:`:

```text
--slow-query-log=1 --slow-query-log-file=/var/log/mysql/slow.log --long-query-time=2
```

### Workers and PHP-FPM

The entrypoint computes `MaxRequestWorkers` as:

```text
min(nproc * 16, (available_RAM - reserve) / 64 MB, 150)
```

The reserve is 1.5 GB on a 4 GB host and 2 GB on an 8 GB host. This is the
`mpm_event` thread count, not the process count: `ThreadsPerChild = 10`,
`ServerLimit = ceil(workers / 10)` rounded up to a multiple of 10, so 40 workers
means 4 Apache processes. PHP-FPM defaults to `pm.max_children = 24`, set by
`PHP_FPM_MAX_CHILDREN` and never above the Apache worker count; the remaining
settings are `pm.start_servers = 2 * nproc`, `pm.min_spare_servers = nproc`,
`pm.max_spare_servers = 4 * nproc` and `pm.max_requests = 500`. Containers with
`mem_limit` or `cpus` read the cgroup limit instead of using all host resources.

Actual RAM use is driven by PHP-FPM because each worker is a process; event MPM
only reduces Apache overhead. On a 4 GB machine keep
`APACHE_MAX_REQUEST_WORKERS=40` and `PHP_FPM_MAX_CHILDREN=24`, and watch memory
before raising them.

### Sizing by load

| Item | Around 100 concurrent users | Around 1000 concurrent users |
|---|---|---|
| CPU / RAM | 4 vCPU / 8 GB | 16 vCPU / 64 GB |
| Disk | 100 GB | 500 GB |
| Model | Single server | One large server, or split web and database |

| Setting | 100 users | 1000 users | Location |
|---|---|---|---|
| `innodb_buffer_pool_size` | 2 GB | 16 to 24 GB | `db` `command:` |
| Redis `maxmemory` | 256 to 512 MB | 2 GB | `redis` `command:` |
| `opcache.memory_consumption` | 256 MB | 512 MB | `php/Dockerfile` |
| Apache `MaxRequestWorkers` (threads) | automatic 32–64 | 300 to 500 | `APACHE_MAX_REQUEST_WORKERS` in `.env` |
| PHP-FPM `pm.max_children` | 24 (default) | 300 to 500 | `PHP_FPM_MAX_CHILDREN` in `.env` |

When you outgrow one host, move MySQL to its own server by changing the database
host, then replicate the `moodle` container behind a load balancer.

## Documentation

The guides in `docs/` are written in Vietnamese and are not part of the repo:

| File | Contents |
|---|---|
| `HƯỚNG DẪN TRIỂN KHAI HỆ THỐNG LMS.md` | Deploy from an empty server to production |
| `HƯỚNG DẪN THAY ĐỔI DOMAIN HỆ THỐNG LMS.md` | Change the access address and enable HTTPS |
| `HƯỚNG DẪN NÂNG CẤP HỆ THỐNG LMS.md` | Upgrade versions, verify, and roll back |
| `HƯỚNG DẪN DI TRÚ HỆ THỐNG LMS.md` | Move the system to a new server |
| `CẤU TRÚC VÀ CẤU HÌNH HỆ THỐNG.md` | Directory layout and all configuration files for rebuilding |

## License

PolyForm Noncommercial 1.0.0. See `LICENSE-EE.md`. Noncommercial use only.
