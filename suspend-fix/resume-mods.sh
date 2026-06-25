#!/bin/bash
# Reloads the mt7921e WiFi driver on resume from suspend and on cold boot,
# and attempts to re-associate with a saved WiFi network. The re-association
# step is gated behind a series of safety checks so it never overrides the
# user's prior state:
#
#   - if NM is not installed or not ready, the script stops after modprobe
#   - if the user has WiFi disabled in the NM applet, the script does not
#     touch the radio or run any reconnection commands
#   - if the wifi interface is already connected, the script does not toggle
#     the radio (which would briefly drop the active connection)
#   - if any reconnection step fails, the script logs and continues
#
# Originally created by ChimeraOS; significantly extended to handle the
# "driver recognized, but won't auto-connect" symptom on Ayaneo / GPD
# handhelds running Bazzite (and similar Fedora Atomic desktops).
#
# Exit status: always 0 on best-effort completion. This script must never
# mark the calling systemd unit as failed: the driver reload alone is
# already a major improvement over a non-functional WiFi device, and any
# reconnect failure is recoverable from the user's network applet.

set -u

LOG_TAG="mt7921e-fix"

log() {
    # Prefer systemd-cat so the message lands in the journal under a stable
    # identifier; fall back to logger, then to stderr as a last resort.
    if command -v systemd-cat >/dev/null 2>&1; then
        printf '%s\n' "$*" | systemd-cat -t "$LOG_TAG" 2>/dev/null || true
    elif command -v logger >/dev/null 2>&1; then
        logger -t "$LOG_TAG" "$*" 2>/dev/null || true
    else
        printf '[%s] %s\n' "$LOG_TAG" "$*" >&2
    fi
}

# Read the connection state of a specific device, or empty string if not
# present in nmcli's output. Centralized so we don't repeat the awk pattern.
device_state() {
    local dev="$1"
    nmcli -t -f DEVICE,STATE device status 2>/dev/null \
        | awk -F: -v d="$dev" '$1==d {print $2; exit}'
}

# ---------------------------------------------------------------------------
# 1. Reload the driver. Skip cleanly on hardware that doesn't have mt7921e
#    available (e.g., this script is shipped to a non-Ayaneo machine).
#    This is the only step that runs on every invocation; everything below
#    is gated behind safety checks.
# ---------------------------------------------------------------------------
if ! modinfo -F filename mt7921e >/dev/null 2>&1; then
    log "mt7921e module not present; nothing to do"
    exit 0
fi
log "reloading mt7921e driver"
if ! modprobe mt7921e; then
    log "modprobe mt7921e failed; continuing so we can still try to recover the radio state"
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
    log "no wireless interface appeared within ~10s after modprobe; driver is loaded, exiting"
    exit 0
fi
log "wireless interface: $WIFI_IFACE"

# ---------------------------------------------------------------------------
# 3. NetworkManager is the supported re-association path. If nmcli is not
#    present, we cannot help further; the driver is loaded and the user
#    will have to connect by hand.
# ---------------------------------------------------------------------------
if ! command -v nmcli >/dev/null 2>&1; then
    log "nmcli not found; driver reloaded, re-association not attempted"
    exit 0
fi

# Wait up to ~15s for NetworkManager to report a stable state. On early
# boot NM may still be initializing; on resume it is normally already up.
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
    log "NetworkManager did not become ready within ~15s; driver is loaded, exiting"
    exit 0
fi

# ---------------------------------------------------------------------------
# 4. Respect the user's prior WiFi state. If the user has WiFi disabled in
#    the NM applet, do NOT touch the radio, do NOT unblock rfkill, do NOT
#    try to connect. This preserves the original "just reload the driver"
#    behavior for users who have explicitly disabled WiFi.
# ---------------------------------------------------------------------------
wifi_intent=$(nmcli -t -f WIFI general status 2>/dev/null)
if [ "$wifi_intent" != "enabled" ]; then
    log "user has WiFi $wifi_intent in NetworkManager; not touching the radio"
    exit 0
fi

# ---------------------------------------------------------------------------
# 5. If the wifi interface is already connected (or connecting), preserve
#    the user's connection. The original behavior was to leave the running
#    connection alone; the radio toggle below would briefly drop it.
# ---------------------------------------------------------------------------
state=$(device_state "$WIFI_IFACE")
case "$state" in
    connected|connecting)
        log "wifi is already $state on $WIFI_IFACE; preserving connection"
        exit 0
        ;;
esac

# ---------------------------------------------------------------------------
# 6. We have permission to do re-association work. The interface is enabled
#    in the applet, and it is currently disconnected. From here on, any
#    failure is logged but does not stop the script.
# ---------------------------------------------------------------------------
log "wifi is disconnected on $WIFI_IFACE; attempting re-association"

# 6a. Unblock soft-blocked radios. Some laptop BIOSes / hotkeys leave the
#     wifi radio soft-blocked across suspend/resume or reboot; NM sees the
#     interface but cannot scan, so it appears "no networks available".
if command -v rfkill >/dev/null 2>&1; then
    if rfkill list wifi 2>/dev/null | grep -q "Soft blocked: yes"; then
        log "wifi radio is soft-blocked; unblocking"
        rfkill unblock wifi 2>/dev/null || true
    fi
fi

# 6b. Toggle the radio. This is the reliable workaround for the post-modprobe
#     "wifi radio up but won't auto-connect" symptom: NM's internal state
#     for the interface has not been reset, so autoconnect is gated behind
#     a radio-off / radio-on cycle.
log "re-initializing wifi radio on $WIFI_IFACE"
nmcli radio wifi off 2>/dev/null || true
sleep 1
nmcli radio wifi on  2>/dev/null || true
sleep 1

# 6c. Force a fresh scan. Some NM versions only re-evaluate autoconnect
#     after a successful scan, and the radio toggle alone can race with
#     the driver finishing its post-modprobe initialization (firmware load,
#     regulatory domain setup). The `ifname` option requires NM >= 1.0;
#     fall back to a blanket rescan if it is rejected.
if ! nmcli device wifi rescan ifname "$WIFI_IFACE" 2>/dev/null; then
    nmcli device wifi rescan 2>/dev/null || true
fi

# 6d. Safety net: if NM still reports the interface as disconnected a few
#     seconds later, explicitly bring up the most recently used saved wifi
#     connection. This covers two cases the radio toggle + rescan alone
#     does not:
#       (a) the connection profile has autoconnect disabled;
#       (b) the saved network is hidden (hidden SSIDs are not visible to
#           scan-based autoconnect and must be activated by name).
sleep 5
state=$(device_state "$WIFI_IFACE")
case "$state" in
    connected|connecting)
        log "wifi is now $state on $WIFI_IFACE; done"
        exit 0
        ;;
esac

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
