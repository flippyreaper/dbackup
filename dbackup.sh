#!/usr/bin/env bash
#
# dbackup.sh — Docker volume backup with gum TUI (Miami Vice neon edition)
#
# Usage: sudo dbackup.sh [OPTIONS]
#
# Backup:
#   (no args)              Interactive menu
#   --only vol1,vol2       Backup only these volumes
#   --exclude vol1,vol2    Skip these volumes
#   --list                 Show available volumes with sizes
#   --no-stop              Don't stop containers before backup
#   --dry-run              Preview without doing anything
#
# Restore:
#   --restore              Interactive restore menu
#   --restore latest       Restore all from most recent archives
#   --restore ARCHIVE      Restore specific archive
#   --restore-to DIR       Extract to custom directory
#
# Other:
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
CONFIG_FILE="/opt/dbackup/config"
LOG_RETENTION_DAYS=30
STOP_TIMEOUT=60

# ============================================================
# GLOBALS
# ============================================================
IS_INTERACTIVE=false
LOG_FILE=""
ACTION="menu"
ONLY_VOLUMES=()
EXCLUDE_VOLUMES=()
NO_STOP=false
DRY_RUN=false
RESTORE_TARGET=""
RESTORE_TO=""
NOW=$(date +"$TIMESTAMP_FMT")

# Load persistent config (overrides defaults set above)
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

declare -A BACKUP_STATUS
declare -A BACKUP_DURATION
declare -A BACKUP_SIZE
TOTAL_START=0
ERRORS=0

STOPPED_CONTAINER_IDS=()
STOPPED_CONTAINER_NAMES=()
STOPPED_DB_IDS=()
STOPPED_DB_NAMES=()
SKIPPED_CONTAINER_IDS=()
SKIPPED_CONTAINER_NAMES=()
SKIPPED_DB_IDS=()
SKIPPED_DB_NAMES=()

# ============================================================
# NEON COLOR PALETTE (ANSI — for plain output / cron / log)
# ============================================================
NCYAN=$'\033[38;2;0;255;255m'
NPINK=$'\033[38;2;255;45;120m'
NGREEN=$'\033[38;2;0;255;159m'
NPURPLE=$'\033[38;2;191;0;255m'
NYELLOW=$'\033[38;2;255;230;0m'
NRED=$'\033[38;2;255;68;68m'
NGRAY=$'\033[38;2;102;102;102m'
NC=$'\033[0m'
NBOLD=$'\033[1m'

# Gum hex colors
GC_CYAN="#00FFFF"
GC_PINK="#FF2D78"
GC_GREEN="#00FF9F"
GC_PURPLE="#BF00FF"
GC_YELLOW="#FFE600"
GC_RED="#FF4444"
GC_DIM="#666666"
GC_WHITE="#EEEEEE"
GC_DARK="#1A1A2E"

# ============================================================
# LOGGING
# ============================================================

save_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat > "$CONFIG_FILE" <<EOF
# dbackup persistent config — auto-generated
BORG_REPO_PATH="$BORG_REPO_PATH"
EOF
}

setup_logging() {
    local prefix="${1:-backup}"
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/${prefix}-${NOW}.log"
    if [[ "$IS_INTERACTIVE" == false ]]; then
        exec >>"$LOG_FILE" 2>&1
    fi
}

log() {
    local timestamp msg
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    msg="[$timestamp] $*"
    if [[ "$IS_INTERACTIVE" == true ]]; then
        echo -e "$msg"
        if [[ -n "${LOG_FILE:-}" ]]; then
            printf '%s\n' "$msg" | sed 's/\x1b\[[0-9;]*[mGKHF]//g; s/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"
        fi
    else
        # Non-interactive: stdout already redirected to log — expand then strip ANSI
        echo -e "$msg" | sed 's/\x1b\[[0-9;]*[mGKHF]//g; s/\x1b\[[0-9;]*m//g'
    fi
}

log_info()  { log "${NGREEN}INFO${NC}  $*"; }
log_warn()  { log "${NYELLOW}WARN${NC}  $*"; }
log_error() { log "${NRED}ERROR${NC} $*"; }
log_step()  { log "${NCYAN}>>>>${NC}  $*"; }

die() {
    if [[ "$IS_INTERACTIVE" == true ]]; then
        gum style --foreground "$GC_RED" --bold "  ✗  $*"
    else
        log_error "$*"
    fi
    exit 1
}

cleanup_old_logs() {
    find "$LOG_DIR" -name '*.log' -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
}

# ============================================================
# GUM HELPERS
# ============================================================

gum_ok() {
    gum style --foreground "$GC_GREEN" "  ✓  $*"
}

gum_fail() {
    gum style --foreground "$GC_RED" "  ✗  $*"
}

gum_warn() {
    gum style --foreground "$GC_YELLOW" "  ⚠  $*"
}

gum_info() {
    gum style --foreground "$GC_CYAN" "     $*"
}

gum_step() {
    gum style --foreground "$GC_PURPLE" --bold "  ▸  $*"
}

# Run a command with a gum spinner; borg/command output goes to LOG_FILE only
spin_run() {
    local title="$1"; shift
    gum spin \
        --spinner dot \
        --spinner.foreground "$GC_CYAN" \
        --title.foreground "$GC_WHITE" \
        --title "  $title" \
        -- "$@"
}

format_duration() {
    local s="$1"
    if   (( s >= 3600 )); then printf "%dh %dm %ds" $(( s/3600 )) $(( (s%3600)/60 )) $(( s%60 ))
    elif (( s >= 60   )); then printf "%dm %ds" $(( s/60 )) $(( s%60 ))
    else printf "%ds" "$s"
    fi
}

draw_header() {
    echo ""
    local repo_size
    if [[ -d "$BORG_REPO_PATH" ]]; then
        repo_size=$(du -sh "$BORG_REPO_PATH" 2>/dev/null | cut -f1)
    else
        repo_size="not initialized"
    fi
    gum style \
        --border double \
        --border-foreground "$GC_CYAN" \
        --foreground "$GC_WHITE" \
        --align center \
        --width 64 \
        --padding "0 2" \
        "$(gum style --foreground "$GC_PINK" --bold "⚡  DOCKER BACKUP MANAGER  ⚡")" \
        "$(gum style --foreground "$GC_DIM" "$(hostname)  ▸  $BORG_REPO_PATH")" \
        "$(gum style --foreground "$GC_CYAN" "repo: ${repo_size}")"
    echo ""
}

draw_section() {
    gum style --foreground "$GC_PURPLE" --bold "  ┄┄  $*  ┄┄"
    echo ""
}

# ============================================================
# CORE
# ============================================================

require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo "This script must be run as root. Use: sudo $0 $*" >&2
        exit 1
    fi
}

detect_mode() {
    [[ -t 1 ]] && IS_INTERACTIVE=true || IS_INTERACTIVE=false
}

# ============================================================
# BORG HELPERS
# ============================================================

init_repo() {
    export BORG_REPO="$BORG_REPO_PATH"
    export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes

    mkdir -p "$(dirname "$BORG_REPO_PATH")"

    if ! borg info "$BORG_REPO" &>/dev/null; then
        log_info "Initializing new borg repository at $BORG_REPO"
        borg init --encryption=none "$BORG_REPO" || die "Failed to init borg repo at $BORG_REPO"
    fi

    if borg info "$BORG_REPO" 2>&1 | grep -q "Failed to create/acquire the lock"; then
        die "Repository is locked — another backup may be running. If not: borg break-lock $BORG_REPO"
    fi
}

# ============================================================
# VOLUME DISCOVERY
# ============================================================

get_named_volumes() {
    local volumes=()
    while IFS= read -r vol; do
        [[ "$vol" =~ ^[0-9a-f]{64}$ ]] && continue
        volumes+=("$vol")
    done < <(docker volume ls -q 2>/dev/null)
    echo "${volumes[@]}"
}

get_volume_size() {
    local path="$VOLUME_BASE/$1/_data"
    [[ -d "$path" ]] && du -sh "$path" 2>/dev/null | cut -f1 || echo "0B"
}

get_containers_using_volume() {
    docker ps -q --filter "volume=$1" 2>/dev/null
}

get_all_containers_using_volume() {
    docker ps -aq --filter "volume=$1" 2>/dev/null
}

DB_IMAGE_PATTERNS="postgres|mariadb|mysql|mongo|redis|valkey|memcached|influxdb|clickhouse|cockroach|timescaledb"

is_db_container() {
    local image
    image=$(docker inspect --format '{{.Config.Image}}' "$1" 2>/dev/null)
    [[ "$image" =~ ($DB_IMAGE_PATTERNS) ]]
}

get_container_name() {
    docker inspect --format '{{.Name}}' "$1" 2>/dev/null | sed 's|^/||'
}

get_container_image() {
    docker inspect --format '{{.Config.Image}}' "$1" 2>/dev/null
}

# ============================================================
# CONTAINER STOP / START
# ============================================================

stop_all_containers() {
    local -a volumes_to_backup=("$@")
    local -A seen_cid
    local -A compose_projects  # projects touched by any volume-using container

    STOPPED_CONTAINER_IDS=()
    STOPPED_CONTAINER_NAMES=()
    STOPPED_DB_IDS=()
    STOPPED_DB_NAMES=()
    SKIPPED_CONTAINER_IDS=()
    SKIPPED_CONTAINER_NAMES=()
    SKIPPED_DB_IDS=()
    SKIPPED_DB_NAMES=()

    # Pass 1: find containers directly attached to the named volumes, collect their compose projects
    for vol in "${volumes_to_backup[@]}"; do
        while IFS= read -r cid; do
            [[ -z "$cid" ]] && continue
            seen_cid[$cid]=1
            local project
            project=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$cid" 2>/dev/null)
            [[ -n "$project" ]] && compose_projects[$project]=1
        done < <(docker ps -aq --filter "volume=$vol" 2>/dev/null)
    done

    # Pass 2: expand to ALL containers in those compose projects (catches bind-mount-only siblings)
    for project in "${!compose_projects[@]}"; do
        while IFS= read -r cid; do
            [[ -z "$cid" ]] && continue
            seen_cid[$cid]=1
        done < <(docker ps -aq --filter "label=com.docker.compose.project=$project" 2>/dev/null)
    done

    # Classify all discovered containers
    for cid in "${!seen_cid[@]}"; do
        local cname state
        cname=$(get_container_name "$cid")
        state=$(docker inspect --format '{{.State.Status}}' "$cid" 2>/dev/null)
        if [[ "$state" == "running" || "$state" == "restarting" ]]; then
            if is_db_container "$cid"; then
                STOPPED_DB_IDS+=("$cid"); STOPPED_DB_NAMES+=("$cname")
            else
                STOPPED_CONTAINER_IDS+=("$cid"); STOPPED_CONTAINER_NAMES+=("$cname")
            fi
        else
            if is_db_container "$cid"; then
                SKIPPED_DB_IDS+=("$cid"); SKIPPED_DB_NAMES+=("$cname")
            else
                SKIPPED_CONTAINER_IDS+=("$cid"); SKIPPED_CONTAINER_NAMES+=("$cname")
            fi
        fi
    done

    local n_running=$(( ${#STOPPED_CONTAINER_IDS[@]} + ${#STOPPED_DB_IDS[@]} ))
    local n_skipped=$(( ${#SKIPPED_CONTAINER_IDS[@]} + ${#SKIPPED_DB_IDS[@]} ))

    if [[ "$IS_INTERACTIVE" == true ]]; then
        if [[ "$n_skipped" -gt 0 ]]; then
            for i in "${!SKIPPED_DB_IDS[@]}";      do printf "     ${NGRAY}[already stopped]${NC} %s\n" "${SKIPPED_DB_NAMES[$i]} (DB)"; done
            for i in "${!SKIPPED_CONTAINER_IDS[@]}"; do printf "     ${NGRAY}[already stopped]${NC} %s\n" "${SKIPPED_CONTAINER_NAMES[$i]}"; done
            echo ""
        fi
    fi

    if [[ "$n_running" -eq 0 ]]; then
        [[ "$IS_INTERACTIVE" == true ]] && gum_info "No running containers to stop" || log_info "No running containers to stop"
        return 0
    fi

    if [[ "$IS_INTERACTIVE" == true ]]; then
        gum_step "Stopping $n_running container(s)  (${STOP_TIMEOUT}s grace)"
        for i in "${!STOPPED_CONTAINER_IDS[@]}"; do printf "     ${NCYAN}[app]${NC}  %s\n" "${STOPPED_CONTAINER_NAMES[$i]}"; done
        for i in "${!STOPPED_DB_IDS[@]}";        do printf "     ${NYELLOW}[DB]${NC}   %s\n" "${STOPPED_DB_NAMES[$i]}"; done
        echo ""
    else
        log_info "Stopping $n_running running container(s) (${STOP_TIMEOUT}s grace)..."
        for i in "${!STOPPED_CONTAINER_IDS[@]}"; do log_info "  [APP] ${STOPPED_CONTAINER_NAMES[$i]}"; done
        for i in "${!STOPPED_DB_IDS[@]}";        do log_info "  [DB]  ${STOPPED_DB_NAMES[$i]}"; done
    fi

    [[ "$DRY_RUN" == true ]] && return 0

    # Stop apps first (they depend on DBs), then DBs — ensures clean disconnection
    if [[ ${#STOPPED_CONTAINER_IDS[@]} -gt 0 ]]; then
        if [[ "$IS_INTERACTIVE" == true ]]; then
            spin_run "Stopping apps..." docker stop --time "$STOP_TIMEOUT" "${STOPPED_CONTAINER_IDS[@]}"
        else
            docker stop --time "$STOP_TIMEOUT" "${STOPPED_CONTAINER_IDS[@]}" &>/dev/null
            log_info "Apps stopped"
        fi
    fi
    if [[ ${#STOPPED_DB_IDS[@]} -gt 0 ]]; then
        if [[ "$IS_INTERACTIVE" == true ]]; then
            spin_run "Stopping databases..." docker stop --time "$STOP_TIMEOUT" "${STOPPED_DB_IDS[@]}"
        else
            docker stop --time "$STOP_TIMEOUT" "${STOPPED_DB_IDS[@]}" &>/dev/null
            log_info "Databases stopped"
        fi
    fi

    if [[ "$IS_INTERACTIVE" == true ]]; then
        gum_ok "All running containers stopped"
    else
        log_info "All running containers stopped"
    fi
    echo ""
}

declare -A _STARTED_COMPOSE=()
_reset_started_compose() { _STARTED_COMPOSE=(); }

start_container() {
    local cid="$1"
    local project workdir
    project=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$cid" 2>/dev/null)
    workdir=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$cid" 2>/dev/null)

    if [[ -n "$project" && -n "$workdir" && -d "$workdir" ]]; then
        if [[ -n "${_STARTED_COMPOSE[$workdir]+x}" ]]; then
            return 0
        fi
        _STARTED_COMPOSE[$workdir]=1
        local has_compose=false
        for f in "$workdir"/docker-compose.yml "$workdir"/docker-compose.yaml \
                 "$workdir"/compose.yml "$workdir"/compose.yaml; do
            [[ -f "$f" ]] && has_compose=true && break
        done
        if $has_compose; then
            if ! (cd "$workdir" && docker compose up -d >>"$LOG_FILE" 2>&1); then
                (cd "$workdir" && docker-compose up -d >>"$LOG_FILE" 2>&1) || docker start "$cid" >>"$LOG_FILE" 2>&1
            fi
        else
            docker start "$cid" >>"$LOG_FILE" 2>&1
        fi
    else
        docker start "$cid" >>"$LOG_FILE" 2>&1
    fi
}

start_all_containers() {
    local n_running=$(( ${#STOPPED_DB_IDS[@]} + ${#STOPPED_CONTAINER_IDS[@]} ))
    [[ "$DRY_RUN" == true ]] && return 0
    [[ "$n_running" -eq 0 ]] && return 0

    _reset_started_compose

    if [[ ${#STOPPED_DB_IDS[@]} -gt 0 ]]; then
        if [[ "$IS_INTERACTIVE" == true ]]; then
            gum_step "Starting ${#STOPPED_DB_IDS[@]} database container(s) first..."
        else
            log_info "Starting ${#STOPPED_DB_IDS[@]} database container(s) first..."
        fi
        for i in "${!STOPPED_DB_IDS[@]}"; do
            start_container "${STOPPED_DB_IDS[$i]}"
            if [[ "$IS_INTERACTIVE" == true ]]; then
                gum_ok "DB: ${STOPPED_DB_NAMES[$i]}"
            else
                log_info "  [DB] Started ${STOPPED_DB_NAMES[$i]}"
            fi
        done
        sleep 5
    fi

    if [[ ${#STOPPED_CONTAINER_IDS[@]} -gt 0 ]]; then
        if [[ "$IS_INTERACTIVE" == true ]]; then
            gum_step "Starting ${#STOPPED_CONTAINER_IDS[@]} application container(s)..."
        else
            log_info "Starting ${#STOPPED_CONTAINER_IDS[@]} application container(s)..."
        fi
        for i in "${!STOPPED_CONTAINER_IDS[@]}"; do
            start_container "${STOPPED_CONTAINER_IDS[$i]}"
            if [[ "$IS_INTERACTIVE" == true ]]; then
                gum_ok "App: ${STOPPED_CONTAINER_NAMES[$i]}"
            else
                log_info "  [APP] Started ${STOPPED_CONTAINER_NAMES[$i]}"
            fi
        done
    fi

    if [[ "$IS_INTERACTIVE" == true ]]; then
        echo ""
        gum_ok "All $n_running container(s) restarted"
    else
        log_info "All $n_running previously-running container(s) restarted"
    fi
}

# ============================================================
# BACKUP FUNCTIONS
# ============================================================

ensure_volume_exists() {
    local vol_name="$1"
    local vol_path="$VOLUME_BASE/$vol_name/_data"
    if [[ ! -d "$vol_path" ]]; then
        log_info "Volume '$vol_name' does not exist — creating..."
        docker volume create "$vol_name" &>/dev/null
        mkdir -p "$vol_path"
    fi
}

backup_volume() {
    local vol="$1"
    local vol_path="$VOLUME_BASE/$vol/_data"
    local archive_name="${vol}-${NOW}"
    local start_time elapsed size

    if [[ ! -d "$vol_path" ]]; then
        [[ "$IS_INTERACTIVE" == true ]] && gum_warn "$vol — no _data dir, skipping" || log_warn "$vol has no _data directory, skipping"
        BACKUP_STATUS[$vol]="SKIP"
        return 0
    fi

    start_time=$(date +%s)
    size=$(get_volume_size "$vol")
    BACKUP_SIZE[$vol]="$size"

    if [[ "$DRY_RUN" == true ]]; then
        [[ "$IS_INTERACTIVE" == true ]] && printf "     ${NGRAY}[dry-run]${NC} Would backup: %s\n" "$vol ($size)" || log_info "[dry-run] Would backup: $vol ($size)"
        BACKUP_STATUS[$vol]="DRY"
        BACKUP_DURATION[$vol]="0s"
        return 0
    fi

    if [[ "$IS_INTERACTIVE" == true ]]; then
        if spin_run "$vol  ($size)" bash -c "
            export BORG_REPO='$BORG_REPO_PATH'
            export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes
            cd '$vol_path' && borg create --compression '$BORG_COMPRESSION' --stats \
                '${BORG_REPO_PATH}::${archive_name}' . >>'$LOG_FILE' 2>&1 && \
            borg prune --keep-daily=$RETENTION_DAILY --glob-archives '${vol}-*' '$BORG_REPO_PATH' >>'$LOG_FILE' 2>&1
        "; then
            elapsed=$(( $(date +%s) - start_time ))
            BACKUP_DURATION[$vol]="${elapsed}s"
            BACKUP_STATUS[$vol]="OK"
            gum_ok "$vol  ($size · ${elapsed}s)"
        else
            elapsed=$(( $(date +%s) - start_time ))
            BACKUP_DURATION[$vol]="${elapsed}s"
            BACKUP_STATUS[$vol]="FAIL"
            ((ERRORS++))
            gum_fail "$vol  FAILED"
        fi
    else
        export BORG_REPO="$BORG_REPO_PATH"
        export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes
        log_step "Backing up: $vol ($size)"
        if (cd "$vol_path" && borg create --compression "$BORG_COMPRESSION" --stats \
                "${BORG_REPO_PATH}::${archive_name}" .); then
            borg prune --keep-daily="$RETENTION_DAILY" --glob-archives "${vol}-*" "$BORG_REPO_PATH" 2>&1 || true
            elapsed=$(( $(date +%s) - start_time ))
            BACKUP_DURATION[$vol]="${elapsed}s"
            BACKUP_STATUS[$vol]="OK"
            log_info "OK: $vol (${elapsed}s)"
        else
            elapsed=$(( $(date +%s) - start_time ))
            BACKUP_DURATION[$vol]="${elapsed}s"
            BACKUP_STATUS[$vol]="FAIL"
            ((ERRORS++))
            log_error "FAILED: $vol"
        fi
    fi
}

backup_compose() {
    local archive_name="compose-configs-${NOW}"
    local tmpdir start_time elapsed
    start_time=$(date +%s)

    tmpdir=$(mktemp -d)
    local found=0

    for project_dir in "$COMPOSE_DIR"/*/; do
        [[ ! -d "$project_dir" ]] && continue
        local project_name has_files=false
        project_name=$(basename "$project_dir")
        for f in "$project_dir"docker-compose.yml "$project_dir"docker-compose.yaml \
                 "$project_dir"compose.yml "$project_dir"compose.yaml; do
            if [[ -f "$f" ]]; then
                mkdir -p "$tmpdir/$project_name"
                cp "$f" "$tmpdir/$project_name/"
                has_files=true
            fi
        done
        if [[ -f "$project_dir/.env" ]]; then
            mkdir -p "$tmpdir/$project_name"
            cp "$project_dir/.env" "$tmpdir/$project_name/"
            has_files=true
        fi
        [[ "$has_files" == true ]] && ((found++))
    done

    if [[ "$found" -eq 0 ]]; then
        rm -rf "$tmpdir"
        BACKUP_STATUS["compose-configs"]="SKIP"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        rm -rf "$tmpdir"
        [[ "$IS_INTERACTIVE" == true ]] && printf "     ${NGRAY}[dry-run]${NC} Would backup compose configs (%s projects)\n" "$found" || log_info "[dry-run] Would backup compose configs ($found projects)"
        BACKUP_STATUS["compose-configs"]="DRY"
        BACKUP_DURATION["compose-configs"]="0s"
        BACKUP_SIZE["compose-configs"]="configs"
        return 0
    fi

    if [[ "$IS_INTERACTIVE" == true ]]; then
        if spin_run "compose configs  ($found projects)" bash -c "
            export BORG_REPO='$BORG_REPO_PATH'
            export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes
            cd '$tmpdir' && borg create --compression '$BORG_COMPRESSION' --stats \
                '${BORG_REPO_PATH}::${archive_name}' . >>'$LOG_FILE' 2>&1 && \
            borg prune --keep-daily=$RETENTION_DAILY --glob-archives 'compose-configs-*' '$BORG_REPO_PATH' >>'$LOG_FILE' 2>&1
        "; then
            elapsed=$(( $(date +%s) - start_time ))
            BACKUP_DURATION["compose-configs"]="${elapsed}s"
            BACKUP_SIZE["compose-configs"]="configs"
            BACKUP_STATUS["compose-configs"]="OK"
            gum_ok "compose configs  ($found projects · ${elapsed}s)"
        else
            BACKUP_STATUS["compose-configs"]="FAIL"
            ((ERRORS++))
            gum_fail "compose configs  FAILED"
        fi
    else
        export BORG_REPO="$BORG_REPO_PATH"
        export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes
        log_step "Backing up compose configs ($found projects)"
        if (cd "$tmpdir" && borg create --compression "$BORG_COMPRESSION" --stats \
                "${BORG_REPO_PATH}::${archive_name}" .); then
            borg prune --keep-daily="$RETENTION_DAILY" --glob-archives "compose-configs-*" "$BORG_REPO_PATH" 2>&1 || true
            elapsed=$(( $(date +%s) - start_time ))
            BACKUP_DURATION["compose-configs"]="${elapsed}s"
            BACKUP_SIZE["compose-configs"]="configs"
            BACKUP_STATUS["compose-configs"]="OK"
            log_info "OK: compose configs (${elapsed}s)"
        else
            BACKUP_STATUS["compose-configs"]="FAIL"
            ((ERRORS++))
            log_error "FAILED: compose configs"
        fi
    fi

    rm -rf "$tmpdir"
    borg compact "$BORG_REPO_PATH" >>"$LOG_FILE" 2>&1 || true
}

build_volume_list() {
    local all_volumes
    read -ra all_volumes <<< "$(get_named_volumes)"
    local filtered=()

    if [[ ${#ONLY_VOLUMES[@]} -gt 0 ]]; then
        for vol in "${ONLY_VOLUMES[@]}"; do
            local found=false
            for av in "${all_volumes[@]}"; do [[ "$av" == "$vol" ]] && found=true && break; done
            if [[ "$found" == true ]]; then filtered+=("$vol")
            else log_warn "Volume '$vol' not found, skipping"; fi
        done
    elif [[ ${#EXCLUDE_VOLUMES[@]} -gt 0 ]]; then
        for av in "${all_volumes[@]}"; do
            local excluded=false
            for ev in "${EXCLUDE_VOLUMES[@]}"; do [[ "$av" == "$ev" ]] && excluded=true && break; done
            [[ "$excluded" == false ]] && filtered+=("$av")
        done
    else
        filtered=("${all_volumes[@]}")
    fi
    echo "${filtered[@]}"
}

print_summary() {
    local total_elapsed=$(( $(date +%s) - TOTAL_START ))

    if [[ "$IS_INTERACTIVE" == true ]]; then
        echo ""
        draw_section "BACKUP SUMMARY"

        local rows=""
        local all_keys=("${!BACKUP_STATUS[@]}")
        # Sort: compose-configs last
        local sorted_keys=()
        for k in "${all_keys[@]}"; do [[ "$k" != "compose-configs" ]] && sorted_keys+=("$k"); done
        sorted_keys+=("compose-configs")

        for vol in "${sorted_keys[@]}"; do
            local status="${BACKUP_STATUS[$vol]:-?}"
            local size="${BACKUP_SIZE[$vol]:-?}"
            local dur="${BACKUP_DURATION[$vol]:-?}"
            local status_colored
            case "$status" in
                OK)   status_colored="${NGREEN}OK  ${NC}" ;;
                FAIL) status_colored="${NRED}FAIL${NC}" ;;
                SKIP) status_colored="${NGRAY}SKIP${NC}" ;;
                DRY)  status_colored="${NYELLOW}DRY ${NC}" ;;
                *)    status_colored="$status" ;;
            esac
            printf "  %s  %-30s  %8s  %6s\n" "$status_colored" "$vol" "$size" "$dur"
        done

        # Total row
        local total_fmt; total_fmt=$(format_duration "$total_elapsed")
        printf "  ${NGRAY}%s${NC}\n" "$(printf '─%.0s' {1..52})"
        printf "  ${NGRAY}%-36s${NC}  ${NCYAN}%6s${NC}\n" "TOTAL" "$total_fmt"

        echo ""
        local repo_stats
        repo_stats=$(borg info "$BORG_REPO_PATH" 2>/dev/null | grep -E "^(Number of|Deduplicated|All archives)" | head -5)
        if [[ -n "$repo_stats" ]]; then
            gum style --foreground "$GC_DIM" "$repo_stats"
        fi
        echo ""
        if [[ "$ERRORS" -eq 0 ]]; then
            gum style \
                --border normal \
                --border-foreground "$GC_GREEN" \
                --foreground "$GC_GREEN" \
                --align center --width 64 --padding "0 2" \
                "$(gum style --bold --foreground "$GC_GREEN" "✓  Backup complete  —  ${total_fmt}")"
        else
            gum style \
                --border normal \
                --border-foreground "$GC_RED" \
                --foreground "$GC_RED" \
                --align center --width 64 --padding "0 2" \
                "$(gum style --bold --foreground "$GC_RED" "✗  Backup finished with $ERRORS error(s)  —  ${total_fmt}")"
        fi
        echo ""
    else
        echo ""
        log_info "=== BACKUP SUMMARY ($(format_duration "$total_elapsed")) ==="
        for vol in "${!BACKUP_STATUS[@]}"; do
            log_info "  ${BACKUP_STATUS[$vol]}  $vol  ${BACKUP_SIZE[$vol]:-}  ${BACKUP_DURATION[$vol]:-}"
        done
        if [[ "$ERRORS" -gt 0 ]]; then
            log_error "$ERRORS error(s) during backup"
        else
            log_info "All backups completed successfully"
        fi
    fi
}

run_backup() {
    local volumes=("$@")
    NOW=$(date +"$TIMESTAMP_FMT")   # refresh timestamp each run so archive names are unique
    TOTAL_START=$(date +%s)
    ERRORS=0

    if [[ "$IS_INTERACTIVE" == true ]]; then
        draw_section "BACKING UP ${#volumes[@]} VOLUME(S)"
    fi

    if [[ "$NO_STOP" == false ]]; then
        stop_all_containers "${volumes[@]}"
    else
        [[ "$IS_INTERACTIVE" == true ]] && gum_warn "--no-stop: containers will NOT be stopped" || log_warn "Running with --no-stop: unsafe for databases"
        echo ""
    fi

    for vol in "${volumes[@]}"; do
        backup_volume "$vol"
    done

    if [[ ${#ONLY_VOLUMES[@]} -eq 0 ]]; then
        backup_compose
    fi

    if [[ "$NO_STOP" == false ]]; then
        echo ""
        start_all_containers
    fi

    print_summary
    cleanup_old_logs
}

backup_all_noninteractive() {
    init_repo
    local volumes
    read -ra volumes <<< "$(build_volume_list)"
    [[ ${#volumes[@]} -eq 0 ]] && die "No volumes to backup"
    run_backup "${volumes[@]}"
}

# ============================================================
# LIST
# ============================================================

cmd_list() {
    local all_volumes
    read -ra all_volumes <<< "$(get_named_volumes)"

    if [[ "$IS_INTERACTIVE" == true ]]; then
        draw_header
        draw_section "NAMED VOLUMES"
        for vol in "${all_volumes[@]}"; do
            local size
            size=$(get_volume_size "$vol")
            printf "  ${NCYAN}%-30s${NC}  %s\n" "$vol" "$size"
        done
        echo ""
        draw_section "BORG REPO"
        if borg info "$BORG_REPO_PATH" &>/dev/null; then
            borg info "$BORG_REPO_PATH" 2>/dev/null | grep -E "^(Repository|Number of|Deduplicated|All archives)" | while IFS= read -r line; do
                gum style --foreground "$GC_DIM" "  $line"
            done
        else
            gum_warn "Repository not initialized yet"
        fi
        echo ""
    else
        log_info "Named volumes:"
        for vol in "${all_volumes[@]}"; do
            log_info "  $vol  ($(get_volume_size "$vol"))"
        done
    fi
}

# ============================================================
# RESTORE FUNCTIONS
# ============================================================

list_archives_raw() {
    borg list --short "$BORG_REPO_PATH" 2>/dev/null
}

get_archive_groups() {
    local -A groups
    local -a order=()
    while IFS= read -r archive; do
        [[ -z "$archive" ]] && continue
        local grp
        grp=$(echo "$archive" | sed 's/-[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}_[0-9]\{4,6\}$//')
        if [[ -z "${groups[$grp]+x}" ]]; then
            order+=("$grp")
            groups[$grp]=1
        fi
    done < <(list_archives_raw)
    echo "${order[@]}"
}

restore_archive() {
    local archive="$1"
    local restore_path="$2"
    local is_compose="${3:-false}"

    mkdir -p "$restore_path"

    if [[ "$is_compose" == true ]]; then
        local tmpdir
        tmpdir=$(mktemp -d)
        (cd "$tmpdir" && borg extract "${BORG_REPO_PATH}::${archive}")
        cp -r "$tmpdir"/*/ "$restore_path/" 2>/dev/null || cp -r "$tmpdir"/* "$restore_path/"
        rm -rf "$tmpdir"
    else
        (cd "$restore_path" && borg extract "${BORG_REPO_PATH}::${archive}")
    fi
}

# Restore a single group from a specific archive (shared logic)
_restore_one() {
    local grp="$1" archive="$2"
    local target_path is_compose=false

    if [[ "$grp" == "compose-configs" ]]; then
        if [[ -n "$RESTORE_TO" ]]; then
            target_path="$RESTORE_TO/compose-configs"
        else
            target_path="$COMPOSE_DIR"
            is_compose=true
        fi
    else
        if [[ -n "$RESTORE_TO" ]]; then
            target_path="$RESTORE_TO/$grp"
        else
            ensure_volume_exists "$grp"
            target_path="$VOLUME_BASE/$grp/_data"
        fi
    fi

    if [[ "$IS_INTERACTIVE" == true ]]; then
        if spin_run "$grp  ←  $archive" bash -c "
            export BORG_REPO='$BORG_REPO_PATH'
            export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes
            mkdir -p '$target_path'
            $(if [[ "$is_compose" == true ]]; then
                echo "tmpdir=\$(mktemp -d) && cd \"\$tmpdir\" && borg extract '${BORG_REPO_PATH}::${archive}' && cp -r \"\$tmpdir\"/*/  '$target_path/' 2>/dev/null || cp -r \"\$tmpdir\"/* '$target_path/' && rm -rf \"\$tmpdir\""
            else
                echo "cd '$target_path' && borg extract '${BORG_REPO_PATH}::${archive}'"
            fi)
        "; then
            gum_ok "$grp  ←  $archive"
            return 0
        else
            gum_fail "$grp  FAILED"
            return 1
        fi
    else
        log_step "Restoring: $grp from $archive"
        mkdir -p "$target_path"
        if restore_archive "$archive" "$target_path" "$is_compose"; then
            log_info "OK: $grp"
            return 0
        else
            log_error "FAILED: $grp"
            return 1
        fi
    fi
}

# Global arrays populated by _stop_containers_for_groups for ordered restart
RESTORE_STOPPED_DB_IDS=()
RESTORE_STOPPED_DB_NAMES=()
RESTORE_STOPPED_APP_IDS=()
RESTORE_STOPPED_APP_NAMES=()

# Stop all containers affected by a list of volume groups.
# Two-pass: finds containers directly using volumes, then expands to their
# full compose projects (catches bind-mount-only siblings like app+db pairs).
# Stops apps first, then DBs. Populates RESTORE_STOPPED_* globals.
_stop_containers_for_groups() {
    local -a grps=("$@")
    local -A _seen_cid
    local -A _compose_projects

    RESTORE_STOPPED_DB_IDS=()
    RESTORE_STOPPED_DB_NAMES=()
    RESTORE_STOPPED_APP_IDS=()
    RESTORE_STOPPED_APP_NAMES=()

    # Pass 1: direct volume → container, collect compose projects
    for grp in "${grps[@]}"; do
        [[ "$grp" == "compose-configs" ]] && continue
        while IFS= read -r cid; do
            [[ -z "$cid" ]] && continue
            _seen_cid[$cid]=1
            local proj
            proj=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$cid" 2>/dev/null)
            [[ -n "$proj" ]] && _compose_projects[$proj]=1
        done < <(docker ps -aq --filter "volume=$grp" 2>/dev/null)
    done

    # Pass 2: expand to all containers in those compose projects
    for proj in "${!_compose_projects[@]}"; do
        while IFS= read -r cid; do
            [[ -z "$cid" ]] && continue
            _seen_cid[$cid]=1
        done < <(docker ps -aq --filter "label=com.docker.compose.project=$proj" 2>/dev/null)
    done

    # Classify running containers into DB / APP
    for cid in "${!_seen_cid[@]}"; do
        local state
        state=$(docker inspect --format '{{.State.Status}}' "$cid" 2>/dev/null)
        [[ "$state" != "running" && "$state" != "restarting" ]] && continue
        local cname; cname=$(get_container_name "$cid")
        if is_db_container "$cid"; then
            RESTORE_STOPPED_DB_IDS+=("$cid")
            RESTORE_STOPPED_DB_NAMES+=("$cname")
        else
            RESTORE_STOPPED_APP_IDS+=("$cid")
            RESTORE_STOPPED_APP_NAMES+=("$cname")
        fi
    done

    local n_app=${#RESTORE_STOPPED_APP_IDS[@]}
    local n_db=${#RESTORE_STOPPED_DB_IDS[@]}
    local n_total=$(( n_app + n_db ))
    [[ $n_total -eq 0 ]] && return 0

    if [[ "$IS_INTERACTIVE" == true ]]; then
        gum_step "Stopping $n_total container(s)  (${STOP_TIMEOUT}s grace)"
        for i in "${!RESTORE_STOPPED_APP_IDS[@]}"; do
            printf "     ${NCYAN}[app]${NC}  %s\n" "${RESTORE_STOPPED_APP_NAMES[$i]}"
        done
        for i in "${!RESTORE_STOPPED_DB_IDS[@]}"; do
            printf "     ${NYELLOW}[DB]${NC}   %s\n" "${RESTORE_STOPPED_DB_NAMES[$i]}"
        done
        echo ""
        # Apps first, then DBs
        [[ $n_app -gt 0 ]] && spin_run "Stopping apps..."      docker stop --time "$STOP_TIMEOUT" "${RESTORE_STOPPED_APP_IDS[@]}"
        [[ $n_db  -gt 0 ]] && spin_run "Stopping databases..." docker stop --time "$STOP_TIMEOUT" "${RESTORE_STOPPED_DB_IDS[@]}"
        gum_ok "Stopped $n_total container(s)"
    else
        [[ $n_app -gt 0 ]] && docker stop --time "$STOP_TIMEOUT" "${RESTORE_STOPPED_APP_IDS[@]}" &>/dev/null
        [[ $n_db  -gt 0 ]] && docker stop --time "$STOP_TIMEOUT" "${RESTORE_STOPPED_DB_IDS[@]}" &>/dev/null
    fi
}

cmd_restore_interactive() {
    init_repo

    if [[ "$IS_INTERACTIVE" != true ]]; then
        log_error "--restore requires an interactive terminal"
        exit 1
    fi

    draw_header
    draw_section "RESTORE"

    local groups
    read -ra groups <<< "$(get_archive_groups)"
    [[ ${#groups[@]} -eq 0 ]] && { gum_fail "No archives found in repository"; return; }

    # ── Top-level: what to restore ──────────────────────────────
    local mode
    mode=$(gum choose \
        --height 6 \
        --cursor "  ▸ " \
        --cursor.foreground "$GC_PINK" \
        --item.foreground "$GC_WHITE" \
        --header "$(gum style --foreground "$GC_PURPLE" "  ┄┄  RESTORE MODE  ┄┄")" \
        "⚡  Restore all (latest archives)" \
        "☑️   Restore selected volumes" \
        "── Cancel ──") || return 0
    [[ "$mode" == "── Cancel ──" ]] && return 0

    # ── Build group list with archive counts ────────────────────
    local menu_items=()
    for grp in "${groups[@]}"; do
        local count
        count=$(borg list --short --glob-archives "${grp}-*" "$BORG_REPO_PATH" 2>/dev/null | wc -l)
        menu_items+=("$grp  ($count archives)")
    done

    local selected_groups=()

    if [[ "$mode" == *"Restore all"* ]]; then
        # All groups
        selected_groups=("${groups[@]}")
    else
        # Multi-select checkboxes
        echo ""
        local raw_selected
        raw_selected=$(gum choose \
            --no-limit \
            --height 18 \
            --cursor "  ▸ " \
            --cursor.foreground "$GC_PINK" \
            --item.foreground "$GC_WHITE" \
            --selected.foreground "$GC_CYAN" \
            --selected-prefix "  ● " \
            --unselected-prefix "  ○ " \
            --header "$(gum style --foreground "$GC_PURPLE" "  Select volumes to restore  (space to toggle):")" \
            "${menu_items[@]}") || return 0
        [[ -z "$raw_selected" ]] && { gum_warn "Nothing selected"; return; }

        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local grp_name
            grp_name=$(echo "$line" | sed 's/  ([0-9]* archives)$//')
            selected_groups+=("$grp_name")
        done <<< "$raw_selected"
    fi

    [[ ${#selected_groups[@]} -eq 0 ]] && { gum_warn "Nothing to restore"; return; }

    # ── Archive selection: latest-for-all or pick per volume ────
    echo ""
    local use_latest=true
    if ! gum confirm \
        --affirmative "Latest for all" \
        --negative "Pick per volume" \
        --default=true \
        "$(gum style --foreground "$GC_CYAN" "Use latest archive for each selected volume?")"; then
        use_latest=false
    fi

    # Build a map: group → archive to restore
    declare -A restore_map
    for grp in "${selected_groups[@]}"; do
        if [[ "$use_latest" == true ]]; then
            local latest
            latest=$(borg list --short --glob-archives "${grp}-*" --sort-by timestamp --last 1 "$BORG_REPO_PATH" 2>/dev/null)
            if [[ -z "$latest" ]]; then
                gum_warn "No archives found for $grp — skipping"
                continue
            fi
            restore_map[$grp]="$latest"
        else
            local archives=()
            while IFS= read -r a; do
                [[ -z "$a" ]] && continue
                archives+=("$a")
            done < <(borg list --short --glob-archives "${grp}-*" --sort-by timestamp "$BORG_REPO_PATH" 2>/dev/null)

            if [[ ${#archives[@]} -eq 0 ]]; then
                gum_warn "No archives found for $grp — skipping"
                continue
            fi

            echo ""
            local pick
            pick=$(gum choose \
                --height 15 \
                --cursor "  ▸ " \
                --cursor.foreground "$GC_PINK" \
                --item.foreground "$GC_WHITE" \
                --header "$(gum style --foreground "$GC_PURPLE" "  Archive for: $grp")" \
                "latest  (${archives[-1]})" \
                "${archives[@]}" \
                "── Skip ──") || continue
            [[ "$pick" == "── Skip ──" ]] && continue
            if [[ "$pick" == latest* ]]; then
                restore_map[$grp]="${archives[-1]}"
            else
                restore_map[$grp]="$pick"
            fi
        fi
    done

    [[ ${#restore_map[@]} -eq 0 ]] && { gum_warn "Nothing to restore"; return; }

    # ── Summary + confirm ────────────────────────────────────────
    echo ""
    draw_section "RESTORE PLAN"
    for grp in "${!restore_map[@]}"; do
        printf "     %s  ←  %s\n" \
            "$(gum style --foreground "$GC_CYAN" "$grp")" \
            "$(gum style --foreground "$GC_DIM" "${restore_map[$grp]}")"
    done
    echo ""
    gum confirm \
        --affirmative "Restore" \
        --negative "Cancel" \
        --default=true \
        "$(gum style --foreground "$GC_PINK" --bold "Restore ${#restore_map[@]} item(s)?")" || return 0

    # ── Stop containers (apps first, then DBs, full compose projects) ──
    echo ""
    local grp_list=("${!restore_map[@]}")
    _stop_containers_for_groups "${grp_list[@]}"
    local n_stopped=$(( ${#RESTORE_STOPPED_DB_IDS[@]} + ${#RESTORE_STOPPED_APP_IDS[@]} ))
    [[ $n_stopped -eq 0 ]] && gum_info "No running containers to stop"
    echo ""

    # ── Restore ──────────────────────────────────────────────────
    draw_section "RESTORING"
    local errors=0
    for grp in "${!restore_map[@]}"; do
        _restore_one "$grp" "${restore_map[$grp]}" || (( errors++ )) || true
    done
    echo ""

    if [[ $errors -eq 0 ]]; then
        gum_ok "All ${#restore_map[@]} item(s) restored successfully"
    else
        gum_warn "$errors item(s) failed to restore"
    fi

    # ── Offer to restart — DBs first, then apps ──────────────────
    if [[ $n_stopped -gt 0 ]] && [[ -z "$RESTORE_TO" ]]; then
        echo ""
        if gum confirm \
            --affirmative "Start them" \
            --negative "Leave stopped" \
            --default=true \
            "$(gum style --foreground "$GC_CYAN" "Restart the $n_stopped container(s) that were stopped?")"; then
            _reset_started_compose
            if [[ ${#RESTORE_STOPPED_DB_IDS[@]} -gt 0 ]]; then
                gum_step "Starting ${#RESTORE_STOPPED_DB_IDS[@]} database(s) first..."
                for i in "${!RESTORE_STOPPED_DB_IDS[@]}"; do
                    start_container "${RESTORE_STOPPED_DB_IDS[$i]}" \
                        && gum_ok "DB: ${RESTORE_STOPPED_DB_NAMES[$i]}" \
                        || gum_warn "Failed: ${RESTORE_STOPPED_DB_NAMES[$i]}"
                done
                sleep 5
            fi
            if [[ ${#RESTORE_STOPPED_APP_IDS[@]} -gt 0 ]]; then
                gum_step "Starting ${#RESTORE_STOPPED_APP_IDS[@]} app(s)..."
                for i in "${!RESTORE_STOPPED_APP_IDS[@]}"; do
                    start_container "${RESTORE_STOPPED_APP_IDS[$i]}" \
                        && gum_ok "App: ${RESTORE_STOPPED_APP_NAMES[$i]}" \
                        || gum_warn "Failed: ${RESTORE_STOPPED_APP_NAMES[$i]}"
                done
            fi
        fi
    fi
}

cmd_restore_latest() {
    init_repo

    local groups
    read -ra groups <<< "$(get_archive_groups)"
    [[ ${#groups[@]} -eq 0 ]] && die "No archives found in repository"

    [[ "$IS_INTERACTIVE" == true ]] && draw_section "RESTORING LATEST ARCHIVES"

    local errors=0
    for grp in "${groups[@]}"; do
        local latest
        latest=$(borg list --short --glob-archives "${grp}-*" --sort-by timestamp --last 1 "$BORG_REPO_PATH" 2>/dev/null)
        [[ -z "$latest" ]] && continue
        _restore_one "$grp" "$latest" || (( errors++ )) || true
    done

    if [[ "$IS_INTERACTIVE" == true ]]; then
        echo ""
        [[ $errors -eq 0 ]] && gum_ok "All volumes restored" || gum_warn "$errors volume(s) failed"
        echo ""
    fi
}

cmd_restore_archive() {
    local archive="$1"
    init_repo

    local grp
    grp=$(echo "$archive" | sed 's/-[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}_[0-9]\{4,6\}$//')

    _restore_one "$grp" "$archive" || die "Restore failed"
}

# ============================================================
# INTERACTIVE MAIN MENU
# ============================================================

menu_backup_all() {
    init_repo
    local volumes
    read -ra volumes <<< "$(build_volume_list)"
    [[ ${#volumes[@]} -eq 0 ]] && { gum_fail "No named volumes found"; return; }
    run_backup "${volumes[@]}"
}

menu_backup_selected() {
    local all_volumes
    read -ra all_volumes <<< "$(get_named_volumes)"
    [[ ${#all_volumes[@]} -eq 0 ]] && { gum_fail "No named volumes found"; return; }

    echo ""
    draw_section "SELECT VOLUMES TO BACKUP"

    local selected
    selected=$(gum choose \
        --no-limit \
        --height 15 \
        --cursor "  ▸ " \
        --cursor.foreground "$GC_PINK" \
        --item.foreground "$GC_WHITE" \
        --selected.foreground "$GC_CYAN" \
        --selected-prefix "  ● " \
        --unselected-prefix "  ○ " \
        --header "$(gum style --foreground "$GC_PURPLE" "  Space to select · Enter to confirm:")" \
        "${all_volumes[@]}") || return 0

    [[ -z "$selected" ]] && { gum_warn "Nothing selected"; return; }

    local vols=()
    while IFS= read -r v; do
        [[ -n "$v" ]] && vols+=("$v")
    done <<< "$selected"

    init_repo
    run_backup "${vols[@]}"
}

menu_backup_exclude() {
    local all_volumes
    read -ra all_volumes <<< "$(get_named_volumes)"
    [[ ${#all_volumes[@]} -eq 0 ]] && { gum_fail "No named volumes found"; return; }

    echo ""
    draw_section "SELECT VOLUMES TO EXCLUDE"

    local excluded
    excluded=$(gum choose \
        --no-limit \
        --height 15 \
        --cursor "  ▸ " \
        --cursor.foreground "$GC_PINK" \
        --item.foreground "$GC_WHITE" \
        --selected.foreground "$GC_RED" \
        --selected-prefix "  ✗ " \
        --unselected-prefix "  ✓ " \
        --header "$(gum style --foreground "$GC_PURPLE" "  SPACE to toggle exclude  ·  ENTER to confirm:")" \
        "${all_volumes[@]}") || return 0

    local ex_list=()
    while IFS= read -r v; do
        [[ -n "$v" ]] && ex_list+=("$v")
    done <<< "$excluded"

    if [[ ${#ex_list[@]} -eq 0 ]]; then
        echo ""
        gum_warn "Nothing excluded — this will backup ALL volumes"
        echo ""
        gum confirm \
            --affirmative "Backup all" \
            --negative "Cancel" \
            --default=false \
            "$(gum style --foreground "$GC_YELLOW" "No volumes were excluded. Backup everything?")" || return 0
    fi

    local vols=()
    for av in "${all_volumes[@]}"; do
        local skip=false
        for ex in "${ex_list[@]}"; do [[ "$av" == "$ex" ]] && skip=true && break; done
        [[ "$skip" == false ]] && vols+=("$av")
    done

    [[ ${#vols[@]} -eq 0 ]] && { gum_warn "All volumes excluded — nothing to backup"; return; }

    init_repo
    run_backup "${vols[@]}"
}

menu_dry_run() {
    DRY_RUN=true
    init_repo
    local volumes
    read -ra volumes <<< "$(build_volume_list)"
    [[ ${#volumes[@]} -eq 0 ]] && { gum_fail "No named volumes found"; return; }

    echo ""
    draw_section "DRY RUN PREVIEW"
    for vol in "${volumes[@]}"; do
        local size; size=$(get_volume_size "$vol")
        gum_info "Would backup: $(gum style --foreground "$GC_CYAN" "$vol")  ($size)"
    done
    gum_info "Would backup: compose-configs"
    echo ""
    gum style --foreground "$GC_DIM" "  No changes made."
    echo ""
    DRY_RUN=false
}

menu_list() {
    cmd_list
}

menu_change_repo() {
    echo ""
    draw_section "CHANGE REPO PATH"
    printf "  ${NGRAY}current:${NC} %s\n" "$BORG_REPO_PATH"
    echo ""
    local new_path
    new_path=$(gum input \
        --placeholder "/path/to/borg/repo" \
        --value "$BORG_REPO_PATH" \
        --width 64 \
        --prompt "  Repo path: " \
        --prompt.foreground "$GC_PINK") || return 0
    [[ -z "$new_path" || "$new_path" == "$BORG_REPO_PATH" ]] && { gum_info "No change"; return 0; }
    BORG_REPO_PATH="$new_path"
    save_config
    gum_ok "Repo path saved: $BORG_REPO_PATH"
    echo ""
}

menu_delete_backups() {
    echo ""
    draw_section "DELETE BACKUPS"

    if ! borg info "$BORG_REPO_PATH" &>/dev/null; then
        gum_warn "Repository not initialized at: $BORG_REPO_PATH"
        return
    fi

    # ── Pick a volume group ──────────────────────────────────────
    local groups
    read -ra groups <<< "$(get_archive_groups)"
    [[ ${#groups[@]} -eq 0 ]] && { gum_warn "No archives found in repository"; return; }

    local menu_items=()
    for grp in "${groups[@]}"; do
        local count
        count=$(borg list --short --glob-archives "${grp}-*" "$BORG_REPO_PATH" 2>/dev/null | wc -l)
        menu_items+=("$grp  ($count archives)")
    done
    menu_items+=("── Cancel ──")

    local grp_choice
    grp_choice=$(gum choose \
        --height 16 \
        --cursor "  ▸ " \
        --cursor.foreground "$GC_RED" \
        --item.foreground "$GC_WHITE" \
        --header "$(gum style --foreground "$GC_PURPLE" "  Select a volume to delete archives from:")" \
        "${menu_items[@]}") || return 0
    [[ "$grp_choice" == "── Cancel ──" || -z "$grp_choice" ]] && return 0

    local selected_group
    selected_group=$(echo "$grp_choice" | sed 's/  ([0-9]* archives)$//')

    # ── List archives for this group, newest first ───────────────
    local archives=()
    while IFS= read -r a; do
        [[ -n "$a" ]] && archives+=("$a")
    done < <(borg list --short --glob-archives "${selected_group}-*" \
        --sort-by timestamp "$BORG_REPO_PATH" 2>/dev/null | tac)

    [[ ${#archives[@]} -eq 0 ]] && { gum_warn "No archives found for $selected_group"; return; }

    # Add "Delete ALL" option at top
    local pick_items=("⚠️   Delete ALL ${#archives[@]} archives for ${selected_group}" "${archives[@]}" "── Cancel ──")

    echo ""
    local raw_selected
    raw_selected=$(gum choose \
        --no-limit \
        --height 18 \
        --cursor "  ▸ " \
        --cursor.foreground "$GC_RED" \
        --item.foreground "$GC_WHITE" \
        --selected.foreground "$GC_RED" \
        --selected-prefix "  ✗ " \
        --unselected-prefix "  ○ " \
        --header "$(gum style --foreground "$GC_PURPLE" "  SPACE to mark for deletion  ·  ENTER to confirm:")" \
        "${pick_items[@]}") || return 0

    [[ -z "$raw_selected" ]] && { gum_info "Nothing selected"; return 0; }
    [[ "$raw_selected" == "── Cancel ──" ]] && return 0

    # ── Build final list of archives to delete ───────────────────
    local to_delete=()
    if echo "$raw_selected" | grep -q "Delete ALL"; then
        to_delete=("${archives[@]}")
    else
        while IFS= read -r line; do
            [[ -n "$line" && "$line" != "── Cancel ──" ]] && to_delete+=("$line")
        done <<< "$raw_selected"
    fi

    [[ ${#to_delete[@]} -eq 0 ]] && { gum_info "Nothing to delete"; return 0; }

    # ── Confirm ──────────────────────────────────────────────────
    echo ""
    gum_warn "About to permanently delete ${#to_delete[@]} archive(s) from ${selected_group}:"
    for a in "${to_delete[@]}"; do
        printf "     ${NRED}✗${NC}  %s\n" "$a"
    done
    echo ""
    gum confirm \
        --affirmative "Delete" \
        --negative "Cancel" \
        --default=false \
        "$(gum style --foreground "$GC_RED" --bold "Permanently delete ${#to_delete[@]} archive(s)?")" || return 0

    # ── Delete ───────────────────────────────────────────────────
    echo ""
    local errors=0
    for archive in "${to_delete[@]}"; do
        if spin_run "Deleting ${archive}..." bash -c "
            export BORG_REPO='$BORG_REPO_PATH'
            export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes
            borg delete '${BORG_REPO_PATH}::${archive}' >>'$LOG_FILE' 2>&1
        "; then
            gum_ok "Deleted: $archive"
        else
            gum_fail "Failed: $archive"
            (( errors++ )) || true
        fi
    done

    # Compact repo to reclaim space
    echo ""
    spin_run "Compacting repository..." bash -c "
        export BORG_REPO='$BORG_REPO_PATH'
        export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes
        borg compact '$BORG_REPO_PATH' >>'$LOG_FILE' 2>&1
    "

    echo ""
    if [[ $errors -eq 0 ]]; then
        gum_ok "Deleted ${#to_delete[@]} archive(s) and compacted repo"
    else
        gum_warn "$errors deletion(s) failed"
    fi
}

menu_delete_volumes() {
    echo ""
    draw_section "DELETE DOCKER VOLUMES"

    # Get all named volumes with size
    local -a all_volumes=()
    while IFS= read -r vol; do
        [[ -z "$vol" ]] && continue
        local size; size=$(get_volume_size "$vol")
        all_volumes+=("$vol  ($size)")
    done < <(docker volume ls --format '{{.Name}}' | grep -vE '^[0-9a-f]{64}$' | sort)

    [[ ${#all_volumes[@]} -eq 0 ]] && { gum_warn "No named volumes found"; return; }

    echo ""
    local raw_selected
    raw_selected=$(gum choose \
        --no-limit \
        --height 18 \
        --cursor "  ▸ " \
        --cursor.foreground "$GC_PINK" \
        --item.foreground "$GC_WHITE" \
        --selected.foreground "$GC_RED" \
        --selected-prefix "  ● " \
        --unselected-prefix "  ○ " \
        --header "$(gum style --foreground "$GC_RED" --bold "  ⚠  Select volumes to DELETE  (space to toggle):")" \
        "${all_volumes[@]}") || return 0

    [[ -z "$raw_selected" ]] && { gum_warn "Nothing selected"; return; }

    # Strip size suffix to get plain volume names
    local -a selected_vols=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        selected_vols+=("$(echo "$line" | sed 's/  ([^)]*)$//')")
    done <<< "$raw_selected"

    # Show what will be deleted and which containers use each volume
    echo ""
    draw_section "VOLUMES TO DELETE"
    local -a all_affected_cids=()
    for vol in "${selected_vols[@]}"; do
        local size; size=$(get_volume_size "$vol")
        printf "     ${NRED}%-36s  %s${NC}\n" "$vol" "$size"
        # Show containers using this volume
        while IFS= read -r cid; do
            [[ -z "$cid" ]] && continue
            local cname; cname=$(get_container_name "$cid")
            local state; state=$(docker inspect --format '{{.State.Status}}' "$cid" 2>/dev/null)
            printf "       ${NGRAY}└─ %s  (%s)${NC}\n" "$cname" "$state"
            all_affected_cids+=("$cid")
        done < <(docker ps -aq --filter "volume=$vol" 2>/dev/null)
    done
    echo ""

    # Stop running containers that use these volumes
    local -a running_cids=()
    for cid in "${all_affected_cids[@]}"; do
        local state; state=$(docker inspect --format '{{.State.Status}}' "$cid" 2>/dev/null)
        [[ "$state" == "running" || "$state" == "restarting" ]] && running_cids+=("$cid")
    done

    if [[ ${#running_cids[@]} -gt 0 ]]; then
        gum_warn "${#running_cids[@]} container(s) must be stopped before volume deletion"
        gum confirm \
            --affirmative "Stop & delete" \
            --negative "Cancel" \
            --default=false \
            "$(gum style --foreground "$GC_RED" --bold "⚠  Stop containers and permanently delete ${#selected_vols[@]} volume(s)?")" || return 0
        echo ""
        spin_run "Stopping containers..." docker stop --time "$STOP_TIMEOUT" "${running_cids[@]}"
    else
        gum confirm \
            --affirmative "Delete" \
            --negative "Cancel" \
            --default=false \
            "$(gum style --foreground "$GC_RED" --bold "⚠  Permanently delete ${#selected_vols[@]} volume(s)? This cannot be undone.")" || return 0
    fi

    echo ""
    local errors=0
    for vol in "${selected_vols[@]}"; do
        if docker volume rm "$vol" >>"$LOG_FILE" 2>&1; then
            gum_ok "Deleted volume: $vol"
        else
            gum_fail "Failed to delete: $vol"
            (( errors++ )) || true
        fi
    done
    echo ""
    if [[ $errors -eq 0 ]]; then
        gum_ok "Deleted ${#selected_vols[@]} volume(s)"
    else
        gum_warn "$errors volume(s) could not be deleted (may still have containers attached)"
    fi
}

_human_size() {
    local bytes="$1"
    if   (( bytes >= 1073741824 )); then awk "BEGIN{printf \"%.1f GB\", $bytes/1073741824}"
    elif (( bytes >= 1048576    )); then awk "BEGIN{printf \"%.1f MB\", $bytes/1048576}"
    elif (( bytes >= 1024       )); then awk "BEGIN{printf \"%.1f KB\", $bytes/1024}"
    else echo "${bytes} B"
    fi
}

menu_repo_info() {
    echo ""
    draw_section "REPOSITORY INFO"
    if ! borg info "$BORG_REPO_PATH" &>/dev/null; then
        gum_warn "Repository not initialized at: $BORG_REPO_PATH"
        return
    fi

    local tmpdir; tmpdir=$(mktemp -d)
    local rawfile="$tmpdir/raw"

    # Write vol|archive|date for every archive (borg outputs oldest→newest)
    while IFS='|' read -r archive date; do
        [[ -z "$archive" ]] && continue
        local vol="${archive%-????-??-??_????*}"
        [[ -z "$vol" ]] && vol="$archive"
        printf '%s|%s|%s\n' "$vol" "$archive" "$date" >> "$rawfile"
    done < <(borg list \
        --format '{archive}|{start:%Y-%m-%d %H:%M}{NL}' \
        --sort-by timestamp \
        "$BORG_REPO_PATH" 2>/dev/null)

    if [[ ! -s "$rawfile" ]]; then
        rm -rf "$tmpdir"
        gum_warn "No archives found in repository"
        return
    fi

    # Sorted unique volume names
    local -a sorted_vols=()
    while IFS= read -r v; do
        [[ -n "$v" ]] && sorted_vols+=("$v")
    done < <(awk -F'|' '{print $1}' "$rawfile" | sort -u)

    # Fetch size of latest archive per group — all in parallel, write idx|cs|ds to sizefile
    local sizefile="$tmpdir/sizes"
    local idx=0
    for vol in "${sorted_vols[@]}"; do
        local latest
        latest=$(awk -F'|' -v v="$vol" '$1==v {last=$2} END{print last}' "$rawfile")
        if [[ -n "$latest" ]]; then
            local _idx="$idx"
            (
                result=$(borg info --json "${BORG_REPO_PATH}::${latest}" 2>/dev/null \
                    | python3 -c "
import sys,json
d=json.load(sys.stdin)
s=d['archives'][0]['stats']
print(s['compressed_size'],s['deduplicated_size'])
" 2>/dev/null)
                [[ -n "$result" ]] && echo "${_idx}|${result}" >> "$sizefile"
            ) &
        fi
        (( idx++ )) || true
    done
    wait

    # Build pager content
    local pager_content=""
    pager_content+="$(printf "  ${NCYAN}${NBOLD}%-46s  %-16s  %-22s${NC}\n" "ARCHIVE" "DATE" "LATEST SIZE")"$'\n'
    pager_content+="$(printf "  ${NGRAY}%s${NC}\n" "$(printf '─%.0s' {1..88})")"$'\n\n'

    idx=0
    for vol in "${sorted_vols[@]}"; do
        local size_str=""
        local size_line; size_line=$(grep "^${idx}|" "$sizefile" 2>/dev/null | head -1)
        if [[ -n "$size_line" ]]; then
            local cs ds
            IFS='|' read -r _ cs ds <<< "$size_line"
            if [[ -n "$cs" && "$cs" =~ ^[0-9]+$ && "$cs" -gt 0 ]]; then
                size_str="$(_human_size "$cs")  /  $(_human_size "$ds") dedup"
            fi
        fi

        if [[ -n "$size_str" ]]; then
            pager_content+="$(printf "  ${NPINK}${NBOLD}%-46s  ${NCYAN}%s${NC}\n" "$vol" "$size_str")"$'\n'
        else
            pager_content+="$(printf "  ${NPINK}${NBOLD}%s${NC}\n" "$vol")"$'\n'
        fi

        # Archives newest-first (borg wrote oldest-first, tac reverses)
        while IFS='|' read -r _ archive date; do
            pager_content+="$(printf "    ${NGRAY}%-46s  %s${NC}\n" "$archive" "$date")"$'\n'
        done < <(awk -F'|' -v v="$vol" '$1==v' "$rawfile" | tac)

        pager_content+=$'\n'
        (( idx++ )) || true
    done

    # Totals
    pager_content+="$(printf "  ${NPURPLE}${NBOLD}── TOTALS ──${NC}\n")"$'\n'
    pager_content+="$(printf "  ${NGRAY}%s${NC}\n" "$(printf '─%.0s' {1..88})")"$'\n'
    while IFS= read -r line; do
        pager_content+="$(printf "  ${NGRAY}%s${NC}\n" "$line")"$'\n'
    done < <(borg info "$BORG_REPO_PATH" 2>/dev/null | \
        grep -E "^(Repository ID|Location|Number of|Deduplicated|All archives|Unique)")

    rm -rf "$tmpdir"
    echo -e "$pager_content" | gum pager
}

main_menu() {
    while true; do
        clear
        draw_header

        local choice
        choice=$(gum choose \
            --height 15 \
            --cursor "  ▸ " \
            --cursor.foreground "$GC_PINK" \
            --item.foreground "$GC_WHITE" \
            --selected.foreground "$GC_CYAN" \
            --header "$(gum style --foreground "$GC_PURPLE" "  ┄┄  SELECT OPERATION  ┄┄")" \
            "⚡  Backup all volumes" \
            "🎯  Backup selected volumes" \
            "🚫  Backup all except..." \
            "♻️   Restore from backup" \
            "🗑️   Delete backups" \
            "💣  Delete volumes" \
            "📋  List volumes" \
            "📦  Repository info" \
            "🔮  Dry run (preview)" \
            "🗄️   Change repo path" \
            "🚪  Quit") || break

        case "$choice" in
            *"except"*)
                clear; draw_header
                menu_backup_exclude
                ;;
            *"all volumes"*)
                clear; draw_header
                menu_backup_all
                ;;
            *"selected"*)
                clear; draw_header
                menu_backup_selected
                echo ""
                gum confirm --affirmative "Back to menu" --negative "Exit" "Return to main menu?" && continue || break
                ;;
            *"Restore"*)
                clear
                cmd_restore_interactive
                echo ""
                gum confirm --affirmative "Back to menu" --negative "Exit" "Return to main menu?" && continue || break
                ;;
            *"Delete backups"*)
                clear; draw_header
                menu_delete_backups
                echo ""
                gum confirm --affirmative "Back to menu" --negative "Exit" "Return to main menu?" && continue || break
                ;;
            *"Delete volumes"*)
                clear; draw_header
                menu_delete_volumes
                echo ""
                gum confirm --affirmative "Back to menu" --negative "Exit" "Return to main menu?" && continue || break
                ;;
            *"List"*)
                clear
                menu_list
                ;;
            *"Repository"*)
                clear
                menu_repo_info
                ;;
            *"Dry run"*)
                clear; draw_header
                menu_dry_run
                ;;
            *"repo path"*)
                clear; draw_header
                menu_change_repo
                ;;
            *"Quit"*|"") break ;;
        esac
    done

    clear
    gum style \
        --foreground "$GC_DIM" \
        --align center --width 64 \
        "  Goodbye."
    echo ""
}

# ============================================================
# ARGUMENT PARSING
# ============================================================

show_help() {
    cat <<EOF
Usage: sudo $(basename "$0") [OPTIONS]

Backup (default opens interactive menu):
  --only vol1,vol2       Backup only specified volumes
  --exclude vol1,vol2    Backup all except specified volumes
  --list                 Show available volumes with sizes
  --no-stop              Don't stop containers before backup
  --dry-run              Preview without doing anything

Restore:
  --restore              Interactive restore menu
  --restore latest       Restore all from most recent archives
  --restore ARCHIVE      Restore a specific archive by name
  --restore-to DIR       Extract to custom directory

Options:
  --repo PATH            Override borg repo path
  -h, --help             Show this help
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --only)
                IFS=',' read -ra ONLY_VOLUMES <<< "$2"
                ACTION="backup"
                shift 2
                ;;
            --exclude)
                IFS=',' read -ra EXCLUDE_VOLUMES <<< "$2"
                ACTION="backup"
                shift 2
                ;;
            --list)
                ACTION="list"
                shift
                ;;
            --no-stop)
                NO_STOP=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                ACTION="backup"
                shift
                ;;
            --restore)
                ACTION="restore"
                if [[ -n "${2:-}" && "${2:0:1}" != "-" ]]; then
                    RESTORE_TARGET="$2"
                    shift
                fi
                shift
                ;;
            --restore-to)
                RESTORE_TO="$2"
                shift 2
                ;;
            --repo)
                BORG_REPO_PATH="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                show_help
                exit 1
                ;;
        esac
    done
}

# ============================================================
# MAIN
# ============================================================

main() {
    require_root
    detect_mode
    parse_args "$@"
    setup_logging "${ACTION}"

    export BORG_REPO="$BORG_REPO_PATH"
    export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes

    case "$ACTION" in
        menu)
            if [[ "$IS_INTERACTIVE" == true ]]; then
                main_menu
            else
                # Called from cron with no args — run full backup
                init_repo
                local volumes
                read -ra volumes <<< "$(build_volume_list)"
                [[ ${#volumes[@]} -eq 0 ]] && die "No volumes to backup"
                run_backup "${volumes[@]}"
            fi
            ;;
        backup)
            if [[ "$IS_INTERACTIVE" == true ]]; then
                draw_header
            fi
            backup_all_noninteractive
            ;;
        list)
            cmd_list
            ;;
        restore)
            case "${RESTORE_TARGET:-}" in
                "")
                    cmd_restore_interactive
                    ;;
                latest)
                    cmd_restore_latest
                    ;;
                *)
                    cmd_restore_archive "$RESTORE_TARGET"
                    ;;
            esac
            ;;
    esac
}

main "$@"
