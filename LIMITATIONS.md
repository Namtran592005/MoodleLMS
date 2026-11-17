# Known Limitations

**English** | [Tiếng Việt](LIMITATIONS.vi.md)

An honest list of what this deployment does not do. Severity reflects the impact
when the problem happens in production, not how likely it is. Two of the three
highest risks were fixed on 2026-11-13: Redis now has a data volume and
`moodledata` is backed up with restic. Retention followed on 2026-11-14: the job
keeps 7 days and prunes the rest. The remaining one, copies outside the server,
is still open.

## The three highest risks

| # | Risk | Why it matters |
|---|---|---|
| 1 | `moodledata` backup — fixed 2026-11-13 | Was: user files, submissions and uploads existed only on this disk |
| 2 | Redis data volume — fixed 2026-11-13 | Was: recreating the container logged every user out |
| 3 | Backups only on the server disk | Disk failure loses every copy; snapshots are pruned after 7 days |

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
| File backup and database dump run together | A file uploaded during the backup window is orphaned on restore, not lost | Low |
| Backup stored on the same disk | Disk failure or ransomware loses every copy | High |
| No binlog | No point-in-time recovery; only the last dump | High |
| Restore never rehearsed | Real RTO unknown; likely 30 to 60 minutes | Medium |
| `innodb-flush-log-at-trx-commit=2`, `sync-binlog=0` | Up to one second of committed transactions lost on power failure | Medium |
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
| Only `gzip` compression | No brotli or zstd for proxied HTML, so text stays larger than the best available | Low |
| HTTP/1.1 only on port 80 | No multiplexing; a first visit is limited to six parallel connections per host | Low |
| No external search engine | Global search uses the database and slows with size | Low |
| 200 MB upload, 1 GB PHP memory | Two large concurrent uploads can exhaust memory | Low |

## Security

| Limitation | Impact | Severity |
|---|---|---|
| Ofelia can exec as root in `moodle_web` and `moodle_db` through the proxy | A compromised scheduler controls the site and its database, but cannot create containers or reach the host | High |
| Secrets in plain `.env` | No rotation, no secrets manager, readable by the deploy account | Medium |
| No fail2ban or WAF | Only login endpoints are rate-limited; scanning and abuse are not blocked | Medium |
| Mutable minor image tags (`mysql:9.7`, `redis:8.10`, `mcuadros/ofelia:0.3`) | Patch releases still arrive without notice; builds are not digest-pinned | Low |
| No image scanning or signing | Vulnerable base images go unnoticed | Medium |
| No enforced 2FA or SSO | Password-only accounts, no central identity | Medium |
| CSP still needs `'unsafe-inline'` and `'unsafe-eval'` | Moodle prints inline scripts and TinyMCE calls `new Function`, so injected inline script is not blocked | Medium |
| CSP allows only YouTube | Vimeo, Google Drive and external images in course content are blocked by design | Low |
| No antivirus on uploads | Malicious files are stored and served | Low |
| Logs only on local disk | An attacker who gets in can erase the evidence | Low |

Only CetusGuard holds `/var/run/docker.sock`, and its allowlist permits nothing
but exec calls on `moodle_web` and `moodle_db` (Fix 4). The scheduler never sees
the socket, cannot create, start or delete containers, and cannot inspect the
environment of other containers.

## Operations

| Limitation | Impact | Severity |
|---|---|---|
| Manual upgrades | Downtime and human error on every release | High |
| `.htaccess` can be overwritten by a release | Schema files become downloadable until restored | Medium |
| `config.php` not in the repo | A new machine needs manual reconstruction | Medium |
| `docs/` is gitignored | Operational knowledge lives on one machine | Medium |
| No monitoring or alerting | Failures are found by users, not by the team | High |
| Single cron scheduler | If Ofelia stops, no task runs and nothing reports it | Medium |
| No SMTP configured | Password resets and notifications do not send | Medium |

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
fixing even at small scale are the ones marked High above, starting with the one
remaining backup risk. Everything else can wait until the deployment grows or the
data becomes valuable.

## Fix 1: back up `moodledata` with restic (applied)

**Status.** Applied on 2026-11-13. The first snapshot holds 5,671 files
(50.1 MiB) and uses 19.9 MiB in the repository; the second run with no changes
added 680 bytes in two seconds. A restore of `filedir` produced 4,653 files,
matching the source exactly, and `restic check` found no errors.

**Before.** `scripts/db-backup.sh` dumped MySQL only. Files under
`moodledata/filedir` existed in one place, and a full `tar` every day would have
written about 50 MB of unchanged data each time.

**Change.** Four small edits:

```text
php/Dockerfile        apt install restic
docker-compose.yml    mount ./scripts:/scripts:ro, pass RESTIC_PASSWORD
                      and RESTIC_REPOSITORY, add an Ofelia job at 00:00
scripts/restic-job.sh job itself: init the repo, back up moodledata, exclude junk
scripts/restic-backup.sh  host wrapper for manual runs
scripts/restic-restore.sh restore to a staging dir or --in-place
scripts/restic-clean.sh   remove snapshots or the whole repository
.env / .env.example   RESTIC_PASSWORD
```

The job runs `nice -n 19 sh /scripts/restic-job.sh` in the `moodle` container.
The script initialises `/backup/restic` on the first run, then backs up
`/var/www/moodledata` with host `moodle` and tag `files`. It excludes `cache`,
`localcache`, `temp`, `sessions`, `muc`, `environment`, `antivirus_quarantine`
and `trashdir`, all of which are regenerated or disposable.

Because `filedir` names files by content hash, unchanged files are never stored
twice. The repository grew from 0 to 22 MB for 50 MB of data.

**Verify.**

```bash
docker exec moodle_web restic snapshots
docker exec moodle_web restic stats --mode restore-size
docker exec moodle_web restic check --read-data-subset=5%
```

**Restore.** `scripts/restic-restore.sh --in-place` asks for confirmation, stops
the site, copies the snapshot over `moodledata/` and starts the services again.
Then restore the database and purge caches:

```bash
bash scripts/restic-restore.sh --in-place
bash scripts/db-restore.sh backup/moodle_latest.sql
docker exec -u www-data moodle_web php /var/www/html/admin/cli/purge_caches.php
```

Without `--in-place` the same script only restores into `backup/restore_<time>`
and prints the file counts, which is safe to run while the site is up.

**Trade-offs.** The repository sits in `backup/` on the same disk, so it
protects against mistakes and software faults, not against losing the disk. The
job keeps 7 daily snapshots and prunes the rest; copies outside the server are
Fix 3. `RESTIC_PASSWORD` is now as important as the data itself: without it the
repository cannot be decrypted, so keep a copy outside the server.

## Fix 2: give Redis a data volume (applied)

**Status.** Applied on 2026-11-13. `redis_data` is mounted at `/data`; a test key
survived `docker compose up -d --force-recreate redis`, and the site returned
200. The text below records what was done.

**Before.** AOF was enabled (`appendonly yes`) but `/data` was not mounted. The
AOF file sat in the container layer, so `docker compose down` followed by `up`,
or any rebuild, discarded it. Users were logged out and caches went cold.

**Change.** In `docker-compose.yml`:

```yaml
services:
  redis:
    volumes:
      - ./logs/redis:/var/log/redis
      - redis_data:/data

volumes:
  redis_data:
```

Applied by recreating the service once:

```bash
docker compose up -d redis
```

**Verify.** Write a key, recreate the container, read it back:

```bash
docker exec moodle_redis sh -c 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli set volume_check ok'
docker compose up -d --force-recreate redis
docker exec moodle_redis sh -c 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli get volume_check'
```

The second command must print `ok`. A plain restart is not enough as a test, because
it keeps the same container and would pass even without a volume.

**Trade-offs.** The volume is deleted by `docker compose down -v`, which is
correct: sessions and cache are disposable. It does not remove the need for a
database session fallback. Alternative: switch Moodle sessions to the database
handler, which survives Redis entirely but loses some speed.

## Fix 3: prune and copy backups off the server

**Status.** Pruning was applied on 2026-11-14: the daily job now runs
`restic forget --keep-daily 7 --prune` after a successful backup. Copies outside
the server are still missing, so this section stays open.

**Before.** Snapshots accumulated forever, so `backup/` grew without bound.

**Remaining change.** Copy both the dump and the repository to remote storage,
for example with rclone:

```bash
rclone copy backup/moodle_latest.sql remote:moodle/db/
rclone sync backup/restic remote:moodle/restic
```

Two details matter more than the exact command:

- Copy only after the local run succeeded, otherwise the remote copy is older
  than what you think it is.
- Keep the rclone credentials in a `600` file, outside the repository.

**Verify.** Confirm the newest dump and snapshot are recent and readable:

```bash
ls -lh backup/moodle_latest.sql
head -5 backup/moodle_latest.sql
docker exec moodle_web restic snapshots --latest 1
rclone lsl remote:moodle/restic | tail -3
```

**Trade-offs.** Remote storage costs money and rclone credentials sit on the
host (keep them in a `600` file). Restoring from remote requires downloading
first, which adds time to the RTO. Do a restore drill after the first month.

## Fix 4: filter the Docker API with CetusGuard (applied)

**Status.** Applied on 2026-11-16. Ofelia no longer mounts the socket.
`socket-proxy` holds it and allows four exec routes. Measured on the running
stack: `containers/create`, `containers/start`, `containers/delete` and
`containers/json` answer `403`; exec create on `moodle_web` and `moodle_db`
answers `201`; the minute cron completes through the proxy.

**Before.** `cron` mounted `/var/run/docker.sock:ro`. `:ro` only prevents writes
to the socket file; every request that reaches the daemon still runs with daemon
privileges, so a compromised Ofelia could create a privileged container mounting
`/` and take the host. Label mode also made Ofelia list and inspect every
container, exposing all environment secrets.

**Change.** Four files:

```text
docker-compose.yml   add socket-proxy (CetusGuard), add internal socket_net,
                     move Ofelia to config mode, remove labels from db and moodle
ofelia/config.ini    the four jobs
ofelia/rules.list    exec create/start/inspect on two named containers
cetusguard/Dockerfile add a static busybox to the scratch image for /_ping
```

Only the proxy keeps the socket. Its API surface is exec on two containers;
everything else is rejected before it reaches the daemon. The proxy is built
locally from `./cetusguard` on top of `hectorm/cetusguard:v1`; the only
addition is the static busybox used by its healthcheck. Ofelia is pinned to
`mcuadros/ofelia:0.3`.

**Verify.**

```bash
docker compose ps
docker logs moodle_socket_proxy 2>&1 | tail -n 10
docker logs moodle_cron_scheduler 2>&1 | grep 'New job registered'
docker exec moodle_cron_scheduler date
```

All six containers must be `Up` and `(healthy)`, four jobs must be registered, and
the date must show `+07`. The rule test in
[NOTES.md](NOTES.md#scheduler-and-docker-api-access) must answer `403` for
`containers/create`.

**Remaining risk.** A compromised Ofelia still runs root commands inside
`moodle_web` and `moodle_db`, because exec is exactly what the scheduler needs.
It can read `config.php`, the database password and `RESTIC_PASSWORD`, alter the
site or the database, and delete local backups. It cannot create, start, stop or
delete containers, read images, volumes or networks, or reach the host
filesystem. Removing this last risk means removing the scheduler, not tightening
the proxy.

**Trade-offs.** One more container and a second network to keep in mind. If the
proxy is down, no scheduled task runs, and the Moodle cron runs every minute, so
the failure is visible quickly. Container names now appear in three places
(`docker-compose.yml`, `ofelia/config.ini`, `ofelia/rules.list`).
