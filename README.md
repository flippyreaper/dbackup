# dbackup

Docker named-volume backup manager using [BorgBackup](https://borgbackup.readthedocs.io) for incremental, deduplicated, compressed backups.

Two modes:
- **`dbackup`** — interactive gum TUI (Miami Vice neon, for manual use)
- **`cron-dbackup.sh`** — spartan terminal output (for cron)

---

## Machines

| Host | IP | Alias |
|------|----|-------|
| lychee | local | `dbackup` |
| banana | `192.168.5.22` | `dbackup` |

Both run `/opt/dbackup/dbackup.sh`. Legacy alias: `dbackupold` → `cron-dbackup.sh`

---

## File Layout

```
/opt/dbackup/
├── dbackup.sh          # gum TUI script
├── cron-dbackup.sh     # spartan cron script
├── repo/               # default interactive repo (borg)
├── cron/               # cron repo — lychee only
├── logs/               # log files (30-day retention)
└── README.md
```

---

## Cron Jobs (root crontab)

| Host | Schedule | Repo |
|------|----------|------|
| lychee | `30 2 * * *` | `/opt/dbackup/cron` |
| banana | `30 2 * * *` | `/media/nextcloud/dbackup` |

Both run `cron-dbackup.sh --repo <path>`.

---

## Requirements

- [`borgbackup`](https://borgbackup.readthedocs.io) — `apt install borgbackup`
- [`gum`](https://github.com/charmbracelet/gum) — via Charm apt repo (TUI only)
- `python3` — for size parsing in repo info
- `tac`, `awk` — standard coreutils

### Install gum

```bash
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list
sudo apt update && sudo apt install gum
```

---

## Interactive Menu (dbackup)

```
⚡  Backup all volumes
🎯  Backup selected volumes
🚫  Backup all except...
♻️   Restore from backup
🗑️   Delete backups        ← delete borg archives
💣  Delete volumes         ← delete Docker volumes
📋  List volumes
📦  Repository info        ← grouped by volume, newest first, with sizes
🔮  Dry run (preview)
🗄️   Change repo path      ← persists for the session
🚪  Quit
```

The repo path can be changed per-session from the menu. To make it permanent, edit `BORG_REPO_PATH` at the top of `dbackup.sh`.

---

## CLI Flags

```bash
# Backup
sudo /opt/dbackup/dbackup.sh --only vol1,vol2          # backup specific volumes
sudo /opt/dbackup/dbackup.sh --exclude vol1,vol2       # backup all except these
sudo /opt/dbackup/dbackup.sh --no-stop                 # skip container stop/start
sudo /opt/dbackup/dbackup.sh --dry-run                 # preview, no changes
sudo /opt/dbackup/dbackup.sh --list                    # show volumes with sizes
sudo /opt/dbackup/dbackup.sh --repo /path/to/repo      # override repo path

# Restore
sudo /opt/dbackup/dbackup.sh --restore                 # interactive restore menu
sudo /opt/dbackup/dbackup.sh --restore latest          # restore all from latest
sudo /opt/dbackup/dbackup.sh --restore ARCHIVE_NAME    # restore specific archive
sudo /opt/dbackup/dbackup.sh --restore-to /tmp/out     # extract to custom directory
```

---

## Backup Behaviour

1. Discovers all named Docker volumes (ignores anonymous hash-named volumes)
2. Stops **apps first**, then **databases** (60s grace period)
   - Expands to full compose projects — bind-mount-only siblings included
3. Backs up each volume via `borg create` with `zstd,3` compression
4. Backs up compose configs from `/opt/docker`
5. Prunes old archives — keeps last **14 daily** per volume
6. Runs `borg compact` to reclaim freed space
7. Restarts **databases first** (5s wait), then **apps**
8. Prints summary table with per-volume size and duration

### DB Detection

Containers whose image name matches:
`postgres`, `mariadb`, `mysql`, `mongo`, `redis`, `valkey`, `memcached`, `influxdb`, `clickhouse`, `cockroach`, `timescaledb`

---

## Restore Behaviour

- **Restore all** — restores every group from its latest archive
- **Restore selected** — checkbox multi-select, then latest-for-all or pick per volume
- Stops all containers in affected compose projects before restoring (apps first, then DBs)
- Restarts **DBs first → 5s → apps**
- Creates volume + `_data` dir automatically if they don't exist yet

---

## Delete Volumes Behaviour

- Multi-select named volumes with sizes shown
- Shows which containers use each selected volume (with state)
- Stops running containers first if needed
- Confirmation defaults to **No** — destructive operation

---

## Configuration

Edit the top of `dbackup.sh`:

| Variable | Default | Description |
|----------|---------|-------------|
| `BORG_REPO_PATH` | `/opt/dbackup/repo` | Borg repository path |
| `LOG_DIR` | `/opt/dbackup/logs` | Log file directory |
| `COMPOSE_DIR` | `/opt/docker` | Docker compose projects root |
| `RETENTION_DAILY` | `14` | Daily archives to keep per volume |
| `BORG_COMPRESSION` | `zstd,3` | Borg compression algorithm |
| `STOP_TIMEOUT` | `60` | Container stop grace period (seconds) |
| `LOG_RETENTION_DAYS` | `30` | Days before log files are deleted |

---

## Archive Naming

```
<volume-name>-<YYYY-MM-DD>_<HHMMss>
```

Examples:
```
postgres-data-2026-03-15_023001
compose-configs-2026-03-15_023045
```

---

## Logs

| Run type | Path |
|----------|------|
| Interactive | `LOG_DIR/menu-<timestamp>.log` |
| Cron | `LOG_DIR/backup-<timestamp>.log` |

ANSI codes are stripped from log files. Auto-deleted after 30 days.

---

## Borg Direct Access

```bash
# List all archives
sudo borg list /opt/dbackup/repo

# Info on a specific archive
sudo borg info /opt/dbackup/repo::postgres-data-2026-03-15_023001

# Mount a backup for browsing
sudo borg mount /opt/dbackup/repo::postgres-data-2026-03-15_023001 /mnt/borg
sudo umount /mnt/borg

# Break a stale lock (if backup was interrupted)
sudo borg break-lock /opt/dbackup/repo
```
