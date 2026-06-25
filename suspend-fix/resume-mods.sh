#!/bin/bash
# Reloads the mt7921e WiFi driver on resume from suspend and on cold boot.
#
# === Default behavior ===
# Reload the driver and wait for the wireless interface to appear. The
# wifi radio state, NetworkManager state, rfkill state, and saved
# connections are NOT touched. The user is responsible for manually
# enabling wifi and connecting to a network after a resume or boot.
#
# === Opt-in automatic re-association ===
# Create the marker file
#     /etc/mt7921e-fix/auto-connect
# to enable a more aggressive re-association sequence: enable wifi,
# unblock rfkill, perform up to 3 radio-toggle / rescan / wait cycles
# with longer waits, and finally try to bring up the most recently used
# saved network explicitly. This is best-effort; on hardware where the
# driver has a deeper firmware issue, manual intervention may still be
# required. To opt out, simply remove the marker file.
#
# Originally created by ChimeraOS; significantly extended to handle the
# "driver recognized, but won't auto-connect" symptom on Ayaneo / GPD
# handhelds running Bazzite (and similar Fedora Atomic desktops).
#
# Exit status: always 0 on best-effort completion. This script must never
# mark the calling systemd unit as failed: the driver reload alone is
# already a major improvement over a non-functional WiFi device.

set -u

LOG_TAG="mt7921e-fix"

log() {
    if command -v systemd-cat >/dev/null 2>&1; then
        printf '%s\n' "$*" | systemd-cat -t "$LOG_TAG" 2>/dev/null || true
    elif command -v logger >/dev/null 2>&1; then
        logger -t "$LOG_TAG" "$*" 2>/dev/null || true
    fi
}

device_state() {
    local dev="$1"
    nmcli -t -f DEVICE,STATE device status 2>/dev/null \
        | awk -F: -v d="$dev" '$1==d {print $2; exit}'
}

# ---------------------------------------------------------------------------
# 1. Reload the driver. Skip cleanly on hardware that doesn't have mt7921e.
#    This is the only step that runs on every invocation; everything below
#    is gated behind safety checks.
# ---------------------------------------------------------------------------
if ! modinfo -F filename mt7921e >/dev/null 2>&1; then
    exit 0
fi
log "reloading mt7921e driver"
if ! modprobe mt7921e; then
    log "modprobe mt7921e failed; continuing so the interface may still come up"
fi

# ---------------------------------------------------------------------------
# 2. Wait up to ~10s for a wireless interface to appear under /sys. The
#    interface name is whatever udev assigned; do not hard-code wlan0.
# ---------------------------------------------------------------------------
wait_for_wifi_iface() {
    local iface i
    for i in $(seq 1 20); do
        for iface in /sys/class/net/*/wireless; do
            [ -d "$iface" ] || continue
            basename "$(dirname "$iface")"
            return 0
        done
        sleep 0.5
    done
    return 1
}

WIFI_IFACE=$(wait_for_wifi_iface 2>/dev/null) || WIFI_IFACE=""
if [ -z "$WIFI_IFACE" ]; then
    log "no wireless interface appeared within ~10s; driver is loaded but wifi may not work"
    exit 0
fi
log "wireless interface: $WIFI_IFACE"

# ---------------------------------------------------------------------------
# 3. Default behavior: stop here. Do NOT touch the wifi radio state, do
#    NOT enable wifi, do NOT unblock rfkill, do NOT try to connect. The
#    user enables wifi manually when they need it.
# ---------------------------------------------------------------------------
if [ ! -e /etc/mt7921e-fix/auto-connect ]; then
    log "auto-connect not enabled; user must enable wifi manually"
    exit 0
fi

# ---------------------------------------------------------------------------
# 4. Opt-in aggressive re-association. The user has explicitly created
#    the marker file, indicating they want this script to take over the
#    re-association work.
# ---------------------------------------------------------------------------
log "auto-connect enabled; attempting re-association"

# 4a. Wait up to ~15s for NetworkManager to report a stable state. Early
#     in boot NM may still be initializing.
nm_wait_ready() {
    local i=0 state
    while [ "$i" -lt 30 ]; do
        state=$(nmcli -t -f STATE general status 2>/dev/null) || state=""
        case "$state" in
            connected|disconnected|asleep|connecting|connected-local)
                return 0
                ;;
        esac
        sleep 0.5
        i=$((i + 1))
    done
    return 1
}

if ! nm_wait_ready; then
    log "NetworkManager did not become ready within ~15s; user must connect manually"
    exit 0
fi

# 4b. The user opted in, so we are allowed to enable wifi and unblock the
#     radio. Without this, the radio toggle below would have no effect.
nmcli radio wifi on 2>/dev/null || true

if command -v rfkill >/dev/null 2>&1; then
    if rfkill list wifi 2>/dev/null | grep -q "Soft blocked: yes"; then
        log "wifi radio is soft-blocked; unblocking"
        rfkill unblock wifi 2>/dev/null || true
    fi
fi

# 4c. Multiple re-association attempts. One radio toggle is sometimes
#     not enough; the user has reported that 2-3 toggles with longer
#     waits between them is what reliably triggers autoconnect on this
#     hardware.
for attempt in 1 2 3; do
    log "re-association attempt $attempt of 3"
    nmcli radio wifi off 2>/dev/null || true
    sleep 2
    nmcli radio wifi on  2>/dev/null || true
    sleep 2
    nmcli device wifi rescan ifname "$WIFI_IFACE" 2>/dev/null || \
        nmcli device wifi rescan 2>/dev/null || true

    # Wait up to 8s for the interface to transition to connected.
    for wait in 1 2 3 4 5 6 7 8; do
        state=$(device_state "$WIFI_IFACE")
        if [ "$state" = "connected" ]; then
            log "wifi connected on attempt $attempt after ${wait}s"
            exit 0
        fi
        sleep 1
    done
done

# 4d. Last resort: explicit connection up. Covers connection profiles
#     with `autoconnect=false` and hidden SSIDs that scan-based
#     autoconnect cannot pick up.
saved=$(nmcli -t -f NAME,TYPE,TIMESTAMP connection show 2>/dev/null \
    | awk -F: '$2=="802-11-wireless" && $3!="" {print}' \
    | sort -t: -k3 -n -r \
    | head -n1 \
    | cut -d: -f1)

if [ -n "$saved" ]; then
    log "explicitly bringing up saved connection: $saved"
    nmcli connection up "$saved" ifname "$WIFI_IFACE" 2>/dev/null || \
        log "nmcli connection up $saved failed; user must connect manually"
else
    log "no saved wifi connection found; user must connect manually"
fi

exit 0
