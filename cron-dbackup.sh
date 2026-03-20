#!/usr/bin/env bash
#
# docker-backup.sh — Incremental Docker volume backup using BorgBackup
#
# Usage: sudo docker-backup.sh [OPTIONS]
#
# Backup modes:
#   (no args)              Backup all named volumes + compose configs
#   --only vol1,vol2       Backup only specified volumes
#   --exclude vol1,vol2    Backup all except specified volumes
#   --list                 Show available volumes with sizes
#   --menu                 Interactive menu (volume picker, restore, etc.)
#
# Restore modes:
#   --restore              Interactive archive picker
#   --restore latest       Restore all from most recent archives
#   --restore ARCHIVE      Restore a specific archive
#   --restore-to DIR       Extract to custom directory instead of original path
#
# Options:
#   --no-stop              Don't stop containers before backup (unsafe for DBs)
#   --dry-run              Show what would happen
#   --repo PATH            Override borg repo path
#   -h, --help             Show this help

# ============================================================
# CONFIGURATION
# ============================================================
BORG_REPO_PATH="/opt/dbackup/repo"
VOLUME_BASE="/var/lib/docker/volumes"
COMPOSE_DIR="/opt/docker"
LOG_DIR="/opt/dbackup/logs"
RETENTION_DAILY=14
BORG_COMPRESSION="zstd,3"
TIMESTAMP_FMT="%F_%H%M%S"
LOG_RETENTION_DAYS=30
STOP_TIMEOUT=60

# ============================================================
# GLOBALS
# ============================================================
IS_INTERACTIVE=false
LOG_FILE=""
ACTION="backup"
ONLY_VOLUMES=()
EXCLUDE_VOLUMES=()
NO_STOP=false
DRY_RUN=false
RESTORE_TARGET=""
RESTORE_TO=""
NOW=$(date +"$TIMESTAMP_FMT")

declare -A BACKUP_STATUS
declare -A BACKUP_DURATION
declare -A BACKUP_SIZE
TOTAL_START=0
ERRORS=0

# Containers we stopped (for restart after backup)
STOPPED_CONTAINER_IDS=()
STOPPED_CONTAINER_NAMES=()
STOPPED_DB_IDS=()
STOPPED_DB_NAMES=()
# Containers already stopped before backup (left stopped after backup)
SKIPPED_CONTAINER_IDS=()
SKIPPED_CONTAINER_NAMES=()
SKIPPED_DB_IDS=()
SKIPPED_DB_NAMES=()

# Colors (set later based on tty)
C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_BOLD="" C_DIM="" C_RESET=""

# When true, log() skips terminal output (used during whiptail menu operations)
SILENT_LOG=false

# ============================================================
# UTILITY FUNCTIONS
# ============================================================

setup_colors() {
    if [[ "$IS_INTERACTIVE" == true ]]; then
        C_RED=$'\033[0;31m'
        C_GREEN=$'\033[0;32m'
        C_YELLOW=$'\033[0;33m'
        C_BLUE=$'\033[0;34m'
        C_BOLD=$'\033[1m'
        C_DIM=$'\033[2m'
        C_RESET=$'\033[0m'
    fi
}

log() {
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    local msg="[$timestamp] $*"

    if [[ "$IS_INTERACTIVE" == true ]]; then
        # Print to terminal unless silenced (e.g. while a whiptail dialog is up)
        [[ "$SILENT_LOG" == false ]] && echo "$msg"
        # Write ANSI-stripped copy to log file
        if [[ -n "${LOG_FILE:-}" ]]; then
            printf '%s\n' "$msg" | sed 's/\x1b\[[0-9;]*[mGKHF]//g' >> "$LOG_FILE"
        fi
    else
        # Non-interactive: stdout is already redirected to the log file
        echo "$msg"
    fi
}

log_info()  { log "${C_GREEN}INFO${C_RESET}  $*"; }
log_warn()  { log "${C_YELLOW}WARN${C_RESET}  $*"; }
log_error() { log "${C_RED}ERROR${C_RESET} $*"; }
log_step()  { log "${C_BLUE}>>>>${C_RESET}  $*"; }

die() {
    log_error "$*"
    exit 1
}

require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo "This script must be run as root. Use: sudo $0 $*" >&2
        exit 1
    fi
}

detect_mode() {
    if [[ -t 1 ]]; then
        IS_INTERACTIVE=true
    else
        IS_INTERACTIVE=false
    fi
}

setup_logging() {
    local prefix="${1:-backup}"
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/${prefix}-${NOW}.log"

    if [[ "$IS_INTERACTIVE" == false ]]; then
        # Cron / non-tty: redirect all output straight to the log file
        exec >>"$LOG_FILE" 2>&1
    fi
    # Interactive: log() writes to terminal + appends clean copy to LOG_FILE directly
}

cleanup_old_logs() {
    find "$LOG_DIR" -name '*.log' -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
}

# ============================================================
# BORG HELPERS
# ============================================================

init_repo() {
    export BORG_REPO="$BORG_REPO_PATH"
    export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes

    if ! borg info "$BORG_REPO" &>/dev/null; then
        log_info "Borg repository not found, initializing..."
        if borg init --encryption=none "$BORG_REPO"; then
            log_info "Repository created at $BORG_REPO"
        else
            die "Failed to initialize borg repository at $BORG_REPO"
        fi
    fi

    # Check for lock (concurrent run)
    if borg info "$BORG_REPO" 2>&1 | grep -q "Failed to create/acquire the lock"; then
        die "Repository is locked — another backup may be running. If not, run: borg break-lock $BORG_REPO"
    fi
}

create_archive() {
    local archive_name="$1"
    local source_path="$2"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[dry-run] Would create archive: $archive_name from $source_path"
        return 0
    fi

    (cd "$source_path" && borg create \
        --compression "$BORG_COMPRESSION" \
        --stats \
        "${BORG_REPO}::${archive_name}" \
        .)
}

prune_archives() {
    local glob_pattern="$1"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[dry-run] Would prune archives matching: $glob_pattern"
        return 0
    fi

    borg prune \
        --keep-daily="$RETENTION_DAILY" \
        --glob-archives "${glob_pattern}" \
        "$BORG_REPO" 2>&1 || log_warn "Prune had warnings for pattern: $glob_pattern"

    # Borg 1.2+ supports compact
    borg compact "$BORG_REPO" 2>/dev/null || true
}

# ============================================================
# VOLUME DISCOVERY
# ============================================================

get_named_volumes() {
    local volumes=()
    while IFS= read -r vol; do
        # Skip anonymous volumes (64-char hex names)
        if [[ ! "$vol" =~ ^[0-9a-f]{64}$ ]]; then
            volumes+=("$vol")
        fi
    done < <(docker volume ls -q 2>/dev/null)
    echo "${volumes[@]}"
}

get_volume_size() {
    local vol="$1"
    local path="$VOLUME_BASE/$vol/_data"
    if [[ -d "$path" ]]; then
        du -sh "$path" 2>/dev/null | cut -f1
    else
        echo "0B"
    fi
}

get_containers_using_volume() {
    # Running containers only (used before backup/restore to know what to stop)
    local vol="$1"
    docker ps -q --filter "volume=$vol" 2>/dev/null
}

get_all_containers_using_volume() {
    # All containers (running + stopped) — used after restore to offer starting them
    local vol="$1"
    docker ps -aq --filter "volume=$vol" 2>/dev/null
}

# Known database image patterns — these get started FIRST after restore
DB_IMAGE_PATTERNS="postgres|mariadb|mysql|mongo|redis|valkey|memcached|influxdb|clickhouse|cockroach|timescaledb"

is_db_container() {
    local cid="$1"
    local image
    image=$(docker inspect --format '{{.Config.Image}}' "$cid" 2>/dev/null)
    if [[ "$image" =~ ($DB_IMAGE_PATTERNS) ]]; then
        return 0
    fi
    return 1
}

get_container_name() {
    docker inspect --format '{{.Name}}' "$1" 2>/dev/null | sed 's|^/||'
}

get_container_image() {
    docker inspect --format '{{.Config.Image}}' "$1" 2>/dev/null
}

# ============================================================
# CONTAINER STOP / START (bulk approach)
# ============================================================

# Arrays populated by stop_all_containers, consumed by start_all_containers
# *_IDS / *_NAMES   — were RUNNING → we stopped them → we restart them after backup
# SKIPPED_*         — were already STOPPED → we note them in log, leave them alone
SKIPPED_CONTAINER_IDS=()
SKIPPED_CONTAINER_NAMES=()
SKIPPED_DB_IDS=()
SKIPPED_DB_NAMES=()

stop_all_containers() {
    local -a volumes_to_backup=("$@")
    local -A seen_cid

    STOPPED_CONTAINER_IDS=()
    STOPPED_CONTAINER_NAMES=()
    STOPPED_DB_IDS=()
    STOPPED_DB_NAMES=()
    SKIPPED_CONTAINER_IDS=()
    SKIPPED_CONTAINER_NAMES=()
    SKIPPED_DB_IDS=()
    SKIPPED_DB_NAMES=()

    local -A compose_projects

    # Pass 1: containers directly using each named volume; collect their compose projects
    for vol in "${volumes_to_backup[@]}"; do
        while IFS= read -r cid; do
            [[ -z "$cid" ]] && continue
            seen_cid[$cid]=1
            local proj
            proj=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$cid" 2>/dev/null)
            [[ -n "$proj" ]] && compose_projects[$proj]=1
        done < <(get_all_containers_using_volume "$vol")
    done

    # Pass 2: expand to ALL containers in those compose projects (catches bind-mount-only siblings)
    for proj in "${!compose_projects[@]}"; do
        while IFS= read -r cid; do
            [[ -z "$cid" ]] && continue
            seen_cid[$cid]=1
        done < <(docker ps -aq --filter "label=com.docker.compose.project=$proj" 2>/dev/null)
    done

    # Classify all discovered containers
    for cid in "${!seen_cid[@]}"; do
        local cname state
        cname=$(get_container_name "$cid")
        state=$(docker inspect --format '{{.State.Status}}' "$cid" 2>/dev/null)

        if [[ "$state" == "running" || "$state" == "restarting" ]]; then
            # Running → needs to be stopped before backup, restarted after
            if is_db_container "$cid"; then
                STOPPED_DB_IDS+=("$cid")
                STOPPED_DB_NAMES+=("$cname")
            else
                STOPPED_CONTAINER_IDS+=("$cid")
                STOPPED_CONTAINER_NAMES+=("$cname")
            fi
        else
            # Already stopped → volume backed up safely, leave untouched after
            if is_db_container "$cid"; then
                SKIPPED_DB_IDS+=("$cid")
                SKIPPED_DB_NAMES+=("$cname")
            else
                SKIPPED_CONTAINER_IDS+=("$cid")
                SKIPPED_CONTAINER_NAMES+=("$cname")
            fi
        fi
    done

    local n_running=$(( ${#STOPPED_CONTAINER_IDS[@]} + ${#STOPPED_DB_IDS[@]} ))
    local n_stopped=$(( ${#SKIPPED_CONTAINER_IDS[@]} + ${#SKIPPED_DB_IDS[@]} ))

    # Log already-stopped containers (their volumes are safe to backup as-is)
    if [[ "$n_stopped" -gt 0 ]]; then
        log_info "Already-stopped containers (volumes backed up as-is):"
        for i in "${!SKIPPED_DB_IDS[@]}"; do
            log_info "  ${C_YELLOW}[DB]${C_RESET}  ${SKIPPED_DB_NAMES[$i]} ${C_DIM}(stopped)${C_RESET}"
        done
        for i in "${!SKIPPED_CONTAINER_IDS[@]}"; do
            log_info "  ${C_BLUE}[APP]${C_RESET} ${SKIPPED_CONTAINER_NAMES[$i]} ${C_DIM}(stopped)${C_RESET}"
        done
    fi

    if [[ "$n_running" -eq 0 ]]; then
        log_info "No running containers to stop"
        return 0
    fi

    log_info "Stopping ${C_BOLD}${n_running}${C_RESET} running container(s) (${STOP_TIMEOUT}s grace period)..."

    for i in "${!STOPPED_DB_IDS[@]}"; do
        local cimage
        cimage=$(get_container_image "${STOPPED_DB_IDS[$i]}")
        log_info "  ${C_YELLOW}[DB]${C_RESET}  ${STOPPED_DB_NAMES[$i]} (${cimage})"
    done
    for i in "${!STOPPED_CONTAINER_IDS[@]}"; do
        local cimage
        cimage=$(get_container_image "${STOPPED_CONTAINER_IDS[$i]}")
        log_info "  ${C_BLUE}[APP]${C_RESET} ${STOPPED_CONTAINER_NAMES[$i]} (${cimage})"
    done

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[dry-run] Would stop ${n_running} running container(s)"
        return 0
    fi

    local all_running_ids=("${STOPPED_DB_IDS[@]}" "${STOPPED_CONTAINER_IDS[@]}")
    docker stop --time "$STOP_TIMEOUT" "${all_running_ids[@]}" &>/dev/null
    log_info "All running containers stopped"
}

# Track compose project dirs already started in this cycle to avoid duplicate up calls
declare -A _STARTED_COMPOSE=()

_reset_started_compose() { _STARTED_COMPOSE=(); }

# Start a single container: uses docker compose up -d if it's a compose container,
# otherwise falls back to docker start. Deduplicates per compose project dir.
start_container() {
    local cid="$1"
    local project workdir
    project=$(docker inspect \
        --format '{{index .Config.Labels "com.docker.compose.project"}}' \
        "$cid" 2>/dev/null)
    workdir=$(docker inspect \
        --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' \
        "$cid" 2>/dev/null)

    if [[ -n "$project" && -n "$workdir" && -d "$workdir" ]]; then
        if [[ -n "${_STARTED_COMPOSE[$workdir]+x}" ]]; then
            # Already started this project via compose this cycle
            return 0
        fi
        _STARTED_COMPOSE[$workdir]=1
        log_info "    compose up -d  [project: $project]"
        if ! (cd "$workdir" && docker compose up -d >/dev/null 2>&1); then
            log_warn "    docker compose up -d failed for '$project', falling back to docker start"
            docker start "$cid" >/dev/null 2>&1
        fi
    else
        docker start "$cid" >/dev/null 2>&1
    fi
}

start_all_containers() {
    local n_running=$(( ${#STOPPED_DB_IDS[@]} + ${#STOPPED_CONTAINER_IDS[@]} ))

    if [[ "$DRY_RUN" == true ]]; then
        if [[ "$n_running" -gt 0 ]]; then
            log_info "[dry-run] Would restart ${n_running} previously-running container(s) (DBs first)"
        fi
        return 0
    fi

    if [[ "$n_running" -eq 0 ]]; then
        return 0
    fi

    _reset_started_compose

    # Phase 1: Database containers first
    if [[ ${#STOPPED_DB_IDS[@]} -gt 0 ]]; then
        log_info "Starting ${C_BOLD}${#STOPPED_DB_IDS[@]}${C_RESET} database container(s) first..."
        for i in "${!STOPPED_DB_IDS[@]}"; do
            log_info "  ${C_YELLOW}[DB]${C_RESET}  Starting ${STOPPED_DB_NAMES[$i]}"
            start_container "${STOPPED_DB_IDS[$i]}"
        done
        # Give databases a moment to initialize before dependent apps come up
        sleep 5
    fi

    # Phase 2: Application containers
    if [[ ${#STOPPED_CONTAINER_IDS[@]} -gt 0 ]]; then
        log_info "Starting ${C_BOLD}${#STOPPED_CONTAINER_IDS[@]}${C_RESET} application container(s)..."
        for i in "${!STOPPED_CONTAINER_IDS[@]}"; do
            log_info "  ${C_BLUE}[APP]${C_RESET} Starting ${STOPPED_CONTAINER_NAMES[$i]}"
            start_container "${STOPPED_CONTAINER_IDS[$i]}"
        done
    fi

    log_info "All ${n_running} previously-running container(s) restarted"

    # Note skipped containers (they stay stopped, as they were before backup)
    local n_skipped=$(( ${#SKIPPED_DB_IDS[@]} + ${#SKIPPED_CONTAINER_IDS[@]} ))
    if [[ "$n_skipped" -gt 0 ]]; then
        log_info "${n_skipped} already-stopped container(s) left in stopped state"
    fi
}

# ============================================================
# BACKUP FUNCTIONS
# ============================================================

backup_volume() {
    local vol="$1"
    local vol_path="$VOLUME_BASE/$vol/_data"
    local archive_name="${vol}-${NOW}"
    local start_time elapsed

    if [[ ! -d "$vol_path" ]]; then
        log_warn "Volume $vol has no _data directory, skipping"
        BACKUP_STATUS[$vol]="SKIP"
        return 0
    fi

    start_time=$(date +%s)
    BACKUP_SIZE[$vol]=$(get_volume_size "$vol")

    log_step "Backing up volume: ${C_BOLD}$vol${C_RESET} (${BACKUP_SIZE[$vol]})"

    # Create borg archive
    if create_archive "$archive_name" "$vol_path"; then
        BACKUP_STATUS[$vol]="OK"
    else
        BACKUP_STATUS[$vol]="FAIL"
        ((ERRORS++))
        log_error "  Failed to backup $vol"
    fi

    # Prune old archives for this volume
    prune_archives "${vol}-*"

    elapsed=$(( $(date +%s) - start_time ))
    BACKUP_DURATION[$vol]="${elapsed}s"
}

backup_compose() {
    local archive_name="compose-configs-${NOW}"
    local tmpdir start_time elapsed

    start_time=$(date +%s)
    log_step "Backing up compose configs from ${C_BOLD}$COMPOSE_DIR${C_RESET}"

    tmpdir=$(mktemp -d)
    local found=0

    for project_dir in "$COMPOSE_DIR"/*/; do
        [[ ! -d "$project_dir" ]] && continue
        local project_name
        project_name=$(basename "$project_dir")
        local has_files=false

        # Check for compose files
        for f in "$project_dir"docker-compose.yml "$project_dir"docker-compose.yaml "$project_dir"compose.yml "$project_dir"compose.yaml; do
            if [[ -f "$f" ]]; then
                mkdir -p "$tmpdir/$project_name"
                cp "$f" "$tmpdir/$project_name/"
                has_files=true
            fi
        done

        # Check for .env
        if [[ -f "$project_dir/.env" ]]; then
            mkdir -p "$tmpdir/$project_name"
            cp "$project_dir/.env" "$tmpdir/$project_name/"
            has_files=true
        fi

        if [[ "$has_files" == true ]]; then
            ((found++))
        fi
    done

    if [[ "$found" -eq 0 ]]; then
        log_warn "No compose files found in $COMPOSE_DIR"
        rm -rf "$tmpdir"
        BACKUP_STATUS["compose-configs"]="SKIP"
        return 0
    fi

    log_info "  Found $found projects with compose/env files"

    if create_archive "$archive_name" "$tmpdir"; then
        BACKUP_STATUS["compose-configs"]="OK"
    else
        BACKUP_STATUS["compose-configs"]="FAIL"
        ((ERRORS++))
    fi

    rm -rf "$tmpdir"
    prune_archives "compose-configs-*"

    elapsed=$(( $(date +%s) - start_time ))
    BACKUP_DURATION["compose-configs"]="${elapsed}s"
    BACKUP_SIZE["compose-configs"]="configs"
}

build_volume_list() {
    local all_volumes
    read -ra all_volumes <<< "$(get_named_volumes)"
    local filtered=()

    if [[ ${#ONLY_VOLUMES[@]} -gt 0 ]]; then
        # Include only specified volumes
        for vol in "${ONLY_VOLUMES[@]}"; do
            local found=false
            for av in "${all_volumes[@]}"; do
                if [[ "$av" == "$vol" ]]; then
                    found=true
                    break
                fi
            done
            if [[ "$found" == true ]]; then
                filtered+=("$vol")
            else
                log_warn "Volume '$vol' not found, skipping"
            fi
        done
    elif [[ ${#EXCLUDE_VOLUMES[@]} -gt 0 ]]; then
        # Exclude specified volumes
        for av in "${all_volumes[@]}"; do
            local excluded=false
            for ev in "${EXCLUDE_VOLUMES[@]}"; do
                if [[ "$av" == "$ev" ]]; then
                    excluded=true
                    break
                fi
            done
            if [[ "$excluded" == false ]]; then
                filtered+=("$av")
            fi
        done
    else
        filtered=("${all_volumes[@]}")
    fi

    echo "${filtered[@]}"
}

backup_all() {
    TOTAL_START=$(date +%s)

    init_repo

    local volumes
    read -ra volumes <<< "$(build_volume_list)"

    if [[ ${#volumes[@]} -eq 0 ]]; then
        die "No volumes to backup"
    fi

    log_info "Starting backup of ${#volumes[@]} volume(s)"
    echo ""

    # --- Stop all containers at once before any backup ---
    if [[ "$NO_STOP" == false ]]; then
        stop_all_containers "${volumes[@]}"
        echo ""
    elif [[ "$NO_STOP" == true ]]; then
        log_warn "Running with --no-stop: containers will NOT be stopped (unsafe for databases!)"
        echo ""
    fi

    # --- Backup each volume ---
    for vol in "${volumes[@]}"; do
        backup_volume "$vol"
        echo ""
    done

    # Always backup compose configs (unless --only is used for specific volumes)
    if [[ ${#ONLY_VOLUMES[@]} -eq 0 ]]; then
        backup_compose
        echo ""
    fi

    # --- Restart all containers (DBs first) ---
    if [[ "$NO_STOP" == false ]]; then
        start_all_containers
        echo ""
    fi

    print_summary
    cleanup_old_logs
}

# ============================================================
# RESTORE FUNCTIONS
# ============================================================

list_archives_raw() {
    borg list --short "$BORG_REPO" 2>/dev/null
}

ensure_volume_exists() {
    local vol_name="$1"
    local vol_path="$VOLUME_BASE/$vol_name/_data"

    if [[ ! -d "$vol_path" ]]; then
        log_info "Volume '$vol_name' does not exist, creating it..."
        docker volume create "$vol_name" &>/dev/null
        # Docker creates the directory but let's make sure _data exists
        if [[ ! -d "$vol_path" ]]; then
            mkdir -p "$vol_path"
        fi
    fi
}

restore_interactive() {
    init_repo

    echo ""
    echo "${C_BOLD}Available backup archives:${C_RESET}"
    echo ""

    # Get unique volume prefixes
    local archives=()
    while IFS= read -r archive; do
        [[ -z "$archive" ]] && continue
        archives+=("$archive")
    done < <(list_archives_raw)

    if [[ ${#archives[@]} -eq 0 ]]; then
        die "No archives found in repository"
    fi

    # Extract unique volume names (everything before the last -YYYY-MM-DD_HHMM)
    local -A volume_groups
    local -a group_order=()
    for archive in "${archives[@]}"; do
        local vol_name
        vol_name=$(echo "$archive" | sed 's/-[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}_[0-9]\{4\}$//')
        if [[ -z "${volume_groups[$vol_name]+x}" ]]; then
            group_order+=("$vol_name")
        fi
        volume_groups[$vol_name]+="$archive"$'\n'
    done

    # Show groups
    echo "Volume groups:"
    local i=1
    local -a menu_items=()
    for grp in "${group_order[@]}"; do
        local count
        count=$(echo -n "${volume_groups[$grp]}" | grep -c .)
        echo "  ${C_BOLD}$i)${C_RESET} $grp ($count archive(s))"
        menu_items+=("$grp")
        ((i++))
    done

    echo ""
    echo -n "Select a volume group to restore (1-${#menu_items[@]}), or 'q' to quit: "
    read -r choice

    [[ "$choice" == "q" ]] && exit 0

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt ${#menu_items[@]} ]]; then
        die "Invalid selection"
    fi

    local selected_group="${menu_items[$((choice-1))]}"
    echo ""
    echo "${C_BOLD}Archives for $selected_group:${C_RESET}"

    # List archives for this group
    local group_archives=()
    while IFS= read -r archive; do
        [[ -z "$archive" ]] && continue
        group_archives+=("$archive")
    done < <(borg list --short --glob-archives "${selected_group}-*" --sort-by timestamp "$BORG_REPO" 2>/dev/null)

    i=1
    for archive in "${group_archives[@]}"; do
        echo "  $i) $archive"
        ((i++))
    done
    echo "  a) Restore latest"

    echo ""
    echo -n "Select archive (1-${#group_archives[@]}) or 'a' for latest: "
    read -r archive_choice

    local target_archive
    if [[ "$archive_choice" == "a" ]]; then
        target_archive="${group_archives[-1]}"
    elif [[ "$archive_choice" =~ ^[0-9]+$ ]] && [[ "$archive_choice" -ge 1 ]] && [[ "$archive_choice" -le ${#group_archives[@]} ]]; then
        target_archive="${group_archives[$((archive_choice-1))]}"
    else
        die "Invalid selection"
    fi

    echo ""
    echo "${C_BOLD}Selected: $target_archive${C_RESET}"
    borg info "${BORG_REPO}::${target_archive}" 2>/dev/null | head -10
    echo ""

    # Determine restore target
    local restore_path
    if [[ -n "$RESTORE_TO" ]]; then
        restore_path="$RESTORE_TO/$selected_group"
        mkdir -p "$restore_path"
    elif [[ "$selected_group" == "compose-configs" ]]; then
        restore_path="$COMPOSE_DIR"
        echo "${C_YELLOW}This will restore compose configs to: $restore_path${C_RESET}"
    else
        # Ensure the docker volume exists before restoring
        ensure_volume_exists "$selected_group"
        restore_path="$VOLUME_BASE/$selected_group/_data"
        echo "${C_YELLOW}This will restore to: $restore_path${C_RESET}"

        # Check for containers using the volume
        local containers
        containers=$(get_containers_using_volume "$selected_group")
        if [[ -n "$containers" ]]; then
            echo "${C_YELLOW}Containers using this volume:${C_RESET}"
            for cid in $containers; do
                local cname
                cname=$(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||')
                echo "  - $cname"
            done
            echo ""
            echo -n "Stop these containers before restoring? (y/n): "
            read -r stop_choice
            if [[ "$stop_choice" == "y" ]]; then
                for cid in $containers; do
                    docker stop --time "$STOP_TIMEOUT" "$cid" &>/dev/null
                done
            fi
        fi
    fi

    echo ""
    echo -n "${C_BOLD}Proceed with restore? (y/n): ${C_RESET}"
    read -r confirm
    [[ "$confirm" != "y" ]] && die "Restore cancelled"

    log_info "Restoring $target_archive to $restore_path"
    mkdir -p "$restore_path"

    if [[ "$selected_group" == "compose-configs" ]]; then
        # Compose configs have subdirectory structure, extract to temp then merge
        local tmpdir
        tmpdir=$(mktemp -d)
        (cd "$tmpdir" && borg extract "${BORG_REPO}::${target_archive}")
        cp -r "$tmpdir"/*/ "$restore_path/" 2>/dev/null || cp -r "$tmpdir"/* "$restore_path/"
        rm -rf "$tmpdir"
    else
        (cd "$restore_path" && borg extract "${BORG_REPO}::${target_archive}")
    fi

    log_info "Restore complete!"

    # Offer to start ALL containers associated with the volume (running + previously stopped)
    if [[ "$selected_group" != "compose-configs" ]] && [[ -z "$RESTORE_TO" ]]; then
        local all_containers
        all_containers=$(get_all_containers_using_volume "$selected_group")
        if [[ -n "$all_containers" ]]; then
            echo ""
            echo "Containers associated with this volume:"
            for cid in $all_containers; do
                local cname state
                cname=$(get_container_name "$cid")
                state=$(docker inspect --format '{{.State.Status}}' "$cid" 2>/dev/null)
                echo "  - $cname (was: $state)"
            done
            echo ""
            echo -n "Start these containers now? (y/n): "
            read -r start_choice
            if [[ "$start_choice" == "y" ]]; then
                _reset_started_compose
                for cid in $all_containers; do
                    local cname
                    cname=$(get_container_name "$cid")
                    log_info "Starting: $cname"
                    start_container "$cid"
                done
            fi
        fi
    fi
}

restore_latest() {
    init_repo

    local restore_base="$VOLUME_BASE"
    if [[ -n "$RESTORE_TO" ]]; then
        restore_base="$RESTORE_TO"
        mkdir -p "$restore_base"
    fi

    log_info "Restoring latest archives for all volumes..."
    echo ""

    # Get all unique volume prefixes
    local -a group_order=()
    local -A seen
    while IFS= read -r archive; do
        [[ -z "$archive" ]] && continue
        local vol_name
        vol_name=$(echo "$archive" | sed 's/-[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}_[0-9]\{4\}$//')
        if [[ -z "${seen[$vol_name]+x}" ]]; then
            group_order+=("$vol_name")
            seen[$vol_name]=1
        fi
    done < <(list_archives_raw)

    for grp in "${group_order[@]}"; do
        local latest
        latest=$(borg list --short --glob-archives "${grp}-*" --sort-by timestamp --last 1 "$BORG_REPO" 2>/dev/null)
        [[ -z "$latest" ]] && continue

        local target_path
        if [[ "$grp" == "compose-configs" ]]; then
            if [[ -n "$RESTORE_TO" ]]; then
                target_path="$restore_base/compose-configs"
            else
                target_path="$COMPOSE_DIR"
            fi
        else
            if [[ -n "$RESTORE_TO" ]]; then
                target_path="$restore_base/$grp"
            else
                # Ensure volume exists
                ensure_volume_exists "$grp"
                target_path="$VOLUME_BASE/$grp/_data"
            fi
        fi

        mkdir -p "$target_path"
        log_step "Restoring: ${C_BOLD}$grp${C_RESET} from $latest"

        if [[ "$grp" == "compose-configs" ]]; then
            local tmpdir
            tmpdir=$(mktemp -d)
            if (cd "$tmpdir" && borg extract "${BORG_REPO}::${latest}"); then
                cp -r "$tmpdir"/*/ "$target_path/" 2>/dev/null || cp -r "$tmpdir"/* "$target_path/"
                log_info "  OK"
            else
                log_error "  Failed to restore $grp"
            fi
            rm -rf "$tmpdir"
        else
            if (cd "$target_path" && borg extract "${BORG_REPO}::${latest}"); then
                log_info "  OK"
            else
                log_error "  Failed to restore $grp"
            fi
        fi
    done

    echo ""
    log_info "Restore complete!"
}

restore_archive() {
    local archive_name="$1"
    init_repo

    # Verify archive exists
    if ! borg list --short "$BORG_REPO" 2>/dev/null | grep -qx "$archive_name"; then
        die "Archive '$archive_name' not found. Use --restore to see available archives."
    fi

    local vol_name
    vol_name=$(echo "$archive_name" | sed 's/-[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}_[0-9]\{4\}$//')

    local target_path
    if [[ -n "$RESTORE_TO" ]]; then
        target_path="$RESTORE_TO/$vol_name"
    elif [[ "$vol_name" == "compose-configs" ]]; then
        target_path="$COMPOSE_DIR"
    else
        # Ensure volume exists
        ensure_volume_exists "$vol_name"
        target_path="$VOLUME_BASE/$vol_name/_data"
    fi

    mkdir -p "$target_path"
    log_info "Restoring $archive_name to $target_path"

    if [[ "$vol_name" == "compose-configs" ]]; then
        local tmpdir
        tmpdir=$(mktemp -d)
        (cd "$tmpdir" && borg extract "${BORG_REPO}::${archive_name}")
        cp -r "$tmpdir"/*/ "$target_path/" 2>/dev/null || cp -r "$tmpdir"/* "$target_path/"
        rm -rf "$tmpdir"
    else
        (cd "$target_path" && borg extract "${BORG_REPO}::${archive_name}")
    fi

    log_info "Restore complete!"
}

# ============================================================
# LIST VOLUMES
# ============================================================

list_volumes() {
    local volumes
    read -ra volumes <<< "$(get_named_volumes)"

    echo ""
    echo "${C_BOLD}Docker Named Volumes${C_RESET}"
    echo ""
    printf "  ${C_BOLD}%-35s %10s${C_RESET}\n" "VOLUME" "SIZE"
    printf "  %-35s %10s\n" "-----------------------------------" "----------"

    for vol in "${volumes[@]}"; do
        local size
        size=$(get_volume_size "$vol")
        printf "  %-35s %10s\n" "$vol" "$size"
    done

    echo ""
    echo "Total: ${#volumes[@]} named volume(s)"

    # Show if repo exists
    if [[ -d "$BORG_REPO_PATH" ]]; then
        echo ""
        echo "${C_BOLD}Borg Repository${C_RESET}"
        export BORG_REPO="$BORG_REPO_PATH"
        export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes
        local archive_count
        archive_count=$(borg list --short "$BORG_REPO" 2>/dev/null | wc -l)
        echo "  Path: $BORG_REPO_PATH"
        echo "  Archives: $archive_count"
        local repo_size
        repo_size=$(du -sh "$BORG_REPO_PATH" 2>/dev/null | cut -f1)
        echo "  Repo size: $repo_size"
    fi

    echo ""
}

# ============================================================
# WHIPTAIL HELPERS
# ============================================================

# Terminal size for whiptail dialogs
WT_HEIGHT=24
WT_WIDTH=78
WT_LIST_HEIGHT=16

wt_update_size() {
    local term_lines term_cols
    term_lines=$(tput lines 2>/dev/null || echo 24)
    term_cols=$(tput cols 2>/dev/null || echo 80)
    WT_HEIGHT=$(( term_lines - 4 ))
    WT_WIDTH=$(( term_cols - 4 ))
    [[ $WT_HEIGHT -gt 40 ]] && WT_HEIGHT=40
    [[ $WT_WIDTH -gt 100 ]] && WT_WIDTH=100
    [[ $WT_HEIGHT -lt 16 ]] && WT_HEIGHT=16
    [[ $WT_WIDTH -lt 60 ]] && WT_WIDTH=60
    WT_LIST_HEIGHT=$(( WT_HEIGHT - 8 ))
}

wt_msgbox() {
    whiptail --title "$1" --msgbox "$2" "$WT_HEIGHT" "$WT_WIDTH"
}

wt_yesno() {
    whiptail --title "$1" --yesno "$2" 10 "$WT_WIDTH"
}

wt_info() {
    # Non-blocking info (just show then return)
    whiptail --title "$1" --infobox "$2" 8 "$WT_WIDTH"
}

# ============================================================
# INTERACTIVE MENU (whiptail)
# ============================================================

menu_interactive() {
    wt_update_size

    while true; do
        local repo_info="Repo: $BORG_REPO_PATH"
        if [[ -d "$BORG_REPO_PATH" ]]; then
            local rsize
            rsize=$(du -sh "$BORG_REPO_PATH" 2>/dev/null | cut -f1)
            repo_info="Repo: $BORG_REPO_PATH ($rsize)"
        fi

        local choice
        choice=$(whiptail --title "Docker Backup Manager" \
            --menu "\n$(hostname) | $repo_info\n" \
            "$WT_HEIGHT" "$WT_WIDTH" 7 \
            "backup"    "Backup all volumes" \
            "select"    "Backup selected volumes only" \
            "exclude"   "Backup all except selected" \
            "restore"   "Restore from backup" \
            "list"      "List volumes & repo info" \
            "dry-run"   "Dry run (full backup preview)" \
            "quit"      "Exit" \
            3>&1 1>&2 2>&3) || break

        case "$choice" in
            backup)
                SILENT_LOG=true
                wt_info "Backup" "Starting full backup..."
                backup_all
                SILENT_LOG=false
                wt_msgbox "Backup Complete" "$(print_summary_text)"
                ;;
            select)
                menu_select_volumes "only"
                ;;
            exclude)
                menu_select_volumes "exclude"
                ;;
            restore)
                wt_restore_interactive
                ;;
            list)
                wt_msgbox "Volumes & Repository" "$(list_volumes_text)"
                ;;
            dry-run)
                DRY_RUN=true
                SILENT_LOG=true
                wt_info "Dry Run" "Simulating full backup..."
                backup_all
                DRY_RUN=false
                SILENT_LOG=false
                wt_msgbox "Dry Run Complete" "$(print_summary_text)"
                ;;
            quit)
                break
                ;;
        esac
    done
}

menu_select_volumes() {
    local mode="$1"  # "only" or "exclude"
    local all_volumes
    read -ra all_volumes <<< "$(get_named_volumes)"

    local title
    if [[ "$mode" == "only" ]]; then
        title="Select Volumes to BACKUP"
    else
        title="Select Volumes to EXCLUDE"
    fi

    # Build checklist items: tag item status
    local -a checklist_args=()
    for vol in "${all_volumes[@]}"; do
        local size
        size=$(get_volume_size "$vol")
        if [[ "$mode" == "only" ]]; then
            checklist_args+=("$vol" "$size" "OFF")
        else
            checklist_args+=("$vol" "$size" "OFF")
        fi
    done

    wt_update_size

    local selected
    selected=$(whiptail --title "$title" \
        --checklist "\nUse SPACE to select, ENTER to confirm:\n" \
        "$WT_HEIGHT" "$WT_WIDTH" "$WT_LIST_HEIGHT" \
        "${checklist_args[@]}" \
        3>&1 1>&2 2>&3) || return

    # whiptail returns quoted items: "vol1" "vol2"
    if [[ -z "$selected" ]]; then
        wt_msgbox "No Selection" "No volumes were selected."
        return
    fi

    # Parse selected items (remove quotes)
    local -a sel_array=()
    eval "sel_array=($selected)"

    # Confirm
    local confirm_text
    if [[ "$mode" == "only" ]]; then
        confirm_text="Backup ONLY these ${#sel_array[@]} volume(s)?\n\n"
    else
        confirm_text="Backup all volumes EXCEPT these ${#sel_array[@]}?\n\n"
    fi
    for v in "${sel_array[@]}"; do
        confirm_text+="  - $v\n"
    done

    if ! wt_yesno "Confirm" "$confirm_text"; then
        return
    fi

    if [[ "$mode" == "only" ]]; then
        ONLY_VOLUMES=("${sel_array[@]}")
        EXCLUDE_VOLUMES=()
    else
        EXCLUDE_VOLUMES=("${sel_array[@]}")
        ONLY_VOLUMES=()
    fi

    SILENT_LOG=true
    wt_info "Backup" "Starting backup..."
    backup_all
    SILENT_LOG=false

    # Reset filters
    ONLY_VOLUMES=()
    EXCLUDE_VOLUMES=()

    wt_msgbox "Backup Complete" "$(print_summary_text)"
}

# ============================================================
# WHIPTAIL RESTORE
# ============================================================

wt_restore_interactive() {
    init_repo
    wt_update_size

    # Get unique volume prefixes
    local archives=()
    while IFS= read -r archive; do
        [[ -z "$archive" ]] && continue
        archives+=("$archive")
    done < <(list_archives_raw)

    if [[ ${#archives[@]} -eq 0 ]]; then
        wt_msgbox "No Archives" "No backup archives found in the repository."
        return
    fi

    # Build volume groups
    local -A volume_groups
    local -a group_order=()
    for archive in "${archives[@]}"; do
        local vol_name
        vol_name=$(echo "$archive" | sed 's/-[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}_[0-9]\{4\}$//')
        if [[ -z "${volume_groups[$vol_name]+x}" ]]; then
            group_order+=("$vol_name")
        fi
        volume_groups[$vol_name]+="$archive"$'\n'
    done

    # Build menu items
    local -a menu_args=()
    for grp in "${group_order[@]}"; do
        local count
        count=$(echo -n "${volume_groups[$grp]}" | grep -c .)
        menu_args+=("$grp" "$count archive(s)")
    done

    # Step 1: Pick volume group
    local selected_group
    selected_group=$(whiptail --title "Restore - Select Volume" \
        --menu "\nSelect a volume to restore:\n" \
        "$WT_HEIGHT" "$WT_WIDTH" "$WT_LIST_HEIGHT" \
        "${menu_args[@]}" \
        3>&1 1>&2 2>&3) || return

    # Step 2: Pick archive
    local group_archives=()
    while IFS= read -r archive; do
        [[ -z "$archive" ]] && continue
        group_archives+=("$archive")
    done < <(borg list --short --glob-archives "${selected_group}-*" --sort-by timestamp "$BORG_REPO" 2>/dev/null)

    local -a archive_menu=()
    archive_menu+=("LATEST" "Most recent: ${group_archives[-1]}")
    local i=${#group_archives[@]}
    for archive in "${group_archives[@]}"; do
        # Extract date portion for display
        local datepart
        datepart=$(echo "$archive" | grep -oP '[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{4}$')
        archive_menu+=("$archive" "$datepart")
    done

    local selected_archive
    selected_archive=$(whiptail --title "Restore - Select Archive" \
        --menu "\nArchives for: $selected_group\n" \
        "$WT_HEIGHT" "$WT_WIDTH" "$WT_LIST_HEIGHT" \
        "${archive_menu[@]}" \
        3>&1 1>&2 2>&3) || return

    if [[ "$selected_archive" == "LATEST" ]]; then
        selected_archive="${group_archives[-1]}"
    fi

    # Step 3: Get archive info
    local archive_info
    archive_info=$(borg info "${BORG_REPO}::${selected_archive}" 2>/dev/null | head -12)

    # Determine restore path
    local restore_path
    local path_info
    if [[ -n "$RESTORE_TO" ]]; then
        restore_path="$RESTORE_TO/$selected_group"
        path_info="Custom path: $restore_path"
    elif [[ "$selected_group" == "compose-configs" ]]; then
        restore_path="$COMPOSE_DIR"
        path_info="Compose dir: $restore_path"
    else
        restore_path="$VOLUME_BASE/$selected_group/_data"
        path_info="Volume path: $restore_path"
    fi

    # Step 4: Confirm
    local confirm_msg
    confirm_msg="Archive: $selected_archive\n"
    confirm_msg+="Restore to: $restore_path\n\n"
    confirm_msg+="$archive_info\n\n"

    # Check for running containers (to stop before restore)
    local running_containers=""
    local running_names=""
    if [[ "$selected_group" != "compose-configs" ]]; then
        running_containers=$(get_containers_using_volume "$selected_group")
        if [[ -n "$running_containers" ]]; then
            confirm_msg+="WARNING: Running containers use this volume:\n"
            for cid in $running_containers; do
                local cname
                cname=$(get_container_name "$cid")
                confirm_msg+="  - $cname\n"
                running_names+="$cname "
            done
            confirm_msg+="\nThey will be stopped before restore.\n"
        fi
    fi

    confirm_msg+="\nProceed with restore?"

    if ! wt_yesno "Confirm Restore" "$confirm_msg"; then
        return
    fi

    # Stop running containers
    if [[ -n "$running_containers" ]]; then
        wt_info "Stopping" "Stopping containers: $running_names"
        for cid in $running_containers; do
            docker stop --time "$STOP_TIMEOUT" "$cid" &>/dev/null
        done
    fi

    # Ensure volume exists
    if [[ "$selected_group" != "compose-configs" ]] && [[ -z "$RESTORE_TO" ]]; then
        ensure_volume_exists "$selected_group"
    fi
    mkdir -p "$restore_path"

    wt_info "Restoring" "Extracting $selected_archive..."

    # Do the restore
    local restore_ok=true
    if [[ "$selected_group" == "compose-configs" ]]; then
        local tmpdir
        tmpdir=$(mktemp -d)
        if (cd "$tmpdir" && borg extract "${BORG_REPO}::${selected_archive}"); then
            cp -r "$tmpdir"/*/ "$restore_path/" 2>/dev/null || cp -r "$tmpdir"/* "$restore_path/"
        else
            restore_ok=false
        fi
        rm -rf "$tmpdir"
    else
        if ! (cd "$restore_path" && borg extract "${BORG_REPO}::${selected_archive}"); then
            restore_ok=false
        fi
    fi

    # Offer to start ALL containers associated with the volume (running + previously stopped)
    if [[ "$selected_group" != "compose-configs" ]] && [[ -z "$RESTORE_TO" ]]; then
        local all_containers all_names=""
        all_containers=$(get_all_containers_using_volume "$selected_group")
        if [[ -n "$all_containers" ]]; then
            for cid in $all_containers; do
                local cname
                cname=$(get_container_name "$cid")
                local state
                state=$(docker inspect --format '{{.State.Status}}' "$cid" 2>/dev/null)
                all_names+="  - $cname (was: $state)\n"
            done
            if wt_yesno "Start Containers" "Start containers for this volume?\n\n${all_names}"; then
                _reset_started_compose
                for cid in $all_containers; do
                    start_container "$cid"
                done
            fi
        fi
    fi

    if [[ "$restore_ok" == true ]]; then
        wt_msgbox "Restore Complete" "Successfully restored:\n\n  $selected_archive\n  -> $restore_path"
    else
        wt_msgbox "Restore Failed" "Failed to restore $selected_archive.\nCheck logs for details."
    fi
}

# ============================================================
# SUMMARY
# ============================================================

print_summary() {
    local total_elapsed=$(( $(date +%s) - TOTAL_START ))

    echo ""
    echo "${C_BOLD}============================================${C_RESET}"
    echo "${C_BOLD}  Backup Summary${C_RESET}"
    echo "${C_BOLD}============================================${C_RESET}"
    echo ""

    printf "  ${C_BOLD}%-36s %10s %8s %8s${C_RESET}\n" "VOLUME" "SIZE" "TIME" "STATUS"
    printf "  %-36s %10s %8s %8s\n" "------------------------------------" "----------" "--------" "--------"

    for vol in "${!BACKUP_STATUS[@]}"; do
        local status="${BACKUP_STATUS[$vol]}"
        local size="${BACKUP_SIZE[$vol]:-N/A}"
        local duration="${BACKUP_DURATION[$vol]:-N/A}"
        local status_colored

        case "$status" in
            OK)   status_colored="${C_GREEN}OK${C_RESET}" ;;
            FAIL) status_colored="${C_RED}FAIL${C_RESET}" ;;
            SKIP) status_colored="${C_YELLOW}SKIP${C_RESET}" ;;
            *)    status_colored="$status" ;;
        esac

        printf "  %-36s %10s %8s %b\n" "$vol" "$size" "$duration" "$status_colored"
    done

    echo ""
    echo "  Total time: ${total_elapsed}s"

    if [[ -d "$BORG_REPO_PATH" ]]; then
        local repo_size
        repo_size=$(du -sh "$BORG_REPO_PATH" 2>/dev/null | cut -f1)
        echo "  Repo size:  $repo_size"
    fi

    if [[ "$ERRORS" -gt 0 ]]; then
        echo ""
        echo "  ${C_RED}${ERRORS} error(s) occurred during backup${C_RESET}"
    else
        echo ""
        echo "  ${C_GREEN}All backups completed successfully${C_RESET}"
    fi

    if [[ -n "$LOG_FILE" ]]; then
        echo ""
        echo "  Log: $LOG_FILE"
    fi

    echo ""
}

# Plain-text summary for whiptail msgbox (no ANSI colors)
print_summary_text() {
    local total_elapsed=$(( $(date +%s) - TOTAL_START ))
    local text=""

    text+=$(printf "%-34s %8s %6s %s\n" "VOLUME" "SIZE" "TIME" "STATUS")
    text+="\n"
    text+=$(printf "%-34s %8s %6s %s\n" "──────────────────────────────────" "────────" "──────" "──────")
    text+="\n"

    for vol in "${!BACKUP_STATUS[@]}"; do
        local status="${BACKUP_STATUS[$vol]}"
        local size="${BACKUP_SIZE[$vol]:-N/A}"
        local duration="${BACKUP_DURATION[$vol]:-N/A}"
        text+=$(printf "%-34s %8s %6s %s\n" "$vol" "$size" "$duration" "$status")
        text+="\n"
    done

    text+="\nTotal time: ${total_elapsed}s"

    if [[ -d "$BORG_REPO_PATH" ]]; then
        local repo_size
        repo_size=$(du -sh "$BORG_REPO_PATH" 2>/dev/null | cut -f1)
        text+="\nRepo size:  $repo_size"
    fi

    if [[ "$ERRORS" -gt 0 ]]; then
        text+="\n\n${ERRORS} error(s) occurred!"
    else
        text+="\n\nAll backups completed successfully"
    fi

    if [[ -n "$LOG_FILE" ]]; then
        text+="\nLog: $LOG_FILE"
    fi

    echo -e "$text"
}

# Plain-text volume list for whiptail msgbox
list_volumes_text() {
    local volumes
    read -ra volumes <<< "$(get_named_volumes)"
    local text=""

    text+=$(printf "%-35s %10s\n" "VOLUME" "SIZE")
    text+="\n"
    text+=$(printf "%-35s %10s\n" "───────────────────────────────────" "──────────")
    text+="\n"

    for vol in "${volumes[@]}"; do
        local size
        size=$(get_volume_size "$vol")
        text+=$(printf "%-35s %10s\n" "$vol" "$size")
        text+="\n"
    done

    text+="\nTotal: ${#volumes[@]} named volume(s)"

    if [[ -d "$BORG_REPO_PATH" ]]; then
        export BORG_REPO="$BORG_REPO_PATH"
        export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes
        local archive_count
        archive_count=$(borg list --short "$BORG_REPO" 2>/dev/null | wc -l)
        local repo_size
        repo_size=$(du -sh "$BORG_REPO_PATH" 2>/dev/null | cut -f1)
        text+="\n\nRepo: $BORG_REPO_PATH"
        text+="\nArchives: $archive_count | Size: $repo_size"
    fi

    echo -e "$text"
}

# ============================================================
# HELP
# ============================================================

show_help() {
    head -24 "$0" | tail -22 | sed 's/^# \?//'
    exit 0
}

# ============================================================
# ARGUMENT PARSING
# ============================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --only)
                shift
                [[ -z "${1:-}" ]] && die "--only requires a comma-separated list of volumes"
                IFS=',' read -ra ONLY_VOLUMES <<< "$1"
                ;;
            --exclude)
                shift
                [[ -z "${1:-}" ]] && die "--exclude requires a comma-separated list of volumes"
                IFS=',' read -ra EXCLUDE_VOLUMES <<< "$1"
                ;;
            --list)
                ACTION="list"
                ;;
            --menu)
                ACTION="menu"
                ;;
            --restore)
                ACTION="restore"
                if [[ -n "${2:-}" ]] && [[ "${2}" != --* ]]; then
                    RESTORE_TARGET="$2"
                    shift
                fi
                ;;
            --restore-to)
                shift
                [[ -z "${1:-}" ]] && die "--restore-to requires a directory path"
                RESTORE_TO="$1"
                ;;
            --no-stop)
                NO_STOP=true
                ;;
            --dry-run)
                DRY_RUN=true
                ;;
            --repo)
                shift
                [[ -z "${1:-}" ]] && die "--repo requires a path"
                BORG_REPO_PATH="$1"
                ;;
            --help|-h)
                show_help
                ;;
            *)
                die "Unknown option: $1 (use --help for usage)"
                ;;
        esac
        shift
    done

    # Validate conflicting options
    if [[ ${#ONLY_VOLUMES[@]} -gt 0 ]] && [[ ${#EXCLUDE_VOLUMES[@]} -gt 0 ]]; then
        die "Cannot use --only and --exclude together"
    fi
}

# ============================================================
# MAIN
# ============================================================

main() {
    parse_args "$@"
    require_root
    detect_mode
    setup_colors

    case "$ACTION" in
        list)
            list_volumes
            ;;
        menu)
            init_repo
            setup_logging "backup"
            menu_interactive
            ;;
        restore)
            if [[ -z "$RESTORE_TARGET" ]]; then
                if [[ "$IS_INTERACTIVE" == true ]]; then
                    init_repo
                    setup_colors
                    setup_logging "restore"
                    wt_restore_interactive
                else
                    restore_interactive
                fi
            elif [[ "$RESTORE_TARGET" == "latest" ]]; then
                restore_latest
            else
                restore_archive "$RESTORE_TARGET"
            fi
            ;;
        backup)
            setup_logging
            log_info "docker-backup started ($(date))"
            if [[ "$DRY_RUN" == true ]]; then
                log_warn "DRY RUN — no changes will be made"
            fi
            echo ""
            backup_all
            ;;
    esac
}

main "$@"
