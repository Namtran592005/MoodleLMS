# Notes: Performance and Troubleshooting

**English** | [Tiếng Việt](NOTES.vi.md)

Companion to [README.md](README.md). Nothing here is required to start the
stack; it covers sizing, tuning, maintenance procedures and fixes for problems
seen in operation.

## RAM and workers

### How the entrypoint sizes Apache

```text
MaxRequestWorkers = min(nproc * 16, (available_RAM - reserve) / 64 MB, 150)
```

The reserve is 1.5 GB on a 4 GB host and 2 GB on an 8 GB host. The result is a
thread count for `mpm_event`, not a process count:

```text
ThreadsPerChild = 10
ServerLimit     = ceil(workers / 10)   # rounded up to a multiple of 10
```

So 40 workers means 4 Apache processes with 10 threads each. Containers with
`mem_limit` or `cpus` read the cgroup limit instead of using all host resources.

PHP-FPM settings:

```text
pm.max_children      = 24               # PHP_FPM_MAX_CHILDREN, never above Apache workers
pm.start_servers     = 2 * nproc
pm.min_spare_servers = nproc
pm.max_spare_servers = 4 * nproc
pm.max_requests      = 500
```

### What actually consumes RAM

| Component | Typical share | Notes |
|---|---|---|
| PHP-FPM children | 50 to 90 MB each | Dominant; each is a full process running Moodle |
| OPcache | about 256 MB shared | One copy, shared by all children |
| Apache | about 150 to 250 MB | Threads are cheap; only processes cost much |
| MySQL | 400 MB to 1 GB | Mostly `innodb_buffer_pool_size`, default 128 MB |
| Redis | up to 256 MB | Hard cap with `allkeys-lru` |
| OS and Docker | about 500 MB | Page cache is reclaimable |

The real limit is PHP-FPM: 24 children at 80 MB can reach about 2 GB. That is
why `PHP_FPM_MAX_CHILDREN` matters more than the Apache thread count.

### Check real usage

```bash
docker stats --no-stream
free -h
docker exec moodle_web ps -eo rss,args --sort=-rss | head -15
docker inspect -f '{{.State.OOMKilled}}' moodle_web
```

`rss` is in KB. Look at the top `php-fpm: pool www` processes; the first one is
the master and holds less. Swap use above a few MB on an idle server means the
worker count is too high.

### Symptoms and fixes

| Symptom | Likely cause | Fix |
|---|---|---|
| Random `502 Bad Gateway` | PHP-FPM children killed or crashed | Lower `PHP_FPM_MAX_CHILDREN`, check `OOMKilled` |
| One request hangs, then `504` | Request exceeded `ProxyTimeout 900` | Not a worker issue; see the slow task |
| Container restarts, exit code 137 | OOM kill | Lower children or add RAM |
| Site crawls, disk swap active | Overcommitted RAM | Lower children, then add RAM |
| RAM high but site fast | OPcache and page cache | Normal, leave it alone |

### Values to use

| Host | `APACHE_MAX_REQUEST_WORKERS` | `PHP_FPM_MAX_CHILDREN` |
|---|---|---|
| 4 GB | 40 | 24 |
| 8 GB | 60 to 80 | 40 |
| 16 GB+ | 120 to 150 | 80 to 100 |

On this 4 GB deployment the entrypoint computes 40 / 24, which is the tested
baseline. Raise one step at a time and watch `docker stats` for a day.

## MySQL tuning

`db` starts with:

```text
--innodb-flush-log-at-trx-commit=2
--sync-binlog=0
```

Bulk writes no longer wait for `fsync` after every statement. A custom language
pack checkout dropped from about 320 seconds to 25 to 37 seconds. The trade-off:
a power loss or kernel panic can lose up to one second of committed
transactions, while the database still recovers to a consistent state.

Revert by removing both flags from the `command:` block in `docker-compose.yml`
and running `docker compose up -d db`. Verify at runtime:

```sql
SHOW VARIABLES LIKE 'innodb_flush_log_at_trx_commit';
SHOW VARIABLES LIKE 'sync_binlog';
```

For a slow query, append temporarily to the same `command:` block:

```text
--slow-query-log=1 --slow-query-log-file=/var/log/mysql/slow.log --long-query-time=2
```

The log lands in `logs/mysql/slow.log`. Remove the flags when done; they add I/O
on every query above the threshold.

### Buffer pool by load

| Concurrent users | `innodb_buffer_pool_size` |
|---|---|
| up to 100 | 2 GB |
| about 1000 | 16 to 24 GB |

Set it in the `db` `command:` block and restart the container. The pool should
hold the working set; the database here is only about 44 MB, so 2 GB is already
generous.

## Sizing by load

| Item | Around 100 concurrent users | Around 1000 concurrent users |
|---|---|---|
| Operating system | Ubuntu 26.04 LTS | Ubuntu 26.04 LTS |
| Docker | Engine 24 with Compose v2 | Engine 24 with Compose v2 |
| CPU / RAM | 4 vCPU / 8 GB | 16 vCPU / 64 GB |
| Disk | 100 GB | 500 GB |
| Model | Single server | One large server, or split web and database |

| Setting | 100 users | 1000 users | Location |
|---|---|---|---|
| `innodb_buffer_pool_size` | 2 GB | 16 to 24 GB | `db` `command:` |
| Redis `maxmemory` | 256 to 512 MB | 2 GB | `redis` `command:` |
| `opcache.memory_consumption` | 256 MB | 512 MB | `php/Dockerfile` |
| Apache `MaxRequestWorkers` (threads) | automatic 32–64 | 300 to 500 | `APACHE_MAX_REQUEST_WORKERS` |
| PHP-FPM `pm.max_children` | 24 (default) | 300 to 500 | `PHP_FPM_MAX_CHILDREN` |

Beyond one host, move MySQL to its own server by changing the database host,
then replicate the `moodle` container behind a load balancer.

## Procedures

### Offline install from images

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
`moodle-server-moodle:latest` and `moodle-caddy:latest`, so the directory can
have any name.

### usermenu patch

After install or upgrade:

```bash
bash scripts/patch-usermenu.sh
docker exec -u www-data moodle_web php /var/www/html/admin/cli/purge_caches.php
```

The script stores originals in `backup/usermenu-patch/` and refuses to overwrite
if the source has changed.

### Custom language pack

Open `/admin/tool/customlang/import.php?lng=vi` directly to reach the ZIP form.
The Import item on the menu runs a checkout first, which takes minutes on a
large pack.

- PHP-FPM `request_terminate_timeout` and Apache `ProxyTimeout` are 900 seconds,
  so a single request can finish.
- Every open tab can start another checkout; keep one tab.
- Expect about 60 seconds to import the `vi` pack and about 5 seconds to check it
  in on the reference machine.
- Verify nothing is left unsaved:

```sql
SELECT COUNT(*) FROM mdl_tool_customlang WHERE modified = 1;
```

Zero means the import completed and checked in.

### Webroot .htaccess

`moodle/public/.htaccess` enables the `r.php` router and blocks schema files and
development directories. A new release tarball may overwrite it. Restore:

```bash
git checkout -- moodle/public/.htaccess
install -m 644 moodle/public/.htaccess /path/to/moodle/public/.htaccess
docker exec moodle_web apache2ctl -t
```

Expected results after the change:

| URL | Code |
|---|---|
| `/install.xml` | 403 |
| `/lib/db/install.xml` | 403 |
| `/theme/boost/style/moodle.css` | 200 |
| `/login/index.php` | 200 |

### Restic file backup

`moodledata` holds the real user content: submissions, images, SCORM packages.
`filedir` is immutable — the file name is the content hash — so a full archive
every day copies the same bytes repeatedly. Restic keeps one copy of each block,
which is why the second run of unchanged data adds hundreds of bytes.

What the job does, in `scripts/restic-backup.sh`:

1. Initialise `backup/restic` if the repository does not exist yet.
2. Run `restic backup /var/www/moodledata` with host `moodle` and tag `files`.
3. Exclude `cache`, `localcache`, `temp`, `sessions`, `muc`, `environment`,
   `antivirus_quarantine` and `trashdir`. All are regenerated or disposable.
4. Run `restic forget --keep-daily 7 --prune`, so only the last 7 days remain.

The cleanup runs after the backup, and `set -e` stops the script if the backup
fails, so a bad run never deletes the last good snapshot. Restic also keeps the
oldest snapshot while there are fewer than 7 days in the repository; after a
week the count settles at exactly 7. Today the repository is about 22 MB for
50 MB of data. Offsite copies are the remaining task in
[LIMITATIONS.md](LIMITATIONS.md#fix-3-prune-and-copy-backups-off-the-server).

Manual run and checks:

```bash
docker exec moodle_web sh /scripts/restic-backup.sh
docker exec moodle_web restic snapshots
docker exec moodle_web restic stats --mode restore-size
docker exec moodle_web restic check --read-data-subset=5%
```

Prune rewrites pack files, so it needs free space and takes longer as the
repository grows. If it ever fails on a full disk, the snapshots stay intact;
free space and run it again:

```bash
docker exec moodle_web restic forget --host moodle --tag files --keep-daily 7 --prune
```

### Restoring files

`scripts/restic-restore.sh` runs on the host and has two modes.

Staging is the default: it restores into `backup/restore_<time>`, changes the
owner so the deployment account can read the files, and prints the file count of
the snapshot next to the current count. Nothing under `moodledata/` is touched.

```bash
docker exec moodle_web restic snapshots     # find the ID you want
bash scripts/restic-restore.sh              # newest snapshot
bash scripts/restic-restore.sh 9711dea3     # a specific snapshot
```

In-place is the real recovery: it asks for confirmation, stops `moodle` and
`cron`, copies the files over `moodledata/`, warns if any file is not owned by
the deployment account, starts the services again, waits for the health check
and purges caches.

```bash
bash scripts/restic-restore.sh --in-place
bash scripts/db-restore.sh backup/moodle_latest.sql
docker exec -u www-data moodle_web php /var/www/html/admin/cli/purge_caches.php
```

The staging copy is kept on purpose, so delete `backup/restore_<time>` only
after the site looks right. Restoring copies files from the snapshot but does
not delete files that exist only on disk; those become orphans, which Moodle
ignores. Copied files keep the container's UID, so ownership stays correct; if
the script warns about a different owner, run `bash scripts/fix-perms.sh`.

Two details that cost time when forgotten:

- The repository is written by `root` inside the container, so read it with
  `docker exec` or `sudo` from the host.
- If a restic command is interrupted (for example piped into `head`), it leaves a
  lock behind and the next run fails with "repository is already locked". Remove
  it only when no backup is running:

```bash
docker exec moodle_web restic unlock --remove-all
```

`RESTIC_PASSWORD` lives in `.env` and is passed to the container. Without it the
repository cannot be decrypted, so keep a copy outside the server. To move the
repository later, set `RESTIC_REPOSITORY` in `.env` to an `s3:`, `rclone:` or
`sftp:` target and run `restic init` there once.

## Troubleshooting

### 502 Bad Gateway

PHP-FPM is down or its children were killed.

```bash
docker compose ps
docker logs --tail 50 moodle_web
docker inspect -f '{{.State.OOMKilled}}' moodle_web
```

If it was an OOM kill, lower `PHP_FPM_MAX_CHILDREN` in `.env` and run
`docker compose up -d moodle`.

### 504 after a long request

`ProxyTimeout` is 900 seconds. A 504 means the task itself ran longer, not that
workers are exhausted. Check the Apache and PHP logs, and run long tasks from
CLI instead of the browser.

### Files owned by root

Symptom: permission denied when Moodle writes cache, or new files under
`moodle/` belong to `root`. Cause: `docker exec` without `-u www-data`.

```bash
bash scripts/fix-perms.sh
docker exec -u www-data moodle_web php /var/www/html/admin/cli/purge_caches.php
```

### 403 on install.xml is expected

The webroot rules deliberately deny `install.xml`, `environment.xml`,
`roles_schema.xml`, `*.schema.json` and the `lib/db`, `lib/tests`, `lib/phpunit`
directories. A 403 there is correct. If you need one of those files for
debugging, read it inside the container instead.

### Login loops or lost sessions

Sessions live in Redis. Check it:

```bash
docker exec moodle_redis sh -c 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli ping'
docker compose restart redis
```

If Redis was restarted, users are logged out once. Also confirm the cache
definition still points at `redis` under **Plugins → Caching**.

### Site broken after an upgrade

```bash
docker exec -u www-data moodle_web php /var/www/html/admin/cli/maintenance.php --enable
docker exec -u www-data moodle_web php /var/www/html/admin/cli/upgrade.php --non-interactive
docker exec -u www-data moodle_web php /var/www/html/admin/cli/purge_caches.php
docker exec -u www-data moodle_web php /var/www/html/admin/cli/maintenance.php --disable
```

Keep `config.php` and `moodle/public/.htaccess` when unpacking the new source.
Take a database backup before the upgrade.

### Disk and logs

```bash
docker system df
du -sh moodledata/* backup logs 2>/dev/null
```

- Moodle keeps activity logs for 180 days (`logstore_standard / retentiondays`);
  the cleanup task runs daily. Old rows can still be deleted manually, but do not
  touch `config_log`, `upgrade_log` or `tool_customlang`.
- `scripts/log-rotate.sh` keeps 30 days of Apache, PHP, Caddy, MySQL and Redis
  logs.
- `docker builder prune` reclaims build cache; `docker system prune -a` removes
  unused images and stopped containers without touching data volumes.
- `moodledata/temp`, old source directories and old dumps are safe to delete
  once a newer backup exists.
- Only these two commands remove data:

```bash
docker compose down -v
docker system prune -a --volumes
```

### Uploads fail below the limit

PHP allows 200 MB per file and 200 MB per request:

```bash
docker exec moodle_web php -i | grep -E 'upload_max_filesize|post_max_size|memory_limit'
```

Moodle also has site limits under **Site administration → Security → Site
policies**. A 413 from Caddy or a silent failure usually means the request
exceeded `post_max_size`.

### Wrong time zone

The container uses `TZ` from `.env`. Moodle has its own default under **Site
administration → Location → Location settings**. Both must match, otherwise
cron schedules and log timestamps drift.

## Known limitations

The full analysis is in [LIMITATIONS.md](LIMITATIONS.md). In short:

- One host only: no failover, no zero-downtime upgrade.
- Restic copies `moodledata/`, but the repository shares the server disk.
- Redis keeps its AOF in `redis_data`; `down -v` still clears sessions.
- No monitoring or alerting; users notice failures first.
- Mutable image tags make rebuilds non-reproducible.
- Upgrades are manual and the usermenu patch can break them.

The three highest risks have notes in
[LIMITATIONS.md](LIMITATIONS.md#the-three-highest-risks). Restic and the Redis
volume are applied; pruning and offsite copies are not.

## Maintenance checklist

Weekly:

```bash
docker compose ps
docker stats --no-stream
docker exec moodle_db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot "$MYSQL_DATABASE" -e "SELECT COUNT(*) FROM mdl_logstore_standard_log;"'
docker exec moodle_web restic snapshots --last
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost/
```

Monthly:

- Copy the latest dump off the server and test a restore.
- Run `restic check --read-data-subset=5%` and test a file restore.
- Check free disk and `docker system df`.
- Review `logs/php` and `logs/moodle` for repeated errors.
- Confirm the OS security updates were applied.
