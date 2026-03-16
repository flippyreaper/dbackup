<div align="center">

# ⚡ dbackup

**Docker named-volume backup manager**
Incremental · Deduplicated · Compressed · Themeable

Built on [BorgBackup](https://borgbackup.readthedocs.io) with a [gum](https://github.com/charmbracelet/gum) TUI.

</div>

---

## Overview

Two modes:

| Mode | Script | Use case |
|------|--------|----------|
| **Interactive TUI** | `dbackup.sh` | Manual backups, restore, repo management |
| **Headless** | `cron-dbackup.sh` | Cron jobs, scripted runs, plain terminal output |

---

## Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/flippyreaper/dbackup/main/install.sh | sudo bash
```

The installer will:
- Install `borgbackup` and `gum` if missing
- Clone this repo to `/opt/dbackup/`
- Prompt for repo paths, compose directory, and cron schedule
- Write `/opt/dbackup/config`
- Set up fish shell aliases (`dbackup`, `dbackupold`)
- Add a root crontab entry

---

## Requirements

- [`borgbackup`](https://borgbackup.readthedocs.io) — `apt install borgbackup`
- [`gum`](https://github.com/charmbracelet/gum) — Charmbracelet TUI toolkit (TUI only)
- `python3`, `tac`, `awk`, `git` — standard on most systems

<details>
<summary>Install gum manually</summary>

```bash
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list
sudo apt update && sudo apt install gum
```

</details>

---

## File Layout

```
/opt/dbackup/
├── dbackup.sh          # interactive gum TUI
├── cron-dbackup.sh     # headless cron script
├── install.sh          # automated installer
├── repo/               # default borg repository
├── logs/               # log files (30-day retention)
├── config              # persistent settings (gitignored)
└── README.md
```

---

## Interactive Menu

```
⚡  Backup all volumes
🎯  Backup selected volumes
🚫  Backup all except...
📥  Restore from backup
🗑  Delete backups            ← delete borg archives
💣  Delete volumes            ← delete Docker volumes
📋  List volumes
📦  Repository info           ← grouped by volume, newest first, with sizes
🔮  Dry run (preview)
🔄  Migrate bind mount → volume
📁  Change repo path          ← persists to config
🎨  Choose theme
🚪  Quit
```

---

## Themes

Switch themes live from `🎨 Choose theme` in the menu. Selection persists across sessions.

| Theme | Style |
|-------|-------|
| **Miami Vice** *(default)* | Neon cyan & hot pink |
| **Nord** | Arctic blues & aurora pastels |
| **Dracula** | Deep purple & bright accents |
| **Gruvbox** | Warm retro earth tones |
| **Catppuccin** | Soft mocha pastels |

---

## CLI Flags

```bash
# Backup
sudo dbackup --only vol1,vol2          # backup specific volumes
sudo dbackup --exclude vol1,vol2       # backup all except these
sudo dbackup --no-stop                 # skip container stop/start
sudo dbackup --dry-run                 # preview, no changes
sudo dbackup --list                    # show volumes with sizes
sudo dbackup --repo /path/to/repo      # override repo path for this run

# Restore
sudo dbackup --restore                 # interactive restore menu
sudo dbackup --restore latest          # restore all from latest archives
sudo dbackup --restore ARCHIVE_NAME    # restore specific archive
sudo dbackup --restore-to /tmp/out     # extract to custom directory
```

---

## Backup Behaviour

1. Discovers all **named** Docker volumes (skips anonymous hash-named volumes)
2. Stops **apps first**, then **databases** (60 s grace period)
   - Expands to full compose projects — bind-mount-only siblings included
3. Backs up each volume via `borg create` (`zstd,3` compression)
4. Backs up all compose configs from `COMPOSE_DIR`
5. Prunes old archives — keeps last **14 daily** per volume
6. Runs `borg compact` to reclaim freed space
7. Restarts **databases first** (5 s wait), then apps
8. Prints a summary table: status · size · duration · total time

### DB Detection

Containers whose image matches any of:
`postgres` · `mariadb` · `mysql` · `mongo` · `redis` · `valkey` · `memcached` · `influxdb` · `clickhouse` · `cockroach` · `timescaledb`

---

## Restore Behaviour

- **Restore all** — every group from its latest archive
- **Restore selected** — checkbox multi-select, then latest-for-all or pick per volume
- Stops all containers in affected compose projects (apps first, then DBs)
- Restarts **DBs first → 5 s → apps**
- Creates volume + `_data` dir automatically if missing

---

## Migrate Bind Mount → Named Volume

Converts bind-mount directories into proper Docker named volumes — in place, without data loss.

1. Discovers all directory bind mounts across running containers
2. Multi-select which mounts to migrate
3. Confirm or rename the new volume names
4. Stops affected containers (compose-aware)
5. Creates the named volume and copies data via `alpine` container
6. Updates compose file automatically (handles relative and absolute paths, preserves comments and formatting)
7. Offers to restart containers immediately

> The original bind-mount directory is left untouched as a fallback.

---

## Delete Volumes

- Multi-select named volumes with sizes shown
- Displays which containers use each selected volume (with state)
- Stops running containers first if needed
- Confirmation defaults to **No** — destructive operation

---

## Cron Setup

```bash
# Edit root crontab
sudo crontab -e

# Example: run nightly at 02:30, backing up to an external drive
30 2 * * * /opt/dbackup/cron-dbackup.sh --repo /media/backup/dbackup
```

Logs are written to `LOG_DIR/backup-<timestamp>.log`. No output redirection needed.

---

## Configuration

Set at the top of `dbackup.sh`, or via `/opt/dbackup/config` (written by the installer and `Change repo path`):

| Variable | Default | Description |
|----------|---------|-------------|
| `BORG_REPO_PATH` | `/opt/dbackup/repo` | Borg repository path |
| `ACTIVE_THEME` | `miami` | Active color theme |
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

ANSI codes are stripped. Auto-deleted after 30 days.

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

# Break a stale lock (if a backup was interrupted)
sudo borg break-lock /opt/dbackup/repo
```
