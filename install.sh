#!/usr/bin/env bash
#
# install.sh — dbackup installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/flippyreaper/dbackup/main/install.sh | sudo bash
#   — or —
#   sudo bash /opt/dbackup/install.sh

set -euo pipefail

REPO_URL="https://github.com/flippyreaper/dbackup.git"
INSTALL_DIR="/opt/dbackup"
FISH_FUNCTIONS_DIR=""

# ── Colors ──────────────────────────────────────────────────────────────────
C_CYAN='\033[38;2;0;255;255m'
C_PINK='\033[38;2;255;45;120m'
C_GREEN='\033[38;2;0;255;159m'
C_YELLOW='\033[38;2;255;230;0m'
C_RED='\033[38;2;255;68;68m'
C_DIM='\033[38;2;102;102;102m'
C_BOLD='\033[1m'
C_NC='\033[0m'

info()   { printf "${C_CYAN}  →  ${C_NC}%s\n" "$*"; }
ok()     { printf "${C_GREEN}  ✓  ${C_NC}%s\n" "$*"; }
warn()   { printf "${C_YELLOW}  ⚠  ${C_NC}%s\n" "$*"; }
die()    { printf "${C_RED}  ✗  ${C_NC}%s\n" "$*" >&2; exit 1; }
header() { printf "\n${C_BOLD}${C_CYAN}  ══  %s  ══${C_NC}\n\n" "$*"; }
ask() {
    local prompt="$1" default="${2:-}"
    if [[ -n "$default" ]]; then
        printf "${C_PINK}  ?  ${C_NC}%s ${C_DIM}[%s]${C_NC}: " "$prompt" "$default"
    else
        printf "${C_PINK}  ?  ${C_NC}%s: " "$prompt"
    fi
    local val
    read -r val
    echo "${val:-$default}"
}
ask_yn() {
    local prompt="$1" default="${2:-y}"
    local hint; [[ "$default" == "y" ]] && hint="Y/n" || hint="y/N"
    printf "${C_PINK}  ?  ${C_NC}%s ${C_DIM}[%s]${C_NC}: " "$prompt" "$hint"
    local val; read -r val; val="${val:-$default}"
    [[ "${val,,}" == "y" ]]
}

# ── Preflight ────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run as root: sudo bash install.sh"

# Detect the real user (for fish alias setup)
REAL_USER="${SUDO_USER:-}"
if [[ -z "$REAL_USER" ]]; then
    REAL_USER=$(logname 2>/dev/null || echo "")
fi
if [[ -z "$REAL_USER" || "$REAL_USER" == "root" ]]; then
    REAL_USER=$(ask "Fish alias for which user" "$(ls /home | head -1)")
fi
REAL_HOME=$(eval echo "~$REAL_USER")

# ── Header ───────────────────────────────────────────────────────────────────
clear
printf "\n"
printf "${C_BOLD}${C_CYAN}"
printf "  ╔════════════════════════════════════════╗\n"
printf "  ║       dbackup  —  installer            ║\n"
printf "  ╚════════════════════════════════════════╝\n"
printf "${C_NC}\n"
printf "  ${C_DIM}Installing for user: ${C_NC}${C_CYAN}%s${C_NC}  ${C_DIM}(%s)${C_NC}\n\n" "$REAL_USER" "$REAL_HOME"

# ── Dependencies ─────────────────────────────────────────────────────────────
header "DEPENDENCIES"

if ! command -v borg &>/dev/null; then
    info "Installing borgbackup..."
    apt-get install -y borgbackup -qq && ok "borgbackup installed" || die "Failed to install borgbackup"
else
    ok "borgbackup $(borg --version 2>/dev/null | awk '{print $2}')"
fi

if ! command -v gum &>/dev/null; then
    info "Installing gum (Charmbracelet)..."
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://repo.charm.sh/apt/gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/charm.gpg
    echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" \
        > /etc/apt/sources.list.d/charm.list
    apt-get update -qq
    apt-get install -y gum -qq && ok "gum installed" || die "Failed to install gum"
else
    ok "gum $(gum --version 2>/dev/null)"
fi

for cmd in python3 tac awk git; do
    command -v "$cmd" &>/dev/null && ok "$cmd" || die "$cmd not found — install it first"
done

# ── Clone / update repo ───────────────────────────────────────────────────────
header "SCRIPTS"

if [[ -d "$INSTALL_DIR/.git" ]]; then
    info "Updating $INSTALL_DIR from git..."
    git -C "$INSTALL_DIR" pull --ff-only origin main && ok "Updated to latest" || warn "Git pull failed — using existing files"
elif [[ -f "$INSTALL_DIR/dbackup.sh" ]]; then
    ok "Using existing files in $INSTALL_DIR (not a git repo — skipping update)"
else
    info "Cloning from $REPO_URL..."
    git clone "$REPO_URL" "$INSTALL_DIR" && ok "Cloned to $INSTALL_DIR" || die "Git clone failed"
fi

chmod +x "$INSTALL_DIR/dbackup.sh" "$INSTALL_DIR/cron-dbackup.sh" 2>/dev/null || true

# ── Configuration ─────────────────────────────────────────────────────────────
header "CONFIGURATION"

# Read existing config if present
EXISTING_REPO=""
EXISTING_CRON_REPO=""
[[ -f "$INSTALL_DIR/config" ]] && source "$INSTALL_DIR/config" 2>/dev/null && EXISTING_REPO="${BORG_REPO_PATH:-}"
EXISTING_CRON_REPO=$(crontab -l 2>/dev/null | grep cron-dbackup | grep -oP '(?<=--repo )\S+' || true)

# Detect candidate backup drives (large external mounts)
CANDIDATE_DRIVES=()
while IFS= read -r line; do
    mp=$(echo "$line" | awk '{print $6}')
    [[ "$mp" == /media/* || "$mp" == /mnt/* ]] && CANDIDATE_DRIVES+=("$mp")
done < <(df -h --output=target,size,avail 2>/dev/null | tail -n +2)

printf "  ${C_DIM}Detected mounts: %s${C_NC}\n" "${CANDIDATE_DRIVES[*]:-none}"
echo ""

INTERACTIVE_REPO=$(ask "Interactive repo path (used when running dbackup manually)" \
    "${EXISTING_REPO:-$INSTALL_DIR/repo}")

CRON_REPO=$(ask "Cron repo path (used by nightly cron job)" \
    "${EXISTING_CRON_REPO:-${CANDIDATE_DRIVES[0]:-/opt/dbackup/cron}/dbackup}")

COMPOSE_DIR=$(ask "Docker compose projects directory" "/opt/docker")

CRON_SCHEDULE_DEFAULT="30 2"
CRON_SCHEDULE=$(ask "Cron schedule (minute hour, 24h)" "$CRON_SCHEDULE_DEFAULT")
CRON_MIN=$(echo "$CRON_SCHEDULE" | awk '{print $1}')
CRON_HOUR=$(echo "$CRON_SCHEDULE" | awk '{print $2}')

# ── Write config file ─────────────────────────────────────────────────────────
header "WRITING CONFIG"

mkdir -p "$INSTALL_DIR/repo" "$INSTALL_DIR/logs"

cat > "$INSTALL_DIR/config" <<EOF
# dbackup persistent config — written by install.sh
BORG_REPO_PATH="$INTERACTIVE_REPO"
COMPOSE_DIR="$COMPOSE_DIR"
EOF

ok "Wrote $INSTALL_DIR/config"
mkdir -p "$INTERACTIVE_REPO" && ok "Created interactive repo dir: $INTERACTIVE_REPO" || true
mkdir -p "$CRON_REPO"         && ok "Created cron repo dir: $CRON_REPO" || true
mkdir -p "$INSTALL_DIR/logs"  && ok "Log dir: $INSTALL_DIR/logs"

# ── Fish aliases ───────────────────────────────────────────────────────────────
header "FISH ALIASES"

FISH_FUNCTIONS_DIR="$REAL_HOME/.config/fish/functions"

if command -v fish &>/dev/null; then
    mkdir -p "$FISH_FUNCTIONS_DIR"
    chown "$REAL_USER:$REAL_USER" "$FISH_FUNCTIONS_DIR" 2>/dev/null || true

    cat > "$FISH_FUNCTIONS_DIR/dbackup.fish" <<'EOF'
function dbackup --description "Docker Backup Manager"
    if test (count $argv) -eq 0
        sudo /opt/dbackup/dbackup.sh
    else
        sudo /opt/dbackup/dbackup.sh $argv
    end
end
EOF
    chown "$REAL_USER:$REAL_USER" "$FISH_FUNCTIONS_DIR/dbackup.fish"
    ok "Fish alias: dbackup → /opt/dbackup/dbackup.sh"

    cat > "$FISH_FUNCTIONS_DIR/dbackupold.fish" <<'EOF'
function dbackupold --description "Docker Backup Manager (legacy)"
    if test (count $argv) -eq 0
        sudo /opt/dbackup/cron-dbackup.sh --menu
    else
        sudo /opt/dbackup/cron-dbackup.sh $argv
    end
end
EOF
    chown "$REAL_USER:$REAL_USER" "$FISH_FUNCTIONS_DIR/dbackupold.fish"
    ok "Fish alias: dbackupold → /opt/dbackup/cron-dbackup.sh"

    # Remove stale dbackup2 if present
    rm -f "$FISH_FUNCTIONS_DIR/dbackup2.fish"
else
    warn "fish not found — skipping alias setup"
    warn "Add these manually when fish is installed:"
    printf "  ${C_DIM}dbackup   → sudo /opt/dbackup/dbackup.sh${C_NC}\n"
    printf "  ${C_DIM}dbackupold → sudo /opt/dbackup/cron-dbackup.sh${C_NC}\n"
fi

# ── Root crontab ───────────────────────────────────────────────────────────────
header "CRONTAB"

CRON_LINE="${CRON_MIN} ${CRON_HOUR} * * * /opt/dbackup/cron-dbackup.sh --repo ${CRON_REPO}"

if crontab -l 2>/dev/null | grep -q "cron-dbackup\|docker-backup"; then
    if ask_yn "Cron entry already exists — replace it?" "y"; then
        { crontab -l 2>/dev/null \
            | grep -v "cron-dbackup\|docker-backup\|Docker volume backup" \
            | grep -v "^$"
          echo ""
          echo "# dbackup — nightly backup"
          echo "$CRON_LINE"
        } | crontab -
        ok "Cron entry updated"
    else
        warn "Cron entry left unchanged"
    fi
else
    (crontab -l 2>/dev/null; echo ""; echo "# dbackup — nightly backup"; echo "$CRON_LINE") | crontab -
    ok "Cron entry added"
fi

printf "\n  ${C_DIM}%s${C_NC}\n" "$CRON_LINE"

# ── Done ───────────────────────────────────────────────────────────────────────
printf "\n"
printf "${C_BOLD}${C_GREEN}"
printf "  ╔════════════════════════════════════════╗\n"
printf "  ║         Installation complete          ║\n"
printf "  ╚════════════════════════════════════════╝\n"
printf "${C_NC}\n"
printf "  ${C_CYAN}Interactive repo:${C_NC}  %s\n" "$INTERACTIVE_REPO"
printf "  ${C_CYAN}Cron repo:        ${C_NC}  %s\n" "$CRON_REPO"
printf "  ${C_CYAN}Cron schedule:    ${C_NC}  %s %s * * *\n" "$CRON_MIN" "$CRON_HOUR"
printf "  ${C_CYAN}Fish aliases:     ${C_NC}  dbackup, dbackupold\n"
printf "\n"
printf "  ${C_DIM}Run ${C_NC}${C_CYAN}dbackup${C_NC}${C_DIM} to open the TUI.${C_NC}\n"
printf "\n"
