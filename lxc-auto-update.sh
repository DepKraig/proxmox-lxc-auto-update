#!/usr/bin/env bash
#
# lxc-auto-update.sh
# Weekly auto-updater for Proxmox LXC containers, with pre-update snapshots,
# post-update health checks, automatic rollback on failure, email alerts,
# and automatic OS/package-manager detection (Debian/Ubuntu, Alpine,
# RHEL-family, SUSE, Arch - unknown OSes are skipped and reported, never
# guessed at).
#
# Intended to run via cron on the Proxmox HOST (not inside a container).
#
# ---------------------------------------------------------------------------
# CONFIGURATION
#
# Defaults live here. Your real settings (email address, excluded CTIDs,
# etc.) belong in an external config file so you never have to edit this
# script directly or accidentally commit your own details if you fork/share
# this repo. By default that file is /etc/lxc-auto-update.conf - copy
# config.example.conf there and edit it. See README.md.
# ---------------------------------------------------------------------------

EMAIL_TO="root@localhost"
EMAIL_FROM="root@localhost"   # for Gmail relay, this must match the authenticated account

# CTIDs to skip entirely (space separated), e.g. containers you manage by hand
EXCLUDE_CTIDS=()

# How long (seconds) to wait for a container to come back up and respond
# after reboot before we consider it failed and roll back.
RESTART_TIMEOUT=120
RESTART_POLL_INTERVAL=5

# How many days to keep pre-update snapshots around before pruning old ones
SNAPSHOT_RETENTION_DAYS=14

# Snapshot name prefix (must be a valid Proxmox snapshot name - alnum/underscore)
SNAP_PREFIX="preupdate"

# Set to "1" to log what would happen without actually changing anything
DRY_RUN=0

LOG_DIR="/var/log/lxc-auto-update"

# ---------------------------------------------------------------------------
# Load external config, if present - overrides any of the defaults above.
# Set LXC_AUTO_UPDATE_CONFIG to point elsewhere if you want a different path.
# ---------------------------------------------------------------------------
CONFIG_FILE="${LXC_AUTO_UPDATE_CONFIG:-/etc/lxc-auto-update.conf}"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

LOG_FILE="$LOG_DIR/$(date +%Y%m%d-%H%M%S).log"

# ---------------------------------------------------------------------------
# Internals - shouldn't need to touch below this line
# ---------------------------------------------------------------------------

mkdir -p "$LOG_DIR"
: > "$LOG_FILE"

declare -a SUMMARY_LINES=()

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg" | tee -a "$LOG_FILE"
}

run() {
    # Wrapper that respects DRY_RUN
    if [[ "$DRY_RUN" == "1" ]]; then
        log "DRY-RUN: $*"
        return 0
    else
        "$@"
    fi
}

send_email() {
    local subject="$1"
    local body="$2"
    if ! command -v mail >/dev/null 2>&1; then
        log "WARNING: 'mail' command not found - cannot send email. Subject was: $subject"
        return 1
    fi
    echo -e "$body" | mail -s "$subject" -r "$EMAIL_FROM" "$EMAIL_TO"
}

is_excluded() {
    local ctid="$1"
    for x in "${EXCLUDE_CTIDS[@]}"; do
        [[ "$x" == "$ctid" ]] && return 0
    done
    return 1
}

get_container_name() {
    local ctid="$1"
    pct config "$ctid" 2>/dev/null | awk -F': ' '/^hostname:/{print $2}'
}

container_is_responsive() {
    # True if the container is running AND its init/OS actually answers exec calls
    local ctid="$1"
    local status
    status=$(pct status "$ctid" 2>/dev/null | awk '{print $2}')
    [[ "$status" != "running" ]] && return 1
    pct exec "$ctid" -- true >/dev/null 2>&1
}

wait_for_container() {
    local ctid="$1"
    local waited=0
    while (( waited < RESTART_TIMEOUT )); do
        if container_is_responsive "$ctid"; then
            return 0
        fi
        sleep "$RESTART_POLL_INTERVAL"
        waited=$(( waited + RESTART_POLL_INTERVAL ))
    done
    return 1
}

prune_old_snapshots() {
    local ctid="$1"
    local cutoff_epoch
    cutoff_epoch=$(date -d "-${SNAPSHOT_RETENTION_DAYS} days" +%s)

    while read -r snapname _rest; do
        [[ "$snapname" != ${SNAP_PREFIX}_* ]] && continue
        local datepart="${snapname#${SNAP_PREFIX}_}"
        local snap_epoch
        snap_epoch=$(date -d "${datepart:0:8}" +%s 2>/dev/null) || continue
        if (( snap_epoch < cutoff_epoch )); then
            log "  Pruning old snapshot $snapname on CT $ctid"
            run pct delsnapshot "$ctid" "$snapname" >>"$LOG_FILE" 2>&1
        fi
    done < <(pct listsnapshot "$ctid" 2>/dev/null | tail -n +2)
}

# ---------------------------------------------------------------------------
# OS DETECTION
#
# Detects the container's distro family by reading /etc/os-release inside it,
# with a package-manager binary check as a fallback. Returns one of:
#   debian | alpine | rhel | suse | arch | unknown
# ---------------------------------------------------------------------------
detect_os_family() {
    local ctid="$1"
    local os_release id id_like

    os_release=$(pct exec "$ctid" -- cat /etc/os-release 2>/dev/null)

    if [[ -n "$os_release" ]]; then
        id=$(echo "$os_release" | awk -F= '/^ID=/{gsub(/"/,"",$2); print tolower($2)}')
        id_like=$(echo "$os_release" | awk -F= '/^ID_LIKE=/{gsub(/"/,"",$2); print tolower($2)}')

        case "$id" in
            debian|ubuntu|raspbian|devuan|linuxmint)
                echo "debian"; return ;;
            alpine)
                echo "alpine"; return ;;
            rocky|almalinux|centos|rhel|fedora|amzn|ol)
                echo "rhel"; return ;;
            opensuse*|sles|suse)
                echo "suse"; return ;;
            arch|archarm|manjaro|endeavouros)
                echo "arch"; return ;;
        esac

        # Fall back to ID_LIKE if ID itself wasn't recognized
        case "$id_like" in
            *debian*)              echo "debian"; return ;;
            *rhel*|*fedora*)       echo "rhel"; return ;;
            *suse*)                echo "suse"; return ;;
            *arch*)                echo "arch"; return ;;
        esac
    fi

    # Last resort: probe for a known package manager binary directly
    if pct exec "$ctid" -- sh -c 'command -v apt-get' >/dev/null 2>&1; then
        echo "debian"; return
    elif pct exec "$ctid" -- sh -c 'command -v apk' >/dev/null 2>&1; then
        echo "alpine"; return
    elif pct exec "$ctid" -- sh -c 'command -v dnf || command -v yum' >/dev/null 2>&1; then
        echo "rhel"; return
    elif pct exec "$ctid" -- sh -c 'command -v zypper' >/dev/null 2>&1; then
        echo "suse"; return
    elif pct exec "$ctid" -- sh -c 'command -v pacman' >/dev/null 2>&1; then
        echo "arch"; return
    fi

    echo "unknown"
}

# Returns the update command (as a single string to be run via bash -c inside
# the container) for a given OS family. Empty string = unsupported.
get_update_command() {
    local family="$1"
    case "$family" in
        debian)
            echo 'export DEBIAN_FRONTEND=noninteractive; apt-get update -y && apt-get -y -o Dpkg::Options::="--force-confold" dist-upgrade && apt-get -y autoremove && apt-get -y autoclean'
            ;;
        alpine)
            echo 'apk update && apk upgrade --available'
            ;;
        rhel)
            echo 'if command -v dnf >/dev/null 2>&1; then dnf -y upgrade --refresh; else yum -y update; fi'
            ;;
        suse)
            echo 'zypper --non-interactive refresh && zypper --non-interactive update'
            ;;
        arch)
            echo 'pacman -Syu --noconfirm'
            ;;
        *)
            echo ""
            ;;
    esac
}

detect_shell() {
    # Returns "bash" if bash exists inside the container, otherwise "sh"
    # (used for minimal images - e.g. some Alpine templates - that only
    # ship a POSIX shell). All update commands in get_update_command()
    # are written to be POSIX-compatible so either works.
    local ctid="$1"
    if pct exec "$ctid" -- sh -c 'command -v bash' >/dev/null 2>&1; then
        echo "bash"
    else
        echo "sh"
    fi
}

process_container() {
    local ctid="$1"
    local name
    name=$(get_container_name "$ctid")
    [[ -z "$name" ]] && name="(unnamed)"

    log "=== Processing CT $ctid ($name) ==="

    local pre_status
    pre_status=$(pct status "$ctid" 2>/dev/null | awk '{print $2}')
    if [[ "$pre_status" != "running" ]]; then
        log "  CT $ctid is not running (status: $pre_status) - skipping."
        SUMMARY_LINES+=("CT $ctid ($name): SKIPPED - not running")
        return
    fi

    log "  Detecting OS..."
    local os_family
    os_family=$(detect_os_family "$ctid")
    log "  Detected OS family: $os_family"

    local update_cmd
    update_cmd=$(get_update_command "$os_family")

    if [[ -z "$update_cmd" ]]; then
        log "  WARNING: unrecognized/unsupported OS on CT $ctid - skipping update."
        SUMMARY_LINES+=("CT $ctid ($name): SKIPPED - unrecognized OS, add support manually")
        send_email "[Proxmox] CT $ctid ($name): unrecognized OS - not updated" \
            "CT $ctid ($name) has an OS this script doesn't recognize, so it was left untouched.\n\nLog into it and check /etc/os-release, then add a case for it in get_update_command() in the script.\n\nFull log: $LOG_FILE"
        return
    fi

    local snap_name="${SNAP_PREFIX}_$(date +%Y%m%d_%H%M%S)"
    log "  Creating snapshot '$snap_name'..."
    if ! run pct snapshot "$ctid" "$snap_name" -description "Auto snapshot before weekly update" >>"$LOG_FILE" 2>&1; then
        log "  ERROR: snapshot failed for CT $ctid - skipping update for safety."
        SUMMARY_LINES+=("CT $ctid ($name): FAILED - could not create pre-update snapshot")
        send_email "[Proxmox] CT $ctid ($name): snapshot failed, update skipped" \
            "Could not create a pre-update snapshot for CT $ctid ($name), so it was NOT updated.\n\nCheck storage space / snapshot support for this container's storage backend.\n\nSee $LOG_FILE for details."
        return
    fi

    local shell
    shell=$(detect_shell "$ctid")
    log "  Using shell: $shell"

    log "  Running package update ($os_family)..."
    local update_output update_exit
    update_output=$(run pct exec "$ctid" -- "$shell" -c "$update_cmd" 2>&1)
    update_exit=$?
    echo "$update_output" >> "$LOG_FILE"

    if [[ "$update_exit" -ne 0 ]]; then
        log "  ERROR: package update failed (exit $update_exit). Rolling back CT $ctid..."
        run pct rollback "$ctid" "$snap_name" >>"$LOG_FILE" 2>&1
        run pct start "$ctid" >>"$LOG_FILE" 2>&1
        SUMMARY_LINES+=("CT $ctid ($name): FAILED - update error, rolled back")
        send_email "[Proxmox] CT $ctid ($name): update FAILED - rolled back" \
            "Package update failed on CT $ctid ($name, OS: $os_family) and it was rolled back to the pre-update snapshot ($snap_name).\n\nLikely cause: a package manager error during the update (see output below) - could be a broken package, disk space, or a repo/network issue reachable from the container.\n\n--- update output (last portion) ---\n$(echo "$update_output" | tail -n 40)\n\nFull log: $LOG_FILE"
        return
    fi

    log "  Update succeeded. Rebooting CT $ctid to apply changes..."
    if ! run pct reboot "$ctid" >>"$LOG_FILE" 2>&1; then
        log "  ERROR: reboot command itself failed for CT $ctid."
        run pct rollback "$ctid" "$snap_name" >>"$LOG_FILE" 2>&1
        run pct start "$ctid" >>"$LOG_FILE" 2>&1
        SUMMARY_LINES+=("CT $ctid ($name): FAILED - reboot command failed, rolled back")
        send_email "[Proxmox] CT $ctid ($name): reboot FAILED - rolled back" \
            "CT $ctid ($name) updated successfully but the reboot command itself failed. Rolled back to snapshot $snap_name.\n\nFull log: $LOG_FILE"
        return
    fi

    log "  Waiting up to ${RESTART_TIMEOUT}s for CT $ctid to come back up..."
    if [[ "$DRY_RUN" != "1" ]] && ! wait_for_container "$ctid"; then
        log "  ERROR: CT $ctid did not come back up within ${RESTART_TIMEOUT}s. Rolling back..."
        run pct stop "$ctid" >>"$LOG_FILE" 2>&1
        run pct rollback "$ctid" "$snap_name" >>"$LOG_FILE" 2>&1
        run pct start "$ctid" >>"$LOG_FILE" 2>&1

        local recovered="no"
        if [[ "$DRY_RUN" != "1" ]] && wait_for_container "$ctid"; then
            recovered="yes"
        fi

        SUMMARY_LINES+=("CT $ctid ($name): FAILED - did not restart after update, rolled back (recovered after rollback: $recovered)")
        send_email "[Proxmox] CT $ctid ($name): FAILED TO RESTART - rolled back" \
            "CT $ctid ($name, OS: $os_family) updated but did not come back up (not responsive within ${RESTART_TIMEOUT}s of reboot).\n\nRolled back to pre-update snapshot ($snap_name). Container recovered after rollback: $recovered.\n\nPossible causes:\n- An updated package changed a config file the container's init/services depend on\n- A kernel/module or systemd-related package update needing more than a soft reboot\n- Network config changed inside the container during update\n- The update queued a process (e.g. needrestart) that hung boot\n\nRecommend logging into CT $ctid manually to inspect package manager logs and journalctl after re-attempting the update by hand.\n\nFull log: $LOG_FILE"
        return
    fi

    log "  CT $ctid is back up and responsive."
    SUMMARY_LINES+=("CT $ctid ($name, $os_family): OK - updated and restarted successfully")
    prune_old_snapshots "$ctid"
}

main() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log "WARNING: no config file found at $CONFIG_FILE - using built-in defaults (EMAIL_TO=$EMAIL_TO). See README.md to set one up."
    fi
    if [[ "$EMAIL_TO" == "root@localhost" ]]; then
        log "WARNING: EMAIL_TO is still the default placeholder - alerts will go nowhere useful until you configure it."
    fi

    log "Starting weekly LXC update run (DRY_RUN=$DRY_RUN)"

    local ctids
    ctids=$(pct list 2>/dev/null | tail -n +2 | awk '{print $1}')

    if [[ -z "$ctids" ]]; then
        log "No LXC containers found on this host. Exiting."
        exit 0
    fi

    for ctid in $ctids; do
        if is_excluded "$ctid"; then
            log "CT $ctid is in EXCLUDE_CTIDS - skipping."
            SUMMARY_LINES+=("CT $ctid: SKIPPED - excluded by config")
            continue
        fi
        process_container "$ctid"
    done

    log "Run complete."

    local summary_body
    summary_body="Weekly Proxmox LXC update run finished at $(date '+%Y-%m-%d %H:%M:%S').\n\n"
    for line in "${SUMMARY_LINES[@]}"; do
        summary_body+="- $line\n"
    done
    summary_body+="\nFull log: $LOG_FILE"

    send_email "[Proxmox] Weekly LXC update summary - $(date +%Y-%m-%d)" "$summary_body"
}

main "$@"
