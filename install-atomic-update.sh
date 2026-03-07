#!/usr/bin/env bash
# =============================================================================
# install-atomic-update.sh
#
# Installs and configures:
#   1. atomic-update          — transactional updater for openSUSE rw systems
#   2. Config file            — runtime settings for verbosity and notifications
#   3. Snapper no-dbus shim   — allows snapper to run without D-Bus at shutdown
#   4. Trigger script       — runs atomic-update dup on every shutdown
#   5. Systemd service        — hooks wrapper into the system shutdown/reboot sequence
#   6. Logrotate config       — keeps the log file from growing indefinitely
#   7. Plymouth masking       — shows TTY output during shutdown
#   8. Notification script    — fires desktop notifications after login
#   9. User systemd service   — runs the notification script at login
#
# Usage:
#   sudo bash install-atomic-update.sh              # install
#   sudo bash install-atomic-update.sh --uninstall  # remove everything
#
# Runtime settings (edit any time, no reinstall needed):
#   /etc/atomic-update.conf
# =============================================================================

set -euo pipefail

# ── File paths ────────────────────────────────────────────────────────────────
ATOMIC_UPDATE_BIN="/usr/bin/atomic-update"
CONF_FILE="/etc/atomic-update.conf"
SNAPPER_SHIM="/usr/local/sbin/snapper-nodbus-shim"
TRIGGER_SCRIPT="/usr/local/sbin/atomic-update-trigger"
NOTIFY_SCRIPT="/usr/local/sbin/atomic-update-notify"
SYSTEMD_SYSTEM_SERVICE="/etc/systemd/system/atomic-update-trigger.service"
LOGROTATE_CONF="/etc/logrotate.d/atomic-update-trigger"
LOG_FILE="/var/log/atomic-update-trigger.log"

# User-level paths (resolved after we know who SUDO_USER is)
INVOKING_USER=""
INVOKING_HOME=""
USER_SYSTEMD_DIR=""
USER_NOTIFY_SERVICE=""

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
die()     { error "$*"; exit 1; }
header()  { echo -e "\n${BOLD}── $* ──${RESET}"; }

# ── Sanity checks ─────────────────────────────────────────────────────────────
require_root() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root (use sudo)."
}

resolve_invoking_user() {
    INVOKING_USER="${SUDO_USER:-${USER:-}}"
    if [[ -z "${INVOKING_USER}" || "${INVOKING_USER}" == "root" ]]; then
        warn "Could not determine a non-root invoking user."
        warn "The notification service will NOT be installed."
        warn "Re-run as a regular user with sudo if you want notifications."
        INVOKING_USER=""
    else
        INVOKING_HOME=$(getent passwd "${INVOKING_USER}" | cut -d: -f6)
        USER_SYSTEMD_DIR="${INVOKING_HOME}/.config/systemd/user"
        USER_NOTIFY_SERVICE="${USER_SYSTEMD_DIR}/atomic-update-notify.service"
        info "Invoking user: ${INVOKING_USER} (home: ${INVOKING_HOME})"
    fi
}

check_prerequisites() {
    header "Checking prerequisites"

    [[ -f /etc/os-release ]] || die "Cannot detect OS — /etc/os-release not found."
    # shellcheck source=/dev/null
    source /etc/os-release
    if [[ "${ID:-}" != "opensuse-tumbleweed" && \
          "${ID:-}" != "opensuse-slowroll"   && \
          "${ID_LIKE:-}" != *"suse"* ]]; then
        warn "System does not appear to be openSUSE (ID=${ID:-unknown})."
        read -rp "Continue anyway? [y/N] " yn
        [[ "${yn,,}" == "y" ]] || exit 1
    else
        success "openSUSE detected: ${PRETTY_NAME}"
    fi

    local rootfs_type
    rootfs_type=$(findmnt -no FSTYPE /) || true
    [[ "${rootfs_type}" == "btrfs" ]] || \
        die "Root filesystem is '${rootfs_type}', not btrfs. atomic-update requires btrfs."
    success "Root filesystem is btrfs"

    command -v snapper &>/dev/null || \
        die "'snapper' not found. Install it: sudo zypper install snapper"
    success "snapper is installed"

    local snap_cfg
    snap_cfg=$(snapper --jsonout list-configs 2>/dev/null | \
               python3 -c "
import sys, json
cfgs = json.load(sys.stdin)['configs']
[print(c['config']) for c in cfgs if c['subvolume'] == '/']
" 2>/dev/null || true)
    [[ -n "${snap_cfg}" ]] || \
        die "No snapper config for '/'. Run: sudo snapper -c root create-config /"
    success "Snapper root config found: '${snap_cfg}'"

    command -v systemctl &>/dev/null || die "systemctl not found — systemd required."
    success "systemd is available"

    command -v python3 &>/dev/null || \
        die "python3 not found. Install it: sudo zypper install python3"
    success "python3 is available"

    # notify-send is required for desktop notifications
    if ! command -v notify-send &>/dev/null; then
        warn "notify-send not found — required for desktop notifications."
        read -rp "Install libnotify-tools now? [Y/n] " yn
        if [[ "${yn,,}" != "n" ]]; then
            info "Installing libnotify-tools..."
            zypper install -y libnotify-tools || \
                die "Failed to install libnotify-tools. Install manually: sudo zypper install libnotify-tools"
            success "libnotify-tools installed"
        else
            warn "Skipping libnotify-tools — desktop notifications will not work until it is installed."
            warn "Install manually later: sudo zypper install libnotify-tools"
        fi
    else
        success "notify-send is available"
    fi

    # Detect desktop environment and note any known behavioural differences
    local de="${XDG_CURRENT_DESKTOP:-unknown}"
    info "Desktop environment: ${de}"
    if echo "${de}" | grep -qi "gnome"; then
        info "GNOME detected — notifications will work but --expire-time is ignored;"
        info "persistent notifications are managed by GNOME's notification centre instead."
    fi

    # ── How this works — plain language notice ────────────────────────────────
    echo ""
    echo -e "  ${BOLD}Before we continue — how this works${RESET}"
    echo ""
    echo "  This tool runs 'atomic-update' automatically each time you shut"
    echo "  down or reboot (depending on your preference). Here is what that"
    echo "  means in practice:"
    echo ""
    echo "  • When updates are available, a new btrfs snapshot of your system"
    echo "    is created, the updates are applied inside it, and it becomes"
    echo "    the default on next boot. Your running system is not touched."
    echo ""
    echo "  • If the update is interrupted or fails for any reason, the"
    echo "    snapshot is discarded. Your system boots from the previous"
    echo "    snapshot unchanged, as if nothing happened."
    echo ""
    echo "  • To undo an update: reboot, select the previous snapshot from the"
    echo "    bootloader menu, then run: sudo atomic-update rollback"
    echo "    This makes that snapshot the permanent default. Running rollback"
    echo "    from the already-updated system has no effect. Your personal"
    echo "    files in /home are never affected by snapshots or rollbacks."
    echo ""
    echo "  • Shutdown and reboot will take longer when updates are available,"
    echo "    typically 1–5 minutes depending on how many packages are pending."
    echo "    This is normal — the system is updating before it powers off."
    echo ""
    echo "  • During shutdown or reboot, you will see atomic-update's output"
    echo "    directly on screen — package names, progress, and a final result"
    echo "    line. This is normal. The full log is also kept at:"
    echo "    sudo cat /var/log/atomic-update-trigger.log"
    echo ""
    echo -e "  ${YELLOW}${BOLD}One technical note:${RESET}"
    echo "  Reboot detection relies on reading systemd's internal job queue at"
    echo "  the moment of shutdown. This has been tested and works reliably,"
    echo "  but it is not an officially documented systemd guarantee. It is"
    echo "  mentioned here so you are aware, not because it is likely to cause"
    echo "  problems in normal use."
    echo ""
    read -rp "  Understood — continue with installation? [Y/n] " understood
    [[ "${understood,,}" == "n" ]] && exit 0
    echo ""
}

# ── 1. atomic-update binary ───────────────────────────────────────────────────
install_atomic_update() {
    header "Installing atomic-update"

    if [[ -f "${ATOMIC_UPDATE_BIN}" ]]; then
        local ver
        ver=$(python3 "${ATOMIC_UPDATE_BIN}" --version 2>/dev/null || echo "unknown")
        info "atomic-update already installed: ${ver}"
        read -rp "Re-download latest version from GitHub? [y/N] " yn
        if [[ "${yn,,}" != "y" ]]; then
            success "Keeping existing atomic-update"
            return
        fi
    fi

    info "Downloading atomic-update from GitHub..."
    if command -v curl &>/dev/null; then
        curl -fsSL \
            "https://raw.githubusercontent.com/pavinjosdev/atomic-update/main/atomic-update" \
            -o "${ATOMIC_UPDATE_BIN}"
    elif command -v wget &>/dev/null; then
        wget -qO "${ATOMIC_UPDATE_BIN}" \
            "https://raw.githubusercontent.com/pavinjosdev/atomic-update/main/atomic-update"
    else
        die "Neither curl nor wget found. Cannot download atomic-update."
    fi

    chmod 755 "${ATOMIC_UPDATE_BIN}"
    local ver
    ver=$(python3 "${ATOMIC_UPDATE_BIN}" --version 2>/dev/null || echo "unknown")
    success "atomic-update installed: ${ver}"
}

# ── 2. Config file ────────────────────────────────────────────────────────────
install_config() {
    header "Installing configuration file"

    # If config exists, merge in any keys that are missing rather than
    # overwriting (preserves user settings) or silently skipping (which
    # caused new options to be absent after reinstall).
    if [[ -f "${CONF_FILE}" ]]; then
        info "Config already exists — checking for missing keys..."
        local updated=0

        if ! grep -q "^UPDATE_ON=" "${CONF_FILE}"; then
            echo "" >> "${CONF_FILE}"
            cat >> "${CONF_FILE}" << 'MERGE_EOF'
# ── Update trigger ────────────────────────────────────────────────────────────
# poweroff — run on shutdown/halt only, skip on reboot  (default)
# reboot   — run on reboot only, skip on shutdown/halt
# both     — run on both shutdown and reboot
# none     — never run (disables updates without removing the service)
UPDATE_ON="poweroff"
MERGE_EOF
            warn "Added missing key: UPDATE_ON=poweroff"
            updated=1
        fi

        if ! grep -q "^VERBOSE_SHUTDOWN=" "${CONF_FILE}"; then
            echo "" >> "${CONF_FILE}"
            cat >> "${CONF_FILE}" << 'MERGE_EOF'
# ── Output verbosity ──────────────────────────────────────────────────────────
# yes: full output shown on TTY; no: only result line shown on TTY
VERBOSE_SHUTDOWN="yes"
MERGE_EOF
            warn "Added missing key: VERBOSE_SHUTDOWN=yes"
            updated=1
        fi

        if ! grep -q "^NOTIFY_ON_SUCCESS=" "${CONF_FILE}"; then
            echo "" >> "${CONF_FILE}"
            cat >> "${CONF_FILE}" << 'MERGE_EOF'
# ── Desktop notifications ─────────────────────────────────────────────────────
# NOTIFY_ON_SUCCESS: notify after login when update was applied successfully.
NOTIFY_ON_SUCCESS="no"
MERGE_EOF
            warn "Added missing key: NOTIFY_ON_SUCCESS=no"
            updated=1
        fi

        if ! grep -q "^NOTIFY_ON_PROBLEM=" "${CONF_FILE}"; then
            echo "" >> "${CONF_FILE}"
            cat >> "${CONF_FILE}" << 'MERGE_EOF'
# NOTIFY_ON_PROBLEM: notify after login when update was skipped or failed.
NOTIFY_ON_PROBLEM="yes"
MERGE_EOF
            warn "Added missing key: NOTIFY_ON_PROBLEM=yes"
            updated=1
        fi

        if [[ ${updated} -eq 0 ]]; then
            success "Config is up to date — no missing keys"
        else
            success "Config merged: existing values preserved, missing keys added"
        fi
        return
    fi

    echo ""
    echo -e "  ${BOLD}Configure runtime options${RESET}"
    echo "  (These can be changed at any time by editing ${CONF_FILE})"
    echo ""
    echo "  Recommended defaults:"
    echo ""
    echo "    UPDATE_ON=poweroff   — run updates on shutdown only, skip on reboot"
    echo "    NOTIFY_ON_SUCCESS=no — no notification on success (expected outcome)"
    echo "    NOTIFY_ON_PROBLEM=yes— notify on skip or failure (needs attention)"
    echo ""
    read -rp "  Use these defaults? [Y/n] " use_defaults

    local update_on="poweroff"
    local notify_success="no"
    local notify_problem="yes"

    if [[ "${use_defaults,,}" == "n" ]]; then
        # Update trigger
        echo ""
        echo "  When to run updates:"
        echo "    1) poweroff only  — update on shutdown, skip on reboot  [default]"
        echo "    2) both           — update on shutdown and reboot"
        echo "    3) reboot only    — update on reboot, skip on shutdown"
        echo "    4) none           — disable updates without removing the service"
        echo ""
        read -rp "  Choose 1/2/3/4 [1]: " update_on_choice
        case "${update_on_choice}" in
            2) update_on="both"    ;;
            3) update_on="reboot"  ;;
            4) update_on="none"    ;;
            *) update_on="poweroff" ;;
        esac

        # Notify on success
        echo ""
        echo "  Notify on SUCCESS: show a desktop notification after login when"
        echo "  an update was applied successfully."
        echo ""
        read -rp "  Notify on successful updates? [y/N] " nsyn
        [[ "${nsyn,,}" == "y" ]] && notify_success="yes"

        # Notify on skip/failure
        echo ""
        echo "  Notify on SKIPPED/FAILED: show a desktop notification after login"
        echo "  when an update was skipped (conflicts) or failed unexpectedly."
        echo ""
        read -rp "  Notify on skipped or failed updates? [Y/n] " npyn
        [[ "${npyn,,}" == "n" ]] && notify_problem="no"
    fi

    cat > "${CONF_FILE}" << CONF_EOF
# /etc/atomic-update.conf
# Runtime configuration for atomic-update trigger.
# Changes take effect immediately — no reinstall or service restart needed.

# ── Update trigger ────────────────────────────────────────────────────────────
# Controls when atomic-update runs during the system shutdown/reboot sequence.
# poweroff — run on shutdown/halt only, skip on reboot  (default)
# reboot   — run on reboot only, skip on shutdown/halt
# both     — run on both shutdown and reboot
# none     — never run (disables updates without removing the service)
UPDATE_ON="${update_on}"

# ── Output verbosity ──────────────────────────────────────────────────────────
# During shutdown/reboot, atomic-update's full output is shown on the TTY.
# Set to "no" to suppress TTY output (output is always written to the log).
# Note: suppressing output may result in a blank screen during long updates.
# This setting is intended for advanced users — the default "yes" is recommended.
VERBOSE_SHUTDOWN="yes"

# ── Desktop notifications ─────────────────────────────────────────────────────
# NOTIFY_ON_SUCCESS: show a desktop notification after login when the last
# update was applied successfully.
NOTIFY_ON_SUCCESS="${notify_success}"

# NOTIFY_ON_PROBLEM: show a desktop notification after login when the last
# update was skipped (package conflicts) or failed unexpectedly.
NOTIFY_ON_PROBLEM="${notify_problem}"
CONF_EOF

    chmod 644 "${CONF_FILE}"
    success "Config file written: ${CONF_FILE}"
    info "UPDATE_ON=${update_on}"
    info "VERBOSE_SHUTDOWN=yes (default — see ${CONF_FILE} to change)"
    info "NOTIFY_ON_SUCCESS=${notify_success}"
    info "NOTIFY_ON_PROBLEM=${notify_problem}"
}

# ── 3. Snapper no-dbus shim ───────────────────────────────────────────────────
install_snapper_shim() {
    header "Installing snapper no-dbus shim"

    cat > "${SNAPPER_SHIM}" << 'SHIM_EOF'
#!/usr/bin/env bash
# /usr/local/sbin/snapper-nodbus-shim
# Transparently injects --no-dbus into snapper calls made from the
# atomic-update shutdown context (detected via ATOMIC_UPDATE_SHUTDOWN=1).
# All other invocations pass straight through to the real snapper binary.
# D-Bus is unavailable during late shutdown, so --no-dbus is required for
# snapper to read configs directly from /etc/snapper/configs/ instead.
if [[ "${ATOMIC_UPDATE_SHUTDOWN:-}" == "1" ]]; then
    exec /usr/bin/snapper --no-dbus "$@"
else
    exec /usr/bin/snapper "$@"
fi
SHIM_EOF

    chmod 755 "${SNAPPER_SHIM}"
    success "Snapper no-dbus shim installed"
}

# ── 4. Trigger script ────────────────────────────────────────────────────────
install_trigger() {
    header "Installing trigger script"

    cat > "${TRIGGER_SCRIPT}" << 'TRIGGER_EOF'
#!/usr/bin/env bash
# /usr/local/sbin/atomic-update-trigger
# Runs atomic-update dup during the system shutdown/reboot sequence.
#
# Reads /etc/atomic-update.conf for runtime settings:
#   VERBOSE_SHUTDOWN — yes: show full output on TTY; no: log only
#
# D-Bus is unavailable during late shutdown. The snapper no-dbus shim is
# injected via PATH so atomic-update's internal snapper calls work without
# D-Bus by reading configs directly from /etc/snapper/configs/.

CONF_FILE="/etc/atomic-update.conf"
LOG_FILE="/var/log/atomic-update-trigger.log"
ATOMIC_UPDATE="/usr/bin/atomic-update"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Load config — safe defaults if file is missing
VERBOSE_SHUTDOWN="yes"
UPDATE_ON="poweroff"
[[ -f "${CONF_FILE}" ]] && source "${CONF_FILE}"

touch "${LOG_FILE}" 2>/dev/null || true
chmod 644 "${LOG_FILE}" 2>/dev/null || true

log() { echo "$*" | tee -a "${LOG_FILE}"; }

log ""
log "======================================================================"
log "[${TIMESTAMP}] atomic-update-trigger fired"
log "[config] VERBOSE_SHUTDOWN=${VERBOSE_SHUTDOWN} UPDATE_ON=${UPDATE_ON}"
log "======================================================================"

# Bail immediately if updates are disabled entirely
if [[ "${UPDATE_ON}" == "none" ]]; then
    log "[${TIMESTAMP}] Updates disabled (UPDATE_ON=none) — skipping"
    log "----------------------------------------------------------------------"
    exit 0
fi

# Determine shutdown type by inspecting the active systemd job queue.
# During a reboot, reboot.target appears with job type "start".
# During a poweroff/halt, poweroff.target or halt.target appears instead.
# Filtering on "start" avoids matching unrelated stop jobs for the same targets.
ACTIVE_JOBS=$(systemctl list-jobs --no-legend 2>/dev/null)
if echo "${ACTIVE_JOBS}" | grep -qE 'reboot\.target.*start'; then
    IS_REBOOT=1
else
    IS_REBOOT=0
fi

# Apply UPDATE_ON policy
if [[ ${IS_REBOOT} -eq 1 && "${UPDATE_ON}" == "poweroff" ]]; then
    log "[${TIMESTAMP}] Reboot detected and UPDATE_ON=poweroff — skipping"
    log "----------------------------------------------------------------------"
    exit 0
elif [[ ${IS_REBOOT} -eq 0 && "${UPDATE_ON}" == "reboot" ]]; then
    log "[${TIMESTAMP}] Poweroff detected and UPDATE_ON=reboot — skipping"
    log "----------------------------------------------------------------------"
    exit 0
fi

# Prepend the snapper shim directory to PATH so atomic-update finds the
# shim instead of the real snapper binary.
SHIM_DIR=$(mktemp -d)
RUN_LOG=$(mktemp)
ln -s /usr/local/sbin/snapper-nodbus-shim "${SHIM_DIR}/snapper"
export PATH="${SHIM_DIR}:${PATH}"
export ATOMIC_UPDATE_SHUTDOWN=1

# Tee output to both the persistent log and a per-run temp file.
# The temp file lets us check only this run's output when distinguishing
# "nothing to do" from a real update, avoiding false matches from prior runs.
if [[ "${VERBOSE_SHUTDOWN}" == "yes" ]]; then
    "${ATOMIC_UPDATE}" dup 2>&1 | tee -a "${LOG_FILE}" "${RUN_LOG}"
    EXIT_CODE=${PIPESTATUS[0]}
else
    # Non-verbose: suppress TTY output; full output still goes to the log.
    "${ATOMIC_UPDATE}" dup 2>&1 | tee -a "${LOG_FILE}" > "${RUN_LOG}"
    EXIT_CODE=${PIPESTATUS[0]}
fi

rm -rf "${SHIM_DIR}"

log ""
if [[ ${EXIT_CODE} -eq 0 ]]; then
    if grep -q "Nothing to do" "${RUN_LOG}"; then
        log "[${TIMESTAMP}] Result: NOTHING TO DO — system already up to date"
    else
        log "[${TIMESTAMP}] Result: SUCCESS — new snapshot set as default"
    fi
elif [[ ${EXIT_CODE} -eq 9 ]]; then
    log "[${TIMESTAMP}] Result: SKIPPED — conflicts detected or nothing to do"
else
    log "[${TIMESTAMP}] Result: FAILED — exit code ${EXIT_CODE}"
fi
log "----------------------------------------------------------------------"

rm -f "${RUN_LOG}"

exit 0
TRIGGER_EOF

    chmod 755 "${TRIGGER_SCRIPT}"
    success "Trigger script installed: ${TRIGGER_SCRIPT}"
}

# ── 5. Systemd system service ─────────────────────────────────────────────────
install_trigger_service() {
    header "Installing systemd service"

    cat > "${SYSTEMD_SYSTEM_SERVICE}" << 'SERVICE_EOF'
# /etc/systemd/system/atomic-update-trigger.service
# Runs atomic-update dup during the system shutdown/reboot sequence.
#
# Pattern: RemainAfterExit=yes with a trivial ExecStart keeps the service
# in "active (exited)" state after boot. When systemd tears down
# multi-user.target on shutdown it stops this service, triggering
# ExecStop — where the real work happens.

[Unit]
Description=Atomic distribution update on shutdown
Documentation=https://github.com/pavinjosdev/atomic-update
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes

# Runs at boot: pre-creates the log file and marks the service active so
# ExecStop fires on shutdown/reboot.
ExecStart=/bin/bash -c '\
    touch /var/log/atomic-update-trigger.log && \
    chmod 644 /var/log/atomic-update-trigger.log'

# Runs at shutdown: the actual update
ExecStop=/usr/local/sbin/atomic-update-trigger

TimeoutStopSec=600
User=root
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
SERVICE_EOF

    systemctl daemon-reload
    systemctl enable atomic-update-trigger.service
    # Start immediately so ExecStop fires on the very next shutdown
    systemctl start atomic-update-trigger.service
    success "Trigger service installed, enabled, and started"
}

# ── 6. Logrotate ──────────────────────────────────────────────────────────────
install_logrotate() {
    header "Installing logrotate configuration"

    cat > "${LOGROTATE_CONF}" << 'LOGROTATE_EOF'
/var/log/atomic-update-trigger.log {
    monthly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    create 0644 root root
}
LOGROTATE_EOF

    touch "${LOG_FILE}"
    chmod 644 "${LOG_FILE}"
    chown root:root "${LOG_FILE}"

    success "Logrotate config installed"
    success "Log file: ${LOG_FILE}"
}

# ── 7. Plymouth shutdown masking ──────────────────────────────────────────────
disable_plymouth_shutdown() {
    header "Configuring Plymouth"

    local masked=0
    for svc in plymouth-halt.service plymouth-poweroff.service; do
        if systemctl cat "${svc}" &>/dev/null 2>&1; then
            systemctl mask "${svc}" 2>/dev/null && \
                { success "Masked ${svc}"; masked=1; } || \
                warn "Could not mask ${svc}"
        fi
    done

    if [[ ${masked} -eq 1 ]]; then
        info "Plymouth boot splash untouched; shutdown splash masked for TTY visibility."
    else
        info "No Plymouth shutdown services found — skipping."
    fi
}

# ── 8. Notification script ────────────────────────────────────────────────
install_notify_script() {
    header "Installing notification script"

    cat > "${NOTIFY_SCRIPT}" << 'NOTIFY_EOF'
#!/usr/bin/env bash
# /usr/local/sbin/atomic-update-notify
# Reads the last result from the atomic-update log and fires a desktop
# notification according to /etc/atomic-update.conf.
# Runs as the logged-in user via a systemd user service at login.
# Compatible with any DE that implements the freedesktop notification spec
# (KDE Plasma, GNOME, XFCE, etc.). Note: GNOME ignores --expire-time,
# managing notification persistence through its own notification centre.

CONF_FILE="/etc/atomic-update.conf"
LOG_FILE="/var/log/atomic-update-trigger.log"

# Systemd user services run with a minimal PATH that often excludes /usr/bin.
# Ensure standard binary directories are present.
export PATH="/usr/local/bin:/usr/bin:/bin:${PATH}"

# Locate notify-send explicitly — fail early with a clear message if missing
NOTIFY_SEND=$(command -v notify-send 2>/dev/null) || {
    echo "atomic-update-notify: notify-send not found in PATH (${PATH})" >&2
    exit 1
}

# Load config — safe defaults if file is missing
NOTIFY_ON_SUCCESS="no"
NOTIFY_ON_PROBLEM="yes"
[[ -f "${CONF_FILE}" ]] && source "${CONF_FILE}"

# Nothing to do if both notification types are disabled
if [[ "${NOTIFY_ON_SUCCESS}" != "yes" && "${NOTIFY_ON_PROBLEM}" != "yes" ]]; then
    exit 0
fi

# Log not yet created — nothing to report
[[ -f "${LOG_FILE}" ]] || exit 0

# Find the last Result: line
LAST_RESULT=$(grep "^\[.*\] Result:" "${LOG_FILE}" | tail -1)
[[ -z "${LAST_RESULT}" ]] && exit 0

# Determine result type and whether to notify
if echo "${LAST_RESULT}" | grep -q "Result: SUCCESS"; then
    [[ "${NOTIFY_ON_SUCCESS}" != "yes" ]] && exit 0
    SUMMARY="Atomic update successful"
    BODY="The update was applied successfully.\nA new snapshot is now active.\n\nLog: sudo cat ${LOG_FILE}"
    URGENCY="low"
    ICON="system-software-update"

elif echo "${LAST_RESULT}" | grep -q "NOTHING TO DO"; then
    # System was already up to date — not a problem, not a real update,
    # so we stay silent regardless of notification settings
    exit 0

elif echo "${LAST_RESULT}" | grep -q "SKIPPED"; then
    [[ "${NOTIFY_ON_PROBLEM}" != "yes" ]] && exit 0
    SUMMARY="Atomic update skipped — package conflicts"
    BODY="The update was skipped due to package conflicts.\n\nCheck the log:\nsudo cat ${LOG_FILE}\n\nOr run a dry-run:\nsudo zypper --non-interactive dist-upgrade --dry-run"
    URGENCY="normal"
    ICON="dialog-warning"

elif echo "${LAST_RESULT}" | grep -q "FAILED"; then
    [[ "${NOTIFY_ON_PROBLEM}" != "yes" ]] && exit 0
    SUMMARY="Atomic update failed"
    BODY="The update failed unexpectedly.\n\nCheck the log:\nsudo cat ${LOG_FILE}"
    URGENCY="critical"
    ICON="dialog-error"

else
    [[ "${NOTIFY_ON_PROBLEM}" != "yes" ]] && exit 0
    SUMMARY="Atomic update: unknown result"
    BODY="Could not determine last update status.\n\nCheck the log:\nsudo cat ${LOG_FILE}"
    URGENCY="normal"
    ICON="dialog-information"
fi

"${NOTIFY_SEND}" \
    --app-name="atomic-update" \
    --urgency="${URGENCY}" \
    --icon="${ICON}" \
    --expire-time=0 \
    "${SUMMARY}" \
    "${BODY}"
NOTIFY_EOF

    chmod 755 "${NOTIFY_SCRIPT}"
    success "Notification script installed: ${NOTIFY_SCRIPT}"
}

# ── 9. Systemd user service for notifications ─────────────────────────────────
install_user_service() {
    header "Installing notification user service"

    if [[ -z "${INVOKING_USER}" ]]; then
        warn "Skipping user service — no non-root user detected."
        return
    fi

    mkdir -p "${USER_SYSTEMD_DIR}"

    cat > "${USER_NOTIFY_SERVICE}" << 'USER_SERVICE_EOF'
# ~/.config/systemd/user/atomic-update-notify.service
# Fires a desktop notification after login per /etc/atomic-update.conf.
# Uses graphical-session.target which is registered by KDE, GNOME, and most
# other DEs. On lightweight DEs that don't register with this target the
# service may fire before the notification daemon is ready — increasing the
# sleep value below can help in that case.

[Unit]
Description=Notify user of atomic-update result
After=graphical-session.target

[Service]
Type=oneshot
# Allow time for the notification daemon to be fully listening.
# Increase this value if notifications don't appear on your desktop environment.
ExecStartPre=/bin/sleep 10
ExecStart=/usr/local/sbin/atomic-update-notify

[Install]
WantedBy=graphical-session.target
USER_SERVICE_EOF

    chown "${INVOKING_USER}:${INVOKING_USER}" "${USER_NOTIFY_SERVICE}"

    sudo -u "${INVOKING_USER}" \
        XDG_RUNTIME_DIR="/run/user/$(id -u "${INVOKING_USER}")" \
        systemctl --user daemon-reload
    sudo -u "${INVOKING_USER}" \
        XDG_RUNTIME_DIR="/run/user/$(id -u "${INVOKING_USER}")" \
        systemctl --user enable atomic-update-notify.service

    success "User notification service installed and enabled for '${INVOKING_USER}'"
}

# ── Verify ────────────────────────────────────────────────────────────────────
verify_install() {
    header "Verifying installation"

    if systemctl is-enabled atomic-update-trigger.service &>/dev/null; then
        success "Trigger service is enabled"
    else
        warn "Trigger service does not appear enabled"
    fi

    local state
    state=$(systemctl show atomic-update-trigger.service \
            --property=ActiveState --value 2>/dev/null || echo "unknown")
    if [[ "${state}" == "active" ]]; then
        success "Trigger service is active (exited) — ExecStop will fire on next shutdown/reboot"
    else
        warn "Trigger service state is '${state}' — expected 'active'"
        warn "Run: sudo systemctl start atomic-update-trigger.service"
    fi

    if [[ -f "${CONF_FILE}" ]]; then
        success "Config file present: ${CONF_FILE}"
    else
        warn "Config file missing: ${CONF_FILE}"
    fi

    if [[ -n "${INVOKING_USER}" ]]; then
        local enabled
        enabled=$(sudo -u "${INVOKING_USER}" \
            XDG_RUNTIME_DIR="/run/user/$(id -u "${INVOKING_USER}")" \
            systemctl --user is-enabled atomic-update-notify.service 2>/dev/null \
            || echo "unknown")
        if [[ "${enabled}" == "enabled" ]]; then
            success "User notification service is enabled for '${INVOKING_USER}'"
        else
            warn "User notification service state: ${enabled}"
        fi
    fi
}

# ── Uninstall ─────────────────────────────────────────────────────────────────
uninstall() {
    header "Uninstalling atomic-update trigger"

    for action in disable stop; do
        systemctl ${action} atomic-update-trigger.service 2>/dev/null || true
    done
    success "Trigger service disabled and stopped"

    if [[ -n "${INVOKING_USER}" ]]; then
        local u_home u_uid u_service
        u_home=$(getent passwd "${INVOKING_USER}" | cut -d: -f6)
        u_uid=$(id -u "${INVOKING_USER}" 2>/dev/null || true)
        u_service="${u_home}/.config/systemd/user/atomic-update-notify.service"

        if [[ -f "${u_service}" ]]; then
            sudo -u "${INVOKING_USER}" \
                XDG_RUNTIME_DIR="/run/user/${u_uid}" \
                systemctl --user disable atomic-update-notify.service 2>/dev/null || true
            rm -f "${u_service}"
            sudo -u "${INVOKING_USER}" \
                XDG_RUNTIME_DIR="/run/user/${u_uid}" \
                systemctl --user daemon-reload 2>/dev/null || true
            success "User notification service removed for '${INVOKING_USER}'"
        fi
    fi

    for f in "${SYSTEMD_SYSTEM_SERVICE}" "${TRIGGER_SCRIPT}" "${SNAPPER_SHIM}" \
              "${NOTIFY_SCRIPT}" "${LOGROTATE_CONF}"; do
        if [[ -f "${f}" ]]; then
            rm -f "${f}"
            success "Removed: ${f}"
        fi
    done

    systemctl daemon-reload

    for svc in plymouth-halt.service plymouth-poweroff.service; do
        systemctl unmask "${svc}" 2>/dev/null && \
            success "Unmasked ${svc}" || true
    done

    # Config file — ask rather than silently removing or keeping
    if [[ -f "${CONF_FILE}" ]]; then
        echo ""
        info "Config file found: ${CONF_FILE}"
        info "Current settings:"
        grep -E "^[A-Z_]+=" "${CONF_FILE}" | sed 's/^/    /'
        echo ""
        read -rp "  Remove config file? Keeping it preserves your settings if you reinstall. [y/N] " rmconf
        if [[ "${rmconf,,}" == "y" ]]; then
            rm -f "${CONF_FILE}"
            success "Removed: ${CONF_FILE}"
        else
            info "Config kept at: ${CONF_FILE}"
        fi
    fi

    info "Log file kept at: ${LOG_FILE}  (remove manually if desired)"
    info "atomic-update binary kept at: ${ATOMIC_UPDATE_BIN}  (remove manually if desired)"
    echo ""
    success "Uninstall complete."
    exit 0
}

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary() {
    # Read current config values for display
    local VERBOSE_SHUTDOWN="yes" NOTIFY_ON_SUCCESS="no" NOTIFY_ON_PROBLEM="yes" UPDATE_ON="poweroff"
    [[ -f "${CONF_FILE}" ]] && source "${CONF_FILE}"

    echo ""
    echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════${RESET}"
    echo -e "${GREEN}${BOLD}  Installation complete!${RESET}"
    echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════${RESET}"
    echo ""
    echo -e "  ${BOLD}What happens from now on:${RESET}"
    echo "  • atomic-update dup runs according to UPDATE_ON setting"
    echo "  • Success  → new snapshot becomes active on next boot"
    echo "  • Conflict → snapshot discarded, nothing changes"
    echo "  • Failure  → snapshot discarded, nothing changes"
    echo ""
    echo -e "  ${BOLD}Current settings (${CONF_FILE}):${RESET}"
    echo "  • Run updates on      : ${UPDATE_ON}"
    echo "  • Notify on success   : ${NOTIFY_ON_SUCCESS}"
    echo "  • Notify on skip/fail : ${NOTIFY_ON_PROBLEM}"
    echo ""
    echo -e "  ${BOLD}To change any setting:${RESET}"
    echo "  • sudo nano ${CONF_FILE}"
    echo "  • No restart needed — settings are read at each shutdown/login"
    echo ""
    echo -e "  ${BOLD}Logs:${RESET}"
    echo "  • Persistent log : sudo cat ${LOG_FILE}"
    echo "  • Journal        : sudo journalctl -u atomic-update-trigger"
    echo ""
    echo -e "  ${BOLD}Useful commands:${RESET}"
    echo "  • Service status  : systemctl status atomic-update-trigger"
    echo "  • Disable updates : sudo systemctl disable atomic-update-trigger"
    echo "  • Re-enable       : sudo systemctl enable atomic-update-trigger"
    echo "  • Manual rollback : sudo atomic-update rollback"
    echo "  • Full uninstall  : sudo bash $0 --uninstall"
    echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    echo -e "${BOLD}"
    echo "  ╔════════════════════════════════════════════════════╗"
    echo "  ║   atomic-update trigger installer                  ║"
    echo "  ║   openSUSE Tumbleweed / Slowroll                   ║"
    echo "  ╚════════════════════════════════════════════════════╝"
    echo -e "${RESET}"

    require_root
    resolve_invoking_user

    if [[ "${1:-}" == "--uninstall" ]]; then
        uninstall
    fi

    # ── Phase 1: checks and user decisions ───────────────────────────────────
    check_prerequisites
    install_atomic_update
    install_config

    # ── Phase 2: installation ─────────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}  ────────────────────────────────────────────────────${RESET}"
    echo -e "${BOLD}  Installing...${RESET}"
    echo -e "${BOLD}  ────────────────────────────────────────────────────${RESET}"
    echo ""

    install_snapper_shim
    install_trigger
    install_trigger_service
    install_logrotate
    disable_plymouth_shutdown
    install_notify_script
    install_user_service

    # ── Phase 3: verify and summary ───────────────────────────────────────────
    echo ""
    echo -e "${BOLD}  ────────────────────────────────────────────────────${RESET}"
    echo -e "${BOLD}  Verifying...${RESET}"
    echo -e "${BOLD}  ────────────────────────────────────────────────────${RESET}"
    echo ""

    verify_install
    print_summary
}

main "$@"
