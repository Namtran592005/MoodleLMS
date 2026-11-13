# Known Limitations

**English** | [Tiếng Việt](LIMITATIONS.vi.md)

An honest list of what this deployment does not do. Severity reflects the impact
when the problem happens in production, not how likely it is. The three highest
risks include a proposed fix; nothing in this file has been applied, so the
stack still runs exactly as before.

## The three highest risks

| # | Risk | Why it matters |
|---|---|---|
| 1 | `moodledata/` is not backed up | User files, submissions and uploads exist only on this disk |
| 2 | Redis has no data volume | Recreating the container logs every user out |
| 3 | Backups share the server disk and never expire | Disk failure loses both data and copies; the folder grows without bound |

## Architecture

| Limitation | Impact | Severity |
|---|---|---|
| Single host | Any reboot, Windows update or WSL restart takes the site down | High |
| Runs in WSL on a desktop | No UPS, static IP, remote access or hardware monitoring | High |
| `moodledata/` is a local bind mount | The `moodle` container cannot be replicated across machines | High |
| No load balancer | No failover, no rolling restarts | Medium |
| Shared CPU and RAM | A long import or backup slows every request | Medium |
| `restart: always` only | Recovers crashed processes, not a dead host | Medium |

## Data and recovery

| Limitation | Impact | Severity |
|---|---|---|
| Database dump once a day | Up to 24 hours of data lost; RPO about 24 h | High |
| `moodledata/` not in the backup script | Uploaded files lost even when the database is intact | High |
| Backup stored on the same disk | Disk failure or ransomware loses every copy | High |
| No binlog | No point-in-time recovery; only the last dump | High |
| Backup files never pruned | `backup/` grows until the disk is full | Medium |
| Restore never rehearsed | Real RTO unknown; likely 30 to 60 minutes | Medium |
| `innodb-flush-log-at-trx-commit=2`, `sync-binlog=0` | Up to one second of committed transactions lost on power failure | Medium |
| Redis data lives in the container layer | `down`/`up` or a rebuild discards sessions and cache | Medium |
| No MySQL replica | No second copy to read from or promote | Medium |

## Performance

| Limitation | Impact | Severity |
|---|---|---|
| 4 GB RAM ceiling | Comfortable to about 100 concurrent users, then swap | Medium |
| 24 PHP-FPM children | More concurrency needs more memory, not more threads | Medium |
| MySQL buffer pool 128 MB by default | Disk reads until tuned to 2 GB or more | Medium |
| `opcache.validate_timestamps=0` | Edited PHP files are ignored until the container restarts | Medium |
| `max_execution_time=300` vs `ProxyTimeout 900` | Web tasks can die at 300 s even though the proxy allows 900 s | Low |
| No CDN or object storage | All traffic and files hit one disk and one CPU | Medium |
| No external search engine | Global search uses the database and slows with size | Low |
| 200 MB upload, 1 GB PHP memory | Two large concurrent uploads can exhaust memory | Low |

## Security

| Limitation | Impact | Severity |
|---|---|---|
| Ofelia mounts the Docker socket | Docker API access is effectively root on the host | High |
| Secrets in plain `.env` | No rotation, no secrets manager, readable by the deploy account | Medium |
| No fail2ban or WAF | Only login endpoints are rate-limited; scanning and abuse are not blocked | Medium |
| Mutable image tags (`mysql:9`, `redis:latest`, `ofelia:latest`) | Rebuilds are not reproducible; upgrades arrive unannounced | Medium |
| No image scanning or signing | Vulnerable base images go unnoticed | Medium |
| No enforced 2FA or SSO | Password-only accounts, no central identity | Medium |
| No antivirus on uploads | Malicious files are stored and served | Low |
| Logs only on local disk | An attacker who gets in can erase the evidence | Low |

## Operations

| Limitation | Impact | Severity |
|---|---|---|
| Manual upgrades | Downtime and human error on every release | High |
| usermenu patch edits core | Breaks or gets overwritten on upgrade | Medium |
| `.htaccess` can be overwritten by a release | Schema files become downloadable until restored | Medium |
| `config.php` not in the repo | A new machine needs manual reconstruction | Medium |
| `docs/` is gitignored | Operational knowledge lives on one machine | Medium |
| No monitoring or alerting | Failures are found by users, not by the team | High |
| Single cron scheduler | If Ofelia stops, no task runs and nothing reports it | Medium |
| No SMTP configured | Password resets and notifications do not send | Medium |
| Time zone set in two places | Cron and logs drift when they disagree | Low |

## Scaling

The design grows vertically only. Reaching about 1000 concurrent users requires
structural changes, not tuning:

1. Move MySQL to its own server.
2. Move `moodledata` to S3 or shared NFS.
3. Move Redis out, or run a cluster.
4. Replicate `moodle` behind a load balancer with shared sessions.
5. Split cron and backup from the web container.

## What is acceptable

For a lab, a demo or a small deployment under about 100 users, most of these are
reasonable trade-offs for a stack that starts with one command. The items worth
fixing even at small scale are the three above. Everything else can wait until
the deployment grows or the data becomes valuable.

## Fix 1: back up `moodledata`

**Current state.** `scripts/db-backup.sh` dumps MySQL only. Files under
`moodledata/filedir` exist in one place.

**Proposed change.** Add `scripts/files-backup.sh` and a second Ofelia job:

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

Schedule it about 30 minutes after the database dump. Run the file backup
second: a file uploaded between the two jobs is an orphan, which is harmless,
while the reverse could leave a database row pointing at a missing file.

**Restore procedure.**

```bash
docker compose stop moodle cron
bash scripts/db-restore.sh backup/moodle_latest.sql
tar -xzf backup/moodledata_YYYY-MM-DD_HH-MM.tar.gz -C .
bash scripts/fix-perms.sh
docker compose start moodle cron
docker exec -u www-data moodle_web php /var/www/html/admin/cli/purge_caches.php
```

**Verify.** Compare file counts before and after:

```bash
find moodledata/filedir -type f | wc -l
tar -tzf backup/moodledata_YYYY-MM-DD_HH-MM.tar.gz | wc -l
```

**Trade-offs.** The archive is as large as `moodledata` (about 100 MB now) and
compression costs CPU during the backup window. If it grows past a few GB,
switch to `rsync --link-dest` snapshots so unchanged files are hard-linked.

## Fix 2: give Redis a data volume

**Current state.** AOF is enabled (`appendonly yes`) but `/data` is not mounted.
The AOF file sits in the container layer, so `docker compose down` followed by
`up`, or any rebuild, discards it. Users are logged out and caches are cold.

**Proposed change.** In `docker-compose.yml`:

```yaml
services:
  redis:
    volumes:
      - ./logs/redis:/var/log/redis
      - redis_data:/data

volumes:
  redis_data:
```

Then recreate the service once:

```bash
docker compose up -d redis
```

**Verify.** Write a key, restart, read it back:

```bash
docker exec moodle_redis sh -c 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli set healthcheck ok'
docker compose restart redis
docker exec moodle_redis sh -c 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli get healthcheck'
```

**Trade-offs.** The volume is deleted by `docker compose down -v`, which is
correct: sessions and cache are disposable. It does not remove the need for a
database session fallback. Alternative: switch Moodle sessions to the database
handler, which survives Redis entirely but loses some speed.

## Fix 3: prune and copy backups off the server

**Current state.** `scripts/db-backup.sh` writes one timestamped dump per run
plus `moodle_latest.sql`, and never deletes anything. Everything stays on the
same disk as the database.

**Proposed change.** Keep 14 daily dumps, one weekly copy, and send both database
and file backups to remote storage:

```bash
# after a successful dump
find backup -maxdepth 1 -name 'moodle_*.sql' -mtime +14 -delete
if [ "$(date +%u)" = "7" ]; then
  cp backup/moodle_latest.sql "backup/weekly_$(date +%F).sql"
fi
find backup -maxdepth 1 -name 'weekly_*.sql' -mtime +56 -delete

rclone copy backup/moodle_latest.sql remote:moodle/db/
rclone copy backup/moodledata_latest.tar.gz remote:moodle/files/
```

Two details matter more than the exact numbers:

- Prune only after the new dump succeeded, otherwise a failed run deletes the
  last good copy.
- Copy off the server after pruning, so the remote copy is the one you just
  validated.

**Verify.** Confirm the newest dump is recent and readable:

```bash
ls -lh backup/moodle_latest.sql
head -5 backup/moodle_latest.sql
rclone lsl remote:moodle/db/ | tail -3
```

**Trade-offs.** Remote storage costs money and rclone credentials sit on the
host (keep them in a `600` file). Restoring from remote requires downloading
first, which adds time to the RTO. Do a restore drill after the first month.
