#!/usr/bin/env bash
# =============================================================================
# OpenSpecimen Enterprise Edition — Upgrade Script
# Target OS  : Ubuntu 24.04 LTS
# Stack      : Apache 2.4 + Java 17 + Tomcat 9 (bundled as tomcat-as) + MySQL 8.0
# Service    : Runs as dedicated user 'openspecimen'
# Usage      : sudo bash upgrade_openspecimen.sh
# =============================================================================

set -euo pipefail

# ─── Colour helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ─── Root check ──────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run this script as root: sudo bash $0"

# ─── Fixed paths & names ─────────────────────────────────────────────────────
OS_USER="openspecimen"
BASE_DIR="/usr/local/openspecimen"
TOMCAT_DIR="${BASE_DIR}/tomcat-as"
INSTALLER_DIR="${BASE_DIR}/installer"
LOG_FILE="/var/log/openspecimen_upgrade.log"

# Default properties path — installer typically places it here
DEFAULT_PROPS="${TOMCAT_DIR}/conf/openspecimen.properties"

# ─── Test input overrides (comment out after validation) ─────────────────────
USE_TEST_INPUTS="true"
TEST_OS_UPGRADE_URL="https://build.openspecimen.org/download/openspecimen_v12.2.RC8.zip"
TEST_OS_DOWNLOAD_USER="os_build_user"
TEST_OS_DOWNLOAD_PASS='G7#qV9!xL2@pR6$wD8^sT4&bZ1*FjK5m'
TEST_OS_PROPS_PATH="${DEFAULT_PROPS}"

# ─── Redirect all output to log as well ──────────────────────────────────────
exec > >(tee -a "$LOG_FILE") 2>&1

echo ""
echo "============================================================"
echo "  OpenSpecimen Enterprise Edition — Upgrade Script"
echo "  $(date)"
echo "============================================================"
echo ""

# =============================================================================
# SECTION 1 — Interactive input collection
# =============================================================================

collect_inputs() {
    info "Collecting upgrade parameters..."
    echo ""

    if [[ "${USE_TEST_INPUTS:-false}" == "true" ]]; then
        OS_UPGRADE_URL="${TEST_OS_UPGRADE_URL:-}"
        OS_DOWNLOAD_USER="${TEST_OS_DOWNLOAD_USER:-}"
        OS_DOWNLOAD_PASS="${TEST_OS_DOWNLOAD_PASS:-}"
        OS_PROPS_PATH="${TEST_OS_PROPS_PATH:-}"

        [[ -n "$OS_UPGRADE_URL"   ]] || die "TEST_OS_UPGRADE_URL cannot be empty when USE_TEST_INPUTS=true."
        [[ -n "$OS_DOWNLOAD_USER" ]] || die "TEST_OS_DOWNLOAD_USER cannot be empty when USE_TEST_INPUTS=true."
        [[ -n "$OS_DOWNLOAD_PASS" ]] || die "TEST_OS_DOWNLOAD_PASS cannot be empty when USE_TEST_INPUTS=true."
        [[ -n "$OS_PROPS_PATH"    ]] || die "TEST_OS_PROPS_PATH cannot be empty when USE_TEST_INPUTS=true."

        success "Using hardcoded test inputs."
        return
    fi

    # ── Build URL ──────────────────────────────────────────────────────────
    read -rp  "  OpenSpecimen upgrade build URL       : " OS_UPGRADE_URL
    [[ -n "$OS_UPGRADE_URL" ]] || die "Build URL cannot be empty."

    # ── Download credentials ───────────────────────────────────────────────
    read -rp  "  Download username                    : " OS_DOWNLOAD_USER
    [[ -n "$OS_DOWNLOAD_USER" ]] || die "Download username cannot be empty."

    read -rsp "  Download password                    : " OS_DOWNLOAD_PASS; echo ""
    [[ -n "$OS_DOWNLOAD_PASS" ]] || die "Download password cannot be empty."

    # ── Properties file ────────────────────────────────────────────────────
    echo ""
    read -rp  "  Path to openspecimen.properties
  [${DEFAULT_PROPS}]: " OS_PROPS_PATH
    OS_PROPS_PATH="${OS_PROPS_PATH:-${DEFAULT_PROPS}}"

    echo ""
    success "All inputs collected."
}

collect_inputs

# =============================================================================
# SECTION 2 — Validate properties file
# =============================================================================

validate_props() {
    info "Validating openspecimen.properties at: ${OS_PROPS_PATH}"
    [[ -f "$OS_PROPS_PATH" ]] || die "openspecimen.properties not found at '${OS_PROPS_PATH}'. Aborting upgrade."
    success "Properties file confirmed."
}

validate_props

# =============================================================================
# SECTION 3 — Ensure required tools
# =============================================================================

info "Ensuring required packages (curl, unzip, tmux) are present..."
apt-get install -y -qq curl unzip tmux
success "Packages ready."

# =============================================================================
# SECTION 4 — Download upgrade build
# =============================================================================

download_build() {
    local zip_file="${INSTALLER_DIR}/openspecimen_upgrade.zip"

    mkdir -p "$INSTALLER_DIR"

    info "Downloading upgrade build..."
    info "Progress: percentage, transfer speed, and ETA will be shown."
    curl -fL --progress-bar \
        --user "${OS_DOWNLOAD_USER}:${OS_DOWNLOAD_PASS}" \
        -o "$zip_file" \
        "$OS_UPGRADE_URL" \
        || die "Download failed. Verify URL and credentials."

    success "Download complete: ${zip_file}"

    # ── Extract ─────────────────────────────────────────────────────────────
    info "Extracting upgrade archive..."

    # Clean out any previous upgrade extraction to avoid stale files
    local extract_dir="${INSTALLER_DIR}/upgrade_staging"
    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"

    unzip -q -o "$zip_file" -d "$extract_dir"

    # Locate the top-level folder produced by the zip
    UPGRADE_HOME=$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d | head -1)
    [[ -n "$UPGRADE_HOME" ]] || die "Could not locate extracted upgrade directory inside archive."

    export UPGRADE_HOME
    success "Build extracted to: ${UPGRADE_HOME}"
}

download_build

# =============================================================================
# SECTION 5 — Locate install.sh inside the extracted build
# =============================================================================

locate_installer() {
    info "Looking for install.sh inside extracted build..."

    UPGRADE_INSTALL_SH=$(find "$UPGRADE_HOME" -maxdepth 2 -name "install.sh" | head -1)

    if [[ -z "$UPGRADE_INSTALL_SH" ]]; then
        die "install.sh not found inside the extracted build at '${UPGRADE_HOME}'. " \
            "This does not look like a valid OpenSpecimen build package. Aborting."
    fi

    chmod +x "$UPGRADE_INSTALL_SH"
    success "Found install.sh at: ${UPGRADE_INSTALL_SH}"
}

locate_installer

# =============================================================================
# SECTION 6 — Stop Tomcat (OpenSpecimen service)
# =============================================================================

stop_tomcat() {
    info "Stopping OpenSpecimen / Tomcat service..."

    if systemctl is-active --quiet openspecimen 2>/dev/null; then
        systemctl stop openspecimen
        # Wait up to 30 s for Tomcat to fully stop
        local waited=0
        while systemctl is-active --quiet openspecimen 2>/dev/null; do
            sleep 2
            (( waited += 2 ))
            if (( waited >= 30 )); then
                warn "Service did not stop cleanly after ${waited}s — attempting force kill..."
                systemctl kill --signal=SIGKILL openspecimen 2>/dev/null || true
                sleep 3
                break
            fi
        done
        success "OpenSpecimen service stopped."
    else
        warn "openspecimen service is not currently active — proceeding anyway."
    fi
}

stop_tomcat

# =============================================================================
# SECTION 7 — Run the upgrade
# =============================================================================

run_upgrade() {
    info "Running upgrade as '${OS_USER}'..."
    info "Command: bash install.sh '${OS_PROPS_PATH}'"
    echo ""

    # The installer must run as the openspecimen user, from its own directory
    local install_dir
    install_dir="$(dirname "$UPGRADE_INSTALL_SH")"

    # Ensure the openspecimen user can access the staging directory (root created it)
    info "Setting ownership of staging directory to '${OS_USER}'..."
    chown -R "${OS_USER}:${OS_USER}" "${INSTALLER_DIR}/upgrade_staging"
    chown "${OS_USER}:${OS_USER}" "${INSTALLER_DIR}/openspecimen_upgrade.zip" 2>/dev/null || true
    success "Ownership set."

    runuser -u "$OS_USER" -- bash -c \
        "cd '${install_dir}' && bash '${UPGRADE_INSTALL_SH}' '${OS_PROPS_PATH}'"

    echo ""
    success "OpenSpecimen upgrade installer completed."
}

run_upgrade

# =============================================================================
# SECTION 8 — Start Tomcat (OpenSpecimen service)
# =============================================================================

# =============================================================================
# SECTION 8 — Start Tomcat (OpenSpecimen service)
# =============================================================================

start_tomcat() {
    info "Starting OpenSpecimen / Tomcat service..."
    systemctl daemon-reload

    info "Waiting for installer-started Tomcat to settle (30s)..."
    sleep 30

    # Check 1: systemd already sees it as active
    if systemctl is-active --quiet openspecimen 2>/dev/null; then
        success "OpenSpecimen already running (started by installer) — skipping start."
        return 0
    fi

    # Check 2: Tomcat process is alive via PID file (systemd may not have caught up)
    if [[ -f "${TOMCAT_DIR}/bin/pid.txt" ]]; then
        local pid
        pid=$(cat "${TOMCAT_DIR}/bin/pid.txt")
        if kill -0 "$pid" 2>/dev/null; then
            info "Tomcat process alive (PID ${pid}) — skipping systemctl start."
            systemctl reset-failed openspecimen 2>/dev/null || true
            success "OpenSpecimen is running."
            return 0
        fi
    fi

    # Only reach here if both checks confirm Tomcat is NOT running
    info "Tomcat not running — starting via systemctl..."
    systemctl start openspecimen

    local waited=0
    while ! systemctl is-active --quiet openspecimen 2>/dev/null; do
        sleep 3
        (( waited += 3 ))
        if (( waited >= 60 )); then
            die "OpenSpecimen did not become active within ${waited}s. " \
                "Check: journalctl -u openspecimen  or  ${TOMCAT_DIR}/logs/catalina.out"
        fi
        info "Waiting for service to become active... (${waited}s)"
    done

    success "OpenSpecimen service is running."
}

start_tomcat   # ← THIS LINE WAS MISSING

# =============================================================================
# SECTION 9 — Cleanup
# =============================================================================

info "Cleaning up upgrade zip and staging directory..."
rm -f  "${INSTALLER_DIR}/openspecimen_upgrade.zip"
rm -rf "${INSTALLER_DIR}/upgrade_staging"
success "Cleanup done."

# =============================================================================
# Done — Summary
# =============================================================================

SERVER_IP=$(hostname -I | awk '{print $1}')
TOMCAT_PORT=8080

echo ""
echo "============================================================"
echo -e "  ${GREEN}Upgrade complete!${NC}"
echo "  $(date)"
echo "============================================================"
echo "  URL           : http://${SERVER_IP}:${TOMCAT_PORT}/openspecimen"
echo "  Properties    : ${OS_PROPS_PATH}"
echo "  Base dir      : ${BASE_DIR}"
echo "  Upgrade log   : ${LOG_FILE}"
echo ""
echo "  Service management:"
echo "    systemctl {status|start|stop|restart} openspecimen"
echo "============================================================"
echo ""

# =============================================================================
# SECTION 10 — Optional: view logs in tmux
# =============================================================================

CATALINA_LOG="${TOMCAT_DIR}/logs/catalina.out"
OS_LOG="${BASE_DIR}/data/logs/os.log"

offer_tmux_logs() {
    # Skip if not an interactive terminal (e.g. called from CI/cron)
    [[ -t 0 ]] || return 0

    echo ""
    read -rp "  Would you like to view catalina.out and os.log in tmux? [y/N]: " SHOW_LOGS
    SHOW_LOGS="${SHOW_LOGS,,}"  # lowercase

    [[ "$SHOW_LOGS" == "y" || "$SHOW_LOGS" == "yes" ]] || return 0

    # ── Ensure tmux is installed ─────────────────────────────────────────────
    if ! command -v tmux &>/dev/null; then
        info "tmux not found — installing..."
        apt-get install -y -qq tmux
        success "tmux installed."
    fi

    # ── Warn if logs don't exist yet ─────────────────────────────────────────
    [[ -f "$CATALINA_LOG" ]] || warn "catalina.out not found yet at ${CATALINA_LOG}. 'tail -f' will wait for the file."
    [[ -f "$OS_LOG"       ]] || warn "os.log not found yet at ${OS_LOG}. 'tail -f' will wait for the file."

    local SESSION="os-logs"

    # Kill any stale session with the same name
    tmux kill-session -t "$SESSION" 2>/dev/null || true

    info "Launching tmux session '${SESSION}' with two stacked panes..."
    echo ""
    echo "  ┌──────────────────────────────────────────────────────┐"
    echo "  │  TOP pane   →  catalina.out                          │"
    echo "  │  BOTTOM pane→  os.log                                │"
    echo "  │                                                       │"
    echo "  │  Keybindings (prefix = Ctrl-b):                      │"
    echo "  │    Ctrl-b ↑ / ↓   : switch pane                     │"
    echo "  │    Ctrl-b z        : zoom / unzoom focused pane      │"
    echo "  │    Ctrl-b d        : detach  (script exits cleanly)  │"
    echo "  │    q               : quit tail inside a pane         │"
    echo "  └──────────────────────────────────────────────────────┘"
    echo ""
    sleep 1

    # Build a new session; first pane = catalina.out
    tmux new-session -d -s "$SESSION" -x "$(tput cols)" -y "$(tput lines)" \
        "tail -n 100 -f '${CATALINA_LOG}' 2>/dev/null || (echo 'Waiting for ${CATALINA_LOG}...' && tail -f '${CATALINA_LOG}')"

    # Split horizontally (top / bottom), second pane = os.log
    tmux split-window -v -t "${SESSION}:0" \
        "tail -n 100 -f '${OS_LOG}' 2>/dev/null || (echo 'Waiting for ${OS_LOG}...' && tail -f '${OS_LOG}')"

    # Even out both panes
    tmux select-layout -t "${SESSION}:0" even-vertical

    # Label the panes
    tmux select-pane -t "${SESSION}:0.0" -T "catalina.out"
    tmux select-pane -t "${SESSION}:0.1" -T "os.log"

    # Focus top pane
    tmux select-pane -t "${SESSION}:0.0"

    # Attach — control returns here only after the user detaches
    tmux attach-session -t "$SESSION"

    echo ""
    success "Detached from tmux session '${SESSION}'."
    echo "  Re-attach any time with:  tmux attach -t ${SESSION}"
    echo ""
}

offer_tmux_logs
