# Moodle LMS — Docker Skeleton

**English** | [Tiếng Việt](README.vi.md)

A Moodle 5.x deployment skeleton built with Docker Compose: reverse proxy,
automatic TLS, production PHP, MySQL, Redis, cron and backups. The goal is to
stand up an LMS on a Linux server with a single start command.

The repository holds only the configuration skeleton and two Moodle files.
Moodle source, `moodledata/`, `backup/`, `logs/`, `.env` and internal
documentation stay out of the repo (see `.gitignore`). The exceptions are
`moodle/public/.htaccess`, an important Apache configuration file, and
`moodle/config.php`, which holds no secret: the database password is read from
`MOODLE_DB_PASSWORD`.

Sizing, tuning and fixes for problems seen in operation are in
[NOTES.md](NOTES.md). Known limits and proposed fixes are in
[LIMITATIONS.md](LIMITATIONS.md). Detailed guides (Vietnamese, with copy-paste
commands) are in `docs/`.

## Components

| Service | Image | Role | Ports |
|---|---|---|---|
| `caddy` | build `./caddy` (`moodle-caddy:2.11`) | Reverse proxy (Caddy 2.11 + rate limit), automatic TLS, security headers | 80, 443, 443/udp |
| `db` | `mysql:9.7` | MySQL 9.7 LTS, `utf8mb4` | internal 3306 |
| `redis` | `redis:8.12` | Cache and sessions, 256 MB limit | internal 6379 |
| `moodle` | build `./php` (`moodle-web:5.3`) | Apache 2.4 event MPM + PHP-FPM 8.5, webroot `/var/www/html/public` | internal 80 |
| `socket-proxy` | build `./cetusguard` (`moodle-cetusguard:v1`) | Filters the Docker API down to exec calls in the Moodle container | internal 2375 |
| `cron` | `mcuadros/ofelia:0.3` | Moodle cron, restic backup (database and files), log rotation | not exposed |

Only `caddy` publishes ports. `db`, `redis` and `moodle` are reachable only on
`moodle_net`; `cron` and `socket-proxy` share the separate internal `socket_net`
network, which has no outside route.

## Quick start

```bash
cp .env.example .env
# edit .env: set passwords, MOODLE_WWWROOT, PUID/PGID (match `id -u` on the host)
chmod 600 .env
docker compose build
docker compose up -d
```

Wait for all services to become `healthy` (`docker compose ps`), then open the
site URL. Step-by-step instructions, verification commands and troubleshooting
are in [docs/HƯỚNG DẪN TRIỂN KHAI HỆ THỐNG LMS.md](docs/HƯỚNG%20DẪN%20TRIỂN%20KHAI%20HỆ%20THỐNG%20LMS.md).

## Operations at a glance

```bash
docker compose ps                          # status
docker compose logs -f moodle              # logs
docker compose restart moodle              # restart one service
bash scripts/restic-backup.sh             # backup now
bash scripts/fix-perms.sh --check          # permission check
```

Full command reference: [NOTES.md](NOTES.md).

## Documentation

- [NOTES.md](NOTES.md) — performance, tuning, troubleshooting, backup/restore.
- [LIMITATIONS.md](LIMITATIONS.md) — known limits and proposed fixes.
- `docs/` — Vietnamese guides (deploy, structure, upgrade, migration, domain change, security patching, Git-based upgrade).

## License

PolyForm Noncommercial 1.0.0. See `LICENSE-EE.md`. Noncommercial use only.