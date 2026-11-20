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

## Browser caching and compression

Two settings decide how much work the browser repeats on every page change. The
server itself is fast: the home page answers in 80 to 100 ms and login in 37 to
51 ms. What made navigation feel sluggish was the client side.

### JavaScript cache

`moodle/config.php` sets:

```php
$CFG->cachejs = true;
```

Keep it in `config.php` rather than the database. Moodle forces the value from
there, and `admin/cli/cfg.php` refuses to change it with
`The configuration variable $CFG->cachejs is set in config.php, unable to change.`
The site administration page shows the same setting as forced. The benefit is
that the value survives a database restore.

With the cache off, every asset URL contains `-1` and responses carry an
`Expires` two seconds in the future, so each navigation revalidates about 76
JavaScript and ESM files. With the cache on, URLs carry the Moodle revision,
files are sent minified, and the headers are:

| Asset | Header |
|---|---|
| `/lib/javascript.php/<rev>/...` | `Cache-Control: public, max-age=7776000, immutable` |
| `/core/esm/<rev>/...` | `Cache-Control: public, max-age=31536000, immutable` |

After changing the setting, purge caches and restart the web container:

```bash
docker compose exec -u www-data moodle php admin/cli/purge_caches.php
docker compose restart moodle
```

The restart is required. OPcache runs with `opcache.validate_timestamps=0`, so an
edited `config.php` is ignored until PHP starts again.

Measured in a browser on this host:

| Metric | Cold cache | Warm cache |
|---|---|---|
| DOMContentLoaded, home page | 8.4 s | 0.44 s |
| Resources served from browser cache | 0 of 68 | 46 of 46 |
| Asset transfer | about 1.0 MB | 0 bytes |
| Course page DOMContentLoaded | n/a | 0.37 s |
| Login page DOMContentLoaded | n/a | 0.31 s |

Before the change every navigation behaved like the cold column. The first visit
after a purge is still heavy, because Moodle sends one large `core/first.js`
aggregate; later navigations reuse it from the browser cache.

### Response compression

`Caddyfile` compresses proxied responses:

```text
encode gzip
```

`gzip` is deliberate. This Caddy build does compress static files with `zstd`,
but it does not apply `zstd` to proxied HTML, and on the files it does handle
`zstd` produced larger output than `gzip` (588 versus 543 bytes for `slick.css`,
5553 versus 4557 for `animate.css`). With `gzip` the home page drops from 93.5 KB
to 14.3 KB and login from 45 KB to about 10 KB.

Apache already compresses CSS and JavaScript with `gzip`, so Caddy passes those
through instead of encoding them twice.

## Security headers

`Caddyfile` sets the response headers for every page: `Server`,
`X-Content-Type-Options`, `Referrer-Policy`, `Cross-Origin-Opener-Policy`,
`Permissions-Policy` and `Content-Security-Policy`. The site identifies itself as
`LMS-System`. The policy uses only `'self'` for the system itself, so it works on
any domain or port without editing.

YouTube is the only external source allowed. The videojs player loads
`https://www.youtube.com/iframe_api` as a script, shows posters from
`https://img.youtube.com`, and embeds the player from `youtube-nocookie.com` or
`youtube.com`. Everything else is refused: Vimeo, Google Drive and external
images in course content are blocked. The theme does not load Google Fonts, so
`fonts.googleapis.com` and `fonts.gstatic.com` are not in the policy.

`script-src` still needs `'unsafe-inline'` and `'unsafe-eval'`. Moodle prints
inline scripts on every page and TinyMCE calls `new Function`, so a nonce-based
policy is not possible without patching core.

Check a change with a temporary page in the webroot, then delete it:

```html
<img src="https://example.com/logo.png">
<img src="https://img.youtube.com/vi/ID/0.jpg">
```

The first must be blocked and the second must load. The browser console names
every blocked resource with the directive that refused it.

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
copy those separately. The database lives in the `moodle_db_data` volume, and
`backup/restic` contains a recent dump of it. Image names are fixed as
`moodle-server-moodle:5.3`, `moodle-caddy:2.11` and `moodle-cetusguard:v1`,
so the directory can have any name.

### Trying PHP 8.6

Tested 2026-11-20. `php:8.6-fpm` exists and Moodle 5.3 runs on it, but the
image cannot boot yet:

- `phpredis` 6.3.0 does not compile. `zval_dtor`, `XtOffsetOf`,
  `php_hash_bin2hex` and `ZEND_WRONG_PARAM_COUNT` are gone from PHP 8.6; only
  master builds, so the Dockerfile would have to pin commit `a6ce1e6`.
- Moodle's `composer.lock` pins `ezyang/htmlpurifier`, `lcobucci/jwt`,
  `league/oauth2-server`, `openspout/openspout` and `slim/slim`, all capped at
  `~8.5.0`. The entrypoint runs `composer install` at boot, so the container
  restart-loops before Apache starts.

The PHP code itself is fine: with the composer step skipped, cron,
`purge_caches.php` and `check_database_schema.php` all passed on 8.6.

To back out, restore `php/Dockerfile` and run `docker compose up -d --no-build`
while the old image is still present, or reload `backup/images/` as above.
Retry when a Moodle release allows 8.6 in its lock file and phpredis ships a tag
that compiles on it.

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

### Restic backup of files and database

Two kinds of data must stay in step: rows in MySQL and files under
`moodledata`. One nightly job captures both as two restic snapshots tagged `db`
and `files`, so each half can be restored on its own and each half can have its
own retention. Ofelia runs `nice -n 19 sh /scripts/restic-job.sh` in `moodle_web`
at 00:00 (`Asia/Ho_Chi_Minh`).

In order, the job:

1. Initialises `backup/restic` if the repository does not exist yet.
2. Dumps the Moodle database to `/backup/dbdump/moodle.sql` with
   `mysqldump --single-transaction --quick --skip-lock-tables`, connecting to
   `db` as the Moodle account. The PHP image installs `default-mysql-client`
   for this, and the dump is created with mode `600`.
3. Aborts if the dump is empty or has no `CREATE TABLE`, before touching the
   repository, so the previous snapshots stay valid.
4. Backs the dump up as one snapshot with host `moodle` and tag `db`.
5. Backs up `/var/www/moodledata` as a second snapshot with host `moodle` and
   tag `files`, excluding `cache`, `localcache`, `temp`, `sessions`, `muc`,
   `environment`, `antivirus_quarantine` and `trashdir`. All are regenerated or
   disposable.
6. Deletes the plain SQL file as soon as restic finishes, so `backup/` never
   keeps an unencrypted copy.
7. Forgets old snapshots and prunes: `--tag db --keep-last 2` and
   `--tag files --keep-daily 7`, then one `restic prune` to actually free the
   chunks no snapshot uses.

Two snapshots instead of one is what makes the 2-copy limit possible: a single
combined snapshot can only be kept or dropped as a whole, so keeping 2 would
drop the files too. The two snapshots are two seconds apart, so they describe
almost the same moment.

`--single-transaction` gives a consistent InnoDB view of the database while
the site keeps running. The files are read a few seconds later, so a file
uploaded between the two steps can be newer than the row that points to it; an
extra file is harmless. A file deleted in that gap is the only small
inconsistency to accept.

Why not copy the MySQL volume with restic directly? InnoDB spreads data across
the tablespace, redo log and undo log; copying those files while the server
runs can produce a corrupt set. The dump is the supported way to get a
point-in-time copy.

Restic splits data into chunks, stores each chunk once and compresses it, so
growth stays small on its own: `filedir` names files by content hash, and a
22 MB dump that changed little added 8.7 MB of input but only 1.0 MB stored in
the test run. The dump is still a full copy of the database inside the
snapshot, which is why the `db` history is capped at 2 instead of 7. The job
uses the MariaDB client that Debian ships against MySQL 9.7; the dump restores
into the same server with all 499 tables and the same `mdl_config.version`.

The cleanup runs after the backup, and `set -e` stops the script if the dump or
backup fails, so a bad run never deletes the last good snapshots. Restic keeps
the oldest snapshot while there are fewer than 7 days of `files` snapshots;
after a week that count settles at exactly 7, and `db` settles at 2. Snapshots
tagged `full` by the previous single-snapshot setup are not matched by either
policy; remove the last one with `restic forget <id> --prune`. Offsite copies
are the remaining task in
[LIMITATIONS.md](LIMITATIONS.md#fix-3-prune-and-copy-backups-off-the-server).

Run a backup by hand from the host, which is the same flow Ofelia uses:

```bash
bash scripts/restic-backup.sh                 # backup now, then show 3 snapshots and repo size
docker exec moodle_web restic snapshots
docker exec moodle_web restic ls latest --tag db /backup/dbdump
docker exec moodle_web restic stats --mode restore-size
docker exec moodle_web restic check --read-data-subset=5%
```

`scripts/restic-backup.sh` checks that `moodle_web` is running and then calls
`sh /scripts/restic-job.sh` inside the container, where restic, `mysqldump`,
`/backup/restic` and `/var/www/moodledata` exist. The wrapper exists so manual
runs need no long `docker exec` line and so the schedule and manual runs share
one code path.

### Cleaning the restic repository

`scripts/restic-clean.sh` removes backup history on purpose; it is not part of
normal operation. The default mode runs
`restic forget --keep-last 0 --prune --unsafe-allow-remove-all`, which deletes
every snapshot for host `moodle` — database dump and files — but keeps the
repository and the password in `.env`. `--repo` deletes `backup/restic` itself,
so the next backup initialises a fresh repository. `--dry-run` prints what would
be removed.

```bash
bash scripts/restic-clean.sh --dry-run        # see the snapshots that would go
bash scripts/restic-clean.sh                  # delete snapshots, keep the repo
bash scripts/restic-clean.sh --repo --dry-run # see the repo size before deleting it
bash scripts/restic-clean.sh --repo           # delete backup/restic
```

Both destructive modes ask you to type `XOA`. `--repo` runs `rm -rf` as root
inside the container, so the files owned by root disappear without `sudo`; if
the container is stopped, the script falls back to `sudo rm -rf`. After a
default clean the repository shrinks to a few files but stays valid, and the
next backup stores the whole tree again.

Prune rewrites pack files, so it needs free space and takes longer as the
repository grows. If it ever fails on a full disk, the snapshots stay intact;
free space and run the retention again:

```bash
docker exec moodle_web restic forget --host moodle --group-by host --tag db --keep-last 2
docker exec moodle_web restic forget --host moodle --group-by host --tag files --keep-daily 7
docker exec moodle_web restic prune
```

### Restoring the database and files

`scripts/restic-restore.sh` runs on the host and restores both halves by
default. `--db` restores only the database dump, `--files` restores only
`moodledata`, and the two flags can be combined.

Staging is the default: it restores into `backup/restore_<time>`, changes the
owner so the deployment account can read the files, and prints the file count
of the snapshot next to the current count. For the database it prints the path
of the dump and the import command. Nothing under `moodledata/` or the running
database is touched.

```bash
docker exec moodle_web restic snapshots          # find the ID you want
bash scripts/restic-restore.sh                   # newest snapshot, DB + files
bash scripts/restic-restore.sh --db              # database dump only
bash scripts/restic-restore.sh --files           # moodledata only
bash scripts/restic-restore.sh 9711dea3 --db     # a specific snapshot, DB only
```

The dump lands at `backup/restore_<time>/backup/dbdump/moodle.sql`. It is a
plain SQL file, so delete the staging directory after the drill or restore.

In-place is the real recovery: it asks for confirmation, stops `moodle` and
`cron`, imports the dump and/or copies the files, starts the services again,
waits for the health check and purges caches.

```bash
bash scripts/restic-restore.sh --db --in-place     # database only
bash scripts/restic-restore.sh --files --in-place  # files only
bash scripts/restic-restore.sh --in-place          # both
```

The database import uses the `root` account inside `moodle_db`, so it works even
when the target database or its grants differ from what the Moodle account can
see. The dump contains `DROP TABLE IF EXISTS` for every table it captured, so
each restored table is replaced; tables that exist only in the live database are
left alone, which Moodle ignores. The script also strips a leftover
`SET @@GLOBAL.GTID_PURGED` line before importing, so older dumps still load.

`--db` is why `moodle_db` no longer mounts `/backup` or `./scripts`, and why
Ofelia no longer has exec permission on that container: the import runs from
the host over stdin.

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

### Exporting the dump as a plain SQL file

`scripts/restic-export.sh` is the manual escape hatch. It restores the newest
`db` snapshot inside the container, copies `moodle.sql` to the host with
`docker exec cat`, and removes the container copy. The default path is outside
the deployment directory, `~/moodle-dump_<time>.sql`, with mode `600`.

```bash
bash scripts/restic-export.sh                           # newest db snapshot -> ~/moodle-dump_<time>.sql
bash scripts/restic-export.sh --out=/media/usb/moodle.sql
bash scripts/restic-export.sh 9711dea3 --out=~/old.sql  # a specific snapshot
```

The result is plain SQL, so any MySQL or MariaDB client can import it, and it is
the quickest way to hand a copy to someone who does not have the restic
password. Delete it once it has been moved: an unencrypted database on disk is
exactly what the restic setup avoids.

### Changing RESTIC_PASSWORD

The password encrypts the repository key, so editing only `RESTIC_PASSWORD` in
`.env` leaves existing snapshots unreadable. There are two ways forward.

Keep the snapshots and only change the password, which needs the old password
once:

```bash
docker exec -it moodle_web restic key passwd
```

Then put the new password in `.env` and recreate the container so it sees the
value:

```bash
docker compose up -d moodle
docker exec moodle_web restic snapshots
```

Start over, which is the right choice when the old password is lost or the
history is unwanted:

```bash
# edit RESTIC_PASSWORD in .env first
docker compose up -d moodle
mv backup/restic backup/restic-old     # optional, only if the old snapshots matter
bash scripts/restic-clean.sh --repo    # delete backup/restic, asks for XOA
bash scripts/restic-backup.sh          # init a new repo and take the first snapshot
docker exec moodle_web restic snapshots
docker exec moodle_web restic check
```

The old repository cannot be opened with the new password, so copy it aside
before deleting it if it still has value. Only `moodle_web` runs restic, and it
reads the value from `.env`, so nothing else needs editing.

### Scheduler and Docker API access

Ofelia runs from a file, not from container labels:

```text
ofelia/config.ini   jobs and schedules
ofelia/rules.list   CetusGuard allowlist
command: daemon --config=/etc/ofelia/config.ini
```

Labels were removed from `db` and `moodle`. Label mode needs
`GET /containers/json`, `GET /containers/{id}/json` and the event stream, which
would expose the environment of every container on the host, including
`MYSQL_ROOT_PASSWORD` and `RESTIC_PASSWORD`. File mode needs only `GET /_ping`,
`GET /info` and the exec calls the three jobs actually make.

Only `socket-proxy` mounts `/var/run/docker.sock`, read-only. Ofelia reaches it
at `tcp://socket-proxy:2375` over `socket_net`, a bridge network marked
`internal: true`: no published port, no route outside Docker, and only these two
services are attached.

The proxy image is built locally from `./cetusguard` on top of
`hectorm/cetusguard:v1`. The upstream image is `scratch`, so it has no HTTP
client; the Dockerfile copies only a static busybox for the healthcheck. That
check calls `GET /_ping` every 30 seconds, and `cron` waits for
`service_healthy` before it starts. Because the image is built, it is not part of
`docker compose pull`; `docker compose up -d --build` builds it.

`/_ping`, `/version` and `/info` come from the built-in CetusGuard rules;
everything else is in `ofelia/rules.list`:

```text
POST %API_PREFIX%/containers/moodle_web/exec
POST %API_PREFIX%/exec/%CONTAINER_ID%/start
GET  %API_PREFIX%/exec/%CONTAINER_ID%/json
```

`POST /exec/{id}/start` upgrades the connection to HTTP 101 to stream output;
CetusGuard handles the hijack. Change a container name in `docker-compose.yml`
and you must change it in both `ofelia/config.ini` and `ofelia/rules.list`.

What the proxy rejects, measured against the running stack:

| Request | Result |
|---|---|
| `GET /v1.51/info` | 200 |
| `GET /v1.51/containers/json` | 403 |
| `POST /v1.51/containers/create` | 403 |
| `POST /v1.51/containers/moodle_web/start` | 403 |
| `DELETE /v1.51/containers/moodle_web` | 403 |
| `POST /v1.51/containers/moodle_redis/exec` | 403 |
| `POST /v1.51/containers/moodle_web/exec` | 201 |
| `POST /v1.51/containers/moodle_db/exec` | 403 |

The 403 on `containers/create` is the important one: with the common proxy
setting `CONTAINERS=1` plus `POST=1`, that call is allowed, and a privileged
container mounting `/` turns API access back into host root.

**Remaining risk.** Ofelia still decides *what* runs inside `moodle_web`. A
compromised scheduler can run commands as root there, read `config.php`,
`MYSQL_ROOT_PASSWORD` and `RESTIC_PASSWORD`, change the website, and delete the
restic repository. The database credentials also allow it to change data over
the internal network, even though the proxy no longer grants exec on
`moodle_db`. It cannot create, start, stop or delete containers, read images,
volumes or networks, or reach the host filesystem. Removing the last risk means
removing the scheduler, not tightening the proxy further.

Two operational notes:

- CetusGuard runs on a `scratch` image without zoneinfo, so its own log lines
  are in UTC. Each exec job is still scheduled by Ofelia in `Asia/Ho_Chi_Minh`.
- `socket_net` is a trust boundary. Do not attach other containers to it; any
  container there can use the same allowlist.

To test a single rule by hand, attach a temporary client to `socket_net`:

```bash
docker run --rm --network moodle-server_socket_net curlimages/curl:8.11.1 \
  -s -o /dev/null -w '%{http_code}\n' \
  -X POST -H 'Content-Type: application/json' -d '{}' \
  http://socket-proxy:2375/v1.51/containers/create
```

The answer must be `403`.

### Ofelia schedule format

Ofelia 0.3.x, pinned here to `mcuadros/ofelia:0.3`, still requires the seconds
field first: `0 0 3 * * *` means 03:00:00, while `0 3 * * *` means every hour at
minute 3. The five-field form looks valid and produces no error, so a daily job
silently turns hourly.

```text
0 0 0 * * *   database dump  (00:00)
0 0 0 * * *   log rotation   (00:00)
0 0 0 * * *   restic backup  (00:00)
@every 1m     moodle cron
```

All times are `Asia/Ho_Chi_Minh` because every container receives `TZ` from
`.env`. Change `TZ` and the schedules move with it. The three daily jobs share
the 00:00 slot, so the dump and the file snapshot describe the same moment.

Check what was really registered in the log:

```bash
docker logs moodle_cron_scheduler 2>&1 | grep 'New job registered'
```

Every line prints the schedule, so `0 19 * * *` in that output is the bug.

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

### Container reports unhealthy

`docker compose ps` shows `(unhealthy)` when the healthcheck fails. The `moodle`
check requests `/` and falls back to `/install.php`, with a 120-second start
period and 5 retries, so a normal restart or a short maintenance window does not
mark it failed. Caddy starts only after `moodle` is healthy.

Run the check by hand when it stays unhealthy:

```bash
docker exec moodle_web curl -fsS -o /dev/null -w '%{http_code}\n' http://127.0.0.1/
docker inspect -f '{{json .State.Health}}' moodle_web
docker logs --tail 50 moodle_web
```

The earlier check used `/login/index.php`. That page returns an error while
Moodle is in maintenance mode or serving the upgrade screen after a version
update, so the container was marked unhealthy during upgrades. Wait for the
upgrade to finish instead of restarting mid-way.

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

### Links and cookies point to localhost

`config.php` builds the site URL from `MOODLE_WWWROOT`, so a wrong value shows up
as links to `localhost`, failed redirects and cookies set for the wrong host. The
entrypoint warns at startup when `APP_ENV=production` and the URL still points at
`localhost` or `127.0.0.1`:

```text
[canh bao] MOODLE_WWWROOT=http://localhost trong moi truong production: ...
```

Set the real address in `.env`, recreate the container, then replace URLs already
stored in the database:

```bash
MOODLE_WWWROOT=https://lms.example.vn
MOODLE_SSLPROXY=true
docker compose up -d moodle
```

If HTTPS ends at Caddy, `MOODLE_SSLPROXY=true` is required; without it Moodle
generates `http://` links and can loop between redirects. A second warning appears
when `MOODLE_SSLPROXY=true` but `MOODLE_WWWROOT` is not `https://`.

### Site broken after an upgrade

```bash
docker exec -u www-data moodle_web php /var/www/html/admin/cli/maintenance.php --enable
docker exec -u www-data moodle_web php /var/www/html/admin/cli/upgrade.php --non-interactive
docker exec -u www-data moodle_web php /var/www/html/admin/cli/purge_caches.php
docker exec -u www-data moodle_web php /var/www/html/admin/cli/maintenance.php --disable
```

`config.php` and `moodle/public/.htaccess` are tracked in git; keep both when
unpacking the new source. Take a database backup before the upgrade.

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
- `scripts/log-clean.sh` empties every subdirectory of `logs/` but keeps the
  directory tree. Files that may still be open (no date in the name, today's
  date, or modified in the last 24 hours) are truncated so the running service
  keeps writing to the same file; rotated files are deleted. Run `--dry-run`
  first; it asks for `XOA` before changing anything.
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

### Scheduler cannot reach the proxy

Ofelia reads `ofelia/config.ini` once at startup, so a change needs a restart:

```bash
docker compose up -d --force-recreate socket-proxy cron
docker logs moodle_cron_scheduler 2>&1 | tail -n 20
docker logs moodle_socket_proxy 2>&1 | tail -n 20
```

`connection refused` means the proxy is down or not on `socket_net`. A `403` on a
job means the container name in `ofelia/config.ini` does not match the one in
`ofelia/rules.list`, or the rule file was edited without recreating the proxy.
CetusGuard prints `forbidden` with the method and path at log level 6; raise
`CETUSGUARD_LOG_LEVEL` to `7` for the full request line.

### Wrong time zone

`TZ` in `.env` defaults to `Asia/Ho_Chi_Minh` and compose passes it to every
container, so Apache, PHP, MySQL, Redis, Caddy and Ofelia write timestamps in
Vietnam time. CetusGuard is the exception: its `scratch` image has no zoneinfo,
so its own log lines stay in UTC; the jobs it proxies still follow Ofelia's
timezone. Moodle has its own setting under **Site administration → Location →
Location settings**; keep it on the same zone. If you change `TZ`, update the
Moodle setting too, or the UI and the logs will disagree.

## Known limitations

The full analysis is in [LIMITATIONS.md](LIMITATIONS.md). In short:

- One host only: no failover, no zero-downtime upgrade.
- Restic copies `moodledata/`, but the repository shares the server disk.
- Redis keeps its AOF in `redis_data`; `down -v` still clears sessions.
- No monitoring or alerting; users notice failures first.
- Mutable image tags make rebuilds non-reproducible.
- Upgrades are manual.

The three highest risks have notes in
[LIMITATIONS.md](LIMITATIONS.md#the-three-highest-risks). Restic and the Redis
volume are applied; pruning and offsite copies are not.

## Maintenance checklist

Weekly:

```bash
docker compose ps
docker stats --no-stream
docker exec moodle_db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot "$MYSQL_DATABASE" -e "SELECT COUNT(*) FROM mdl_logstore_standard_log;"'
docker exec moodle_web restic snapshots --latest 1
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost/
```

Monthly:

- Copy the latest dump off the server and test a restore.
- Run `restic check --read-data-subset=5%` and test a file restore.
- Check free disk and `docker system df`.
- Review `logs/php` and `logs/moodle` for repeated errors.
- Run `bash scripts/log-clean.sh --dry-run`, then clean up if `logs/` is large.
- Confirm the OS security updates were applied.
