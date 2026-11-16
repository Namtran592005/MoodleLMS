# Moodle LMS — Docker Skeleton

**English** | [Tiếng Việt](README.vi.md)

A Moodle 5.x deployment skeleton built with Docker Compose: reverse proxy,
automatic TLS, production PHP, MySQL, Redis, cron and backups. The goal is to
stand up an LMS on a Linux server with a single start command. The current source
is Moodle 5.3.1 (build 20261112).

The repository holds only the configuration skeleton. Moodle source,
`moodledata/`, `backup/`, `logs/`, `.env` and internal documentation stay out of
the repo (see `.gitignore`). The one exception is `moodle/public/.htaccess`,
kept because it is an important Apache configuration file.

Sizing, tuning and fixes for problems seen in operation are in
[NOTES.md](NOTES.md). This file stays focused on getting the stack running.

## Components

| Service | Image | Role | Ports |
|---|---|---|---|
| `caddy` | build `./caddy` | Reverse proxy (Caddy latest + rate limit), automatic TLS, security headers | 80, 443, 443/udp |
| `db` | `mysql:9` | MySQL 9.7 LTS, `utf8mb4` | internal 3306 |
| `redis` | `redis:latest` | Cache and sessions, 256 MB limit | internal 6379 |
| `moodle` | build `./php` | Apache 2.4 event MPM + PHP-FPM 8.5, webroot `/var/www/html/public` | internal 80 |
| `cron` | `mcuadros/ofelia` | Moodle cron, database dump, restic backup, log rotation | not exposed |

Only `caddy` publishes ports; the other services are reachable only inside
`moodle_net`.

## Architecture

Caddy terminates HTTPS and forwards to Apache/PHP in `moodle_web`. PHP reads and
writes `moodledata`, queries MySQL and Redis, then returns the response through
Caddy. Apache runs `mpm_event` with threads while PHP 8.5 runs in separate
PHP-FPM processes.

Data is laid out as follows:

| Path | Contents | Storage |
|---|---|---|
| `moodle/` | Moodle source | Bind mount |
| `moodledata/` | User files, cache, sessions | Bind mount |
| `backup/` | Database dumps and the restic repository | Bind mount |
| `logs/` | Per-service logs | Bind mount |
| `moodle_db_data` | MySQL data | Named volume |
| `redis_data` | Redis AOF, sessions and cache | Named volume |
| `caddy_data`, `caddy_config` | Caddy certificates and config | Named volume |

There is no separate init service: each container creates its directories and
sets permissions in its entrypoint, so removing images does not skip the
initialization step. Five images in total.

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
| `RESTIC_PASSWORD` | Passphrase that encrypts the restic repository |
| `RESTIC_REPOSITORY` | Optional, defaults to `/backup/restic` |
| `TZ` | Time zone, defaults to `Asia/Ho_Chi_Minh` |
| `APP_ENV` | `production` |
| `PUID`, `PGID` | UID/GID for `www-data`, defaults to `1000` |
| `APACHE_MAX_REQUEST_WORKERS`, `APACHE_START_SERVERS` | Apache thread and process counts, computed automatically when empty |
| `PHP_FPM_MAX_CHILDREN` | PHP-FPM children, defaults to `24` |
| `MOODLE_WORKER_MEM_MB`, `MOODLE_MEM_RESERVE_MB` | Memory budget per worker and memory kept for other services |
| `COMPOSE_PROJECT_NAME` | Keeps volume and network names stable |

Worker sizing, memory behaviour and load-based values are covered in
[NOTES.md](NOTES.md#ram-and-workers).

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

Keep the repo copy of `moodle/public/.htaccess`; a new release tarball may
replace it with the default file. Restoring it is described in
[NOTES.md](NOTES.md#webroot-htaccess).

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

No `chmod 777`. The entrypoint aligns the UID of the deployment account with
`www-data` by reading the owner of `./moodle` and `./moodledata`; an owner of
`root` or a UID below 1000 is replaced with 1000.

| Path | Owner | Deployment account rights |
|---|---|---|
| `moodle/`, `moodledata/` | deployment account | Read, write, delete |
| `logs/caddy`, `logs/moodle`, `logs/php` | deployment account | Read, write, delete |
| `logs/mysql`, `logs/redis` | service user, deployment account group | Read, write, delete |
| `backup/` | deployment account | Read, write, delete |

Directories are mode `755` and files `644`. To force a different UID/GID, set
`PUID` and `PGID` in `.env` and rebuild.

`docker exec` runs as `root` by default, so PHP commands need `-u www-data`:

```bash
docker exec -u www-data moodle_web php /var/www/html/admin/cli/purge_caches.php
```

If files are already owned by `root`, run `bash scripts/fix-perms.sh`; see
[NOTES.md](NOTES.md#files-owned-by-root) for details.

## Operations

### Backup and restore

Two jobs run every day, database first and files second:

```bash
bash scripts/db-backup.sh                 # dump to backup/moodle_<time>.sql and moodle_latest.sql
bash scripts/restic-backup.sh             # incremental backup of moodledata
```

The database job writes a dated dump and refreshes `moodle_latest.sql`, then
deletes dated dumps older than 7 days; a failed dump never removes the previous
copies. `scripts/db-clean.sh` removes every database dump, including
`moodle_latest.sql`, when you really want a clean slate:

```bash
bash scripts/db-clean.sh --dry-run   # list the files and their total size
bash scripts/db-clean.sh             # delete them, confirmation XOA
```

Ofelia runs the database dump and the restic job at 00:00 in
`Asia/Ho_Chi_Minh`, so the dump and the file snapshot describe the same moment.
The restic repository lives in `backup/restic`, is encrypted with
`RESTIC_PASSWORD`, and stores only what changed since the previous snapshot, so
a second run of unchanged data adds a few hundred bytes instead of a full copy.
After each successful backup it keeps the last 7 daily snapshots and prunes the
rest; a failed backup never removes the last good copy.

Two scripts share the work:

- `scripts/restic-backup.sh` runs on the host, starts a backup now, then prints
  the latest 3 snapshots and the repository size.
- `scripts/restic-job.sh` is the actual job that runs inside the container;
  Ofelia calls it on schedule, so there is no need to run it directly.

```bash
bash scripts/restic-backup.sh               # back up now, do not wait for the schedule
docker exec moodle_web restic snapshots      # list IDs and dates
bash scripts/restic-restore.sh              # newest snapshot -> backup/restore_<time>
bash scripts/restic-restore.sh <snapshot>   # a specific snapshot from the list
bash scripts/restic-restore.sh --in-place   # newest snapshot over moodledata/, with confirmation
```

Without `--in-place` the script only writes to `backup/restore_<time>` and prints
the file counts, so it is safe to run at any time. With `--in-place` it stops
`moodle` and `cron`, copies the files, checks ownership and starts them again.
Database restore uses `bash scripts/db-restore.sh <file.sql>`. Losing
`RESTIC_PASSWORD` makes the repository unreadable, so keep a copy outside the
server. Step-by-step procedures and the lock caveat are in
[NOTES.md](NOTES.md#restic-file-backup).

To drop the restic history, use `scripts/restic-clean.sh`: by default it removes
every snapshot but keeps the repository and the password, `--repo` removes the
repository directory too, and `--dry-run` only prints what it would do. Both
destructive modes ask you to type `XOA` to confirm.

### Cron

Ofelia runs `admin/cli/cron.php` every minute as the deployment account's UID,
with `--keep-alive=0`, so each run exits as soon as it finishes its tasks. The
`cron` service is limited to 256 MB and restarts automatically if it exceeds
that. Every job uses the `TZ` value from `.env`, `Asia/Ho_Chi_Minh` by default.

### Logs

| Service | Path | Format |
|---|---|---|
| Caddy | `logs/caddy/access.log` | JSON, 100 MB rotation, 30 files, 30 days |
| Apache | `logs/moodle/access-YYYY-MM-DD.log` | Split by day |
| PHP | `logs/php/error.log` | Errors; rotated copies by day |
| MySQL | `logs/mysql/error.log` | Errors only |
| Redis | `logs/redis/redis.log` | Notice level |

`scripts/log-rotate.sh` runs daily and keeps 30 days. `scripts/log-clean.sh`
empties every log file on demand while keeping the directory tree, and truncates
files that are still open instead of deleting them. Docker engine logs are capped
at 10 MB per file, 3 files per container. Log retention inside Moodle and cleanup
steps are covered in [NOTES.md](NOTES.md#disk-and-logs).

### Common commands

```bash
docker compose ps
docker compose logs -f moodle
docker compose restart moodle
docker compose down
docker compose up -d
```

Other procedures — offline install from images, custom language packs, cleanup —
are in [NOTES.md](NOTES.md).

## TLS and domain

In `Caddyfile`, replace `:80` with your domain:

```text
lms.example.vn {
```

Caddy obtains and renews Let's Encrypt certificates automatically. After the
change, update `$CFG->wwwroot`, set `$CFG->sslproxy = true` when running behind a
proxy, replace URLs in the database and purge caches.

## Security

- Only ports 22, 80 and 443 are open. MySQL and Redis are not exposed.
- SSH uses key authentication; password and `root` logins are disabled.
- `.env` is mode `600`; the MySQL root, MySQL application and Redis passwords
  must differ.
- `config.php` reads the database password from `MOODLE_DB_PASSWORD`.
- Caddy sends `Strict-Transport-Security` on HTTPS, sets `Server: LMS-System`,
  and adds `Content-Security-Policy`, `X-Content-Type-Options`,
  `Referrer-Policy`, `Cross-Origin-Opener-Policy` and `Permissions-Policy`. The
  policy allows only `'self'` plus the YouTube sources Moodle uses. Apache sets
  `ServerTokens Prod` and `ServerSignature Off`.
- Caddy allows 30 `POST` requests per minute per IP on `/login/index.php` and
  `/login/token.php`, complementing Moodle's account lockout.
- `moodle/public/.htaccess` keeps schema files and development directories out
  of the webroot.
- Enable automatic OS security updates and test restores regularly.

## Configuration

Defaults work for a 4 GB host. The main knobs:

| Area | Default | Where |
|---|---|---|
| Apache threads / PHP-FPM children | computed; 40 / 24 on 4 GB | `.env` |
| MySQL durability | `innodb-flush-log-at-trx-commit=2`, `sync-binlog=0` | `docker-compose.yml` |
| PHP limits | upload and post 200 MB, memory 1 GB, no execution limit | `php/` |
| Redis memory | 256 MB, `allkeys-lru` | `docker-compose.yml` |

Formulas, trade-offs and per-load values are in
[NOTES.md](NOTES.md#ram-and-workers) and
[NOTES.md](NOTES.md#mysql-tuning).

## Documentation

- [NOTES.md](NOTES.md) — performance, tuning and troubleshooting.
- [LIMITATIONS.md](LIMITATIONS.md) — known limits and proposed fixes.
- Vietnamese guides in `docs/` (not part of the repo):

| File | Contents |
|---|---|
| `HƯỚNG DẪN TRIỂN KHAI HỆ THỐNG LMS.md` | Deploy from an empty server to production |
| `HƯỚNG DẪN THAY ĐỔI DOMAIN HỆ THỐNG LMS.md` | Change the access address and enable HTTPS |
| `HƯỚNG DẪN NÂNG CẤP HỆ THỐNG LMS.md` | Upgrade versions, verify, and roll back |
| `HƯỚNG DẪN DI TRÚ HỆ THỐNG LMS.md` | Move the system to a new server |
| `CẤU TRÚC VÀ CẤU HÌNH HỆ THỐNG.md` | Directory layout and configuration files |

## License

PolyForm Noncommercial 1.0.0. See `LICENSE-EE.md`. Noncommercial use only.
