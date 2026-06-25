#!/bin/bash
# Reloads the mt7921e WiFi driver on resume from suspend and on cold boot.
#
# === Design principle: no fixed sleeps between state transitions ===
# Every transition is verified by polling the actual state — never by
# sleeping for an assumed amount of time. `sleep 0.5` only appears inside
# polling loops as the polling interval. This eliminates the "race between
# driver, firmware, wpa_supplicant, and NM" that requires multiple manual
# radio toggles to overcome.
#
# === Default behavior ===
# Reload the driver, do a state-driven radio toggle (off → on, each
# transition verified by polling NM and the kernel), wait for the first
# scan to actually return results, and stop. The user picks a network
# by hand.
#
# === Opt-in automatic re-association ===
# Create the marker file
#     /etc/mt7921e-fix/auto-connect
# to additionally wait for the most recently used saved network to
# become visible in the scan and then bring it up. Best-effort; failures
# are logged so the user can investigate via the journal.
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

# ===========================================================================
# Helpers
# ===========================================================================
# Every helper in this section is a polling loop: it checks the actual
# state, sleeps a fixed polling interval (0.5s) ONLY between polls, and
# returns as soon as the desired state is observed or the timeout elapses.
# No helper assumes a transition has completed based on elapsed time.

# Poll the global wifi radio state until it matches the desired value.
# Args: <desired> <timeout-seconds>
# Returns 0 if the state was observed within the timeout, 1 otherwise.
wait_for_wifi_radio() {
    local desired="$1" timeout_s="$2"
    local i max state
    max=$((timeout_s * 2))   # 0.5s polling interval
    for i in $(seq 1 "$max"); do
        state=$(nmcli -t -f WIFI general status 2>/dev/null) || state=""
        if [ "$state" = "$desired" ]; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

# Poll a wireless device's NM state until it matches the desired value.
# Args: <iface> <desired> <timeout-seconds>
wait_for_device_state() {
    local iface="$1" desired="$2" timeout_s="$3"
    local i max state
    max=$((timeout_s * 2))
    for i in $(seq 1 "$max"); do
        state=$(nmcli -t -f DEVICE,STATE device status 2>/dev/null \
            | awk -F: -v d="$iface" '$1==d {print $2; exit}')
        if [ "$state" = "$desired" ]; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

# Poll the kernel's operstate for a wireless interface until it is "up".
# Args: <iface> <timeout-seconds>
wait_for_iface_operational() {
    local iface="$1" timeout_s="$2"
    local i max oper
    max=$((timeout_s * 2))
    for i in $(seq 1 "$max"); do
        if [ -e "/sys/class/net/$iface/operstate" ]; then
            oper=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null) || oper=""
            if [ "$oper" = "up" ]; then
                return 0
            fi
        fi
        sleep 0.5
    done
    return 1
}

# Poll the kernel's operstate for a wireless interface until it is NOT "up".
# This is what we need between `wifi off` and `wifi on` — we must wait
# until the driver has actually torn the interface down before re-initializing.
# Args: <iface> <timeout-seconds>
wait_for_iface_not_operational() {
    local iface="$1" timeout_s="$2"
    local i max oper
    max=$((timeout_s * 2))
    for i in $(seq 1 "$max"); do
        if [ ! -e "/sys/class/net/$iface/operstate" ]; then
            # Interface has been removed from the kernel; definitively not up.
            return 0
        fi
        oper=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null) || oper=""
        if [ "$oper" != "up" ]; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

# Poll NM's wifi scan until at least <min_count> networks are visible.
# Args: <iface> <min-count> <timeout-seconds>
wait_for_scan_results() {
    local iface="$1" min_count="$2" timeout_s="$3"
    local i max count
    max=$((timeout_s * 2))
    for i in $(seq 1 "$max"); do
        count=$(nmcli -t -f SSID device wifi list ifname "$iface" 2>/dev/null \
            | grep -v '^$' | wc -l | tr -d '[:space:]')
        count="${count:-0}"
        if [ "$count" -ge "$min_count" ]; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

# Poll NM's wifi scan until a specific SSID appears in the results.
# Args: <iface> <ssid> <timeout-seconds>
wait_for_ssid_visible() {
    local iface="$1" ssid="$2" timeout_s="$3"
    local i max
    max=$((timeout_s * 2))
    for i in $(seq 1 "$max"); do
        if nmcli -t -f SSID device wifi list ifname "$iface" 2>/dev/null \
            | grep -qFx "$ssid"; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

# Wait for NetworkManager to be reachable (initial startup of NM at boot).
# Once nmcli can talk to NM, we proceed.
wait_for_nm_reachable() {
    local i=0
    while [ "$i" -lt 20 ]; do   # ~10s
        if nmcli -t -f STATE general status >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.5
        i=$((i + 1))
    done
    return 1
}

# ===========================================================================
# 1. Reload the driver. Skip cleanly on hardware that doesn't have mt7921e.
# ===========================================================================
if ! modinfo -F filename mt7921e >/dev/null 2>&1; then
    exit 0
fi
log "step 1/5: reloading mt7921e driver"
if ! modprobe mt7921e; then
    log "step 1/5: modprobe failed; continuing so the interface may still come up"
fi

# ===========================================================================
# 2. Wait for a wireless interface to appear under /sys. The interface
#    name is whatever udev assigned; do not hard-code wlan0.
# ===========================================================================
WIFI_IFACE=""
for i in $(seq 1 20); do   # ~10s
    for iface in /sys/class/net/*/wireless; do
        if [ -d "$iface" ]; then
            WIFI_IFACE=$(basename "$(dirname "$iface")")
            break 2
        fi
    done
    sleep 0.5
done

if [ -z "$WIFI_IFACE" ]; then
    log "step 2/5: no wireless interface appeared within ~10s; exiting"
    exit 0
fi
log "step 2/5: wireless interface detected: $WIFI_IFACE"

# ===========================================================================
# 3. Wait for NetworkManager to be reachable. On early boot NM may still
#    be initializing; without this check the next nmcli calls would fail
#    with "Could not get NMClient object".
# ===========================================================================
if ! command -v nmcli >/dev/null 2>&1; then
    log "step 3/5: nmcli not found; cannot drive NetworkManager"
    exit 0
fi
if ! wait_for_nm_reachable; then
    log "step 3/5: NetworkManager did not become reachable within ~10s; exiting"
    exit 0
fi
log "step 3/5: NetworkManager is reachable"

# ===========================================================================
# 4. State-driven radio toggle.
#
#    This is the timing fix. Every transition between "wifi on" and
#    "wifi off" is verified by polling the actual state of NM and the
#    kernel — never assumed to have completed after a fixed sleep.
#
#    The sequence:
#      nmcli radio wifi off
#        -> wait until NM reports "disabled" (max 10s)
#        -> wait until the device is in "unavailable" state (max 5s)
#        -> wait until the kernel reports the interface is NOT up (max 5s)
#           (this is the "firmware has actually torn down" signal)
#      nmcli radio wifi on
#        -> wait until NM reports "enabled" (max 10s)
#        -> wait until the device is in "disconnected" state (max 10s)
#        -> wait until the kernel reports the interface IS up (max 5s)
#        -> wait until NM's scan returns at least 1 network (max 15s)
#
#    No fixed sleeps anywhere. If any wait times out, the script logs
#    the timeout and continues to the next step — the rest of the
#    sequence is still useful.
# ===========================================================================
log "step 4/5: state-driven radio toggle on $WIFI_IFACE"

# 4a. Turn radio off; verify NM confirms the state change.
if ! nmcli radio wifi off 2>/dev/null; then
    log "step 4a: nmcli radio wifi off returned non-zero; continuing"
fi
if wait_for_wifi_radio "disabled" 10; then
    log "step 4a: NM reports wifi radio = disabled"
else
    log "step 4a: TIMEOUT waiting for NM to report 'disabled' (10s); continuing"
fi

# 4b. Wait for NM to release the device (state machine transition).
if wait_for_device_state "$WIFI_IFACE" "unavailable" 5; then
    log "step 4b: NM reports device $WIFI_IFACE = unavailable"
else
    log "step 4b: TIMEOUT waiting for device to be 'unavailable' (5s); continuing"
fi

# 4c. Wait for the kernel to actually tear the interface down. This is
#     the critical "firmware has unloaded" signal. We do NOT sleep a
#     fixed time here — we poll the operstate.
if wait_for_iface_not_operational "$WIFI_IFACE" 5; then
    log "step 4c: kernel reports interface $WIFI_IFACE is no longer up (firmware torn down)"
else
    log "step 4c: TIMEOUT waiting for interface to go down (5s); continuing"
fi

# 4d. Turn radio on; verify NM confirms.
if ! nmcli radio wifi on 2>/dev/null; then
    log "step 4d: nmcli radio wifi on returned non-zero; continuing"
fi
if wait_for_wifi_radio "enabled" 10; then
    log "step 4d: NM reports wifi radio = enabled"
else
    log "step 4d: TIMEOUT waiting for NM to report 'enabled' (10s); continuing"
fi

# 4e. Wait for the device to be in a "ready but not connected" state.
#     "disconnected" means the device is up and scanning, but not yet
#     associated. "unmanaged" would mean NM is still setting it up; we
#     specifically want to be past that.
if wait_for_device_state "$WIFI_IFACE" "disconnected" 10; then
    log "step 4e: NM reports device $WIFI_IFACE = disconnected (ready to associate)"
else
    log "step 4e: TIMEOUT waiting for device to be 'disconnected' (10s); continuing"
fi

# 4f. Wait for the kernel to report the interface is up. This is the
#     "firmware has actually loaded" signal — without it, the next scan
#     would return nothing.
if wait_for_iface_operational "$WIFI_IFACE" 5; then
    log "step 4f: kernel reports interface $WIFI_IFACE = operstate up (firmware loaded)"
else
    log "step 4f: TIMEOUT waiting for interface to be up (5s); continuing"
fi

# 4g. Wait for the first scan to actually return at least one network.
#     This is the final timing check: wpa_supplicant has finished its
#     initial scan, the driver is fully initialized, and the radio is
#     actually working. The user can now pick a network.
if wait_for_scan_results "$WIFI_IFACE" 1 15; then
    log "step 4g: first scan returned results; radio is fully operational"
else
    log "step 4g: TIMEOUT waiting for first scan (15s); user may need to wait or rescan"
fi

# ===========================================================================
# 5. Opt-in: try to connect to the most recently used saved network.
# ===========================================================================
if [ ! -e /etc/mt7921e-fix/auto-connect ]; then
    log "step 5/5: auto-connect not enabled; user must pick a network manually"
    exit 0
fi

log "step 5/5: auto-connect enabled; attempting to connect to most recently used network"

# 5a. Unblock rfkill if needed. Some laptop BIOSes / hotkeys leave the
#     radio soft-blocked across suspend/resume or reboot.
if command -v rfkill >/dev/null 2>&1; then
    if rfkill list wifi 2>/dev/null | grep -q "Soft blocked: yes"; then
        log "step 5a: wifi radio is soft-blocked; unblocking"
        rfkill unblock wifi 2>/dev/null || true
    fi
fi

# 5b. Find the most recently used saved wifi connection.
saved=$(nmcli -t -f NAME,TYPE,TIMESTAMP connection show 2>/dev/null \
    | awk -F: '$2=="802-11-wireless" && $3!="" {print}' \
    | sort -t: -k3 -n -r \
    | head -n1 \
    | cut -d: -f1)

if [ -z "$saved" ]; then
    log "step 5b: no saved wifi connection found; user must connect manually"
    exit 0
fi

log "step 5b: most recently used saved connection: $saved"

# 5c. Extract the SSID for the visibility check. Skip if the connection
#     has no SSID (hidden networks are a different case — we still try
#     `connection up` later, which works for hidden networks by name).
saved_ssid=$(nmcli -t -f 802-11-wireless.ssid connection show "$saved" 2>/dev/null \
    | head -n1 \
    | sed 's/^[^:]*://')

if [ -n "$saved_ssid" ]; then
    log "step 5c: waiting for saved network '$saved_ssid' to appear in scan"
    if wait_for_ssid_visible "$WIFI_IFACE" "$saved_ssid" 15; then
        log "step 5c: saved network '$saved_ssid' is now visible"
    else
        log "step 5c: TIMEOUT waiting for '$saved_ssid' to appear (15s); trying connection anyway"
    fi
else
    log "step 5c: no SSID for $saved (hidden network?); skipping visibility check"
fi

# 5d. Bring up the saved connection. This is a real action, not a wait:
#     we issue the command and check the device state to see if it
#     transitioned to connected.
log "step 5d: bringing up saved connection: $saved"
if ! nmcli connection up "$saved" ifname "$WIFI_IFACE" 2>/dev/null; then
    log "step 5d: nmcli connection up returned non-zero; user must connect manually"
    exit 0
fi

# 5e. Wait for the device to actually be in the "connected" state. This
#     is the real verification — `connection up` returning 0 only means
#     the request was accepted, not that the link is up.
if wait_for_device_state "$WIFI_IFACE" "connected" 15; then
    log "step 5e: device $WIFI_IFACE is now connected; done"
else
    log "step 5e: TIMEOUT waiting for 'connected' state (15s); user must retry manually"
fi

exit 0
