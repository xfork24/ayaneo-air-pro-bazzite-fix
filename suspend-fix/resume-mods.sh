#!/bin/bash
# Reloads the mt7921e WiFi driver on resume from suspend and on cold boot.
#
# === Design principle: no fixed sleeps between state transitions ===
# Every transition is verified by polling the actual state — never by
# sleeping for an assumed amount of time. `sleep 0.5` only appears inside
# polling loops as the polling interval. This eliminates the "race between
# driver, firmware, the wifi daemon (iwd or wpa_supplicant), and NM" that
# requires multiple manual radio toggles to overcome.
#
# === Cold-boot vs resume ===
# On resume, suspend-mods has unloaded the module, so this script must
# `modprobe mt7921e` to bring the driver back. On cold boot, the kernel
# already loads mt7921e during PCI enumeration and a wireless interface
# is already present — re-modprobing causes the kernel to remove and
# re-add the interface, and NetworkManager ends up with two devices
# fighting over the same predictable name, dropping one with
# "unmanaged-link-not-init" (observed in boot logs). This script detects
# the cold-boot case (module loaded + wireless interface present) and
# skips modprobe there.
#
# === wifi daemon: iwd or wpa_supplicant ===
# The "DEAUTH_LEAVING" loop (next auth aborts immediately after a radio
# toggle or driver reload) is a stale-state issue in whichever daemon
# owns the interface. On Bazzite / Fedora Atomic that is iwd
# (`/usr/lib/NetworkManager/conf.d/50-iwd.conf: wifi.backend=iwd`); on
# most other distros it is wpa_supplicant. The fix is daemon-specific:
#
#   wpa_supplicant: `pkill -TERM` (let NM respawn a fresh one)
#   iwd:            `systemctl restart iwd.service` (full state reset)
#
# The script detects which backend is in use and dispatches.
#
# === Default behavior ===
# Reload the driver if needed, do a state-driven radio toggle
# (off → on, each transition verified by polling NM and the kernel),
# reset the wifi daemon's stale state, wait for the first scan to
# actually return results, and stop. The user picks a network by hand.
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

# Wait for NetworkManager to actually claim the wifi device (i.e. the
# interface shows up in `nmcli device status` as type "wifi"). NM can be
# reachable and responsive long before it has finished initializing its
# devices — at that point `nmcli radio wifi off/on` is accepted by NM,
# but the global toggle is never propagated to a device state, and the
# subsequent waits for "device unavailable / disconnected" all time out.
# This is exactly what happens on cold boot when boot-fix races NM's
# device-init; on resume NM has owned the device all along so this
# returns immediately.
# Args: <iface> <timeout-seconds>
wait_for_nm_wifi_device() {
    local iface="$1" timeout_s="$2"
    local i max found
    max=$((timeout_s * 2))
    for i in $(seq 1 "$max"); do
        found=$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null \
            | awk -F: -v d="$iface" '$1==d && $2=="wifi" {print "yes"; exit}')
        if [ "$found" = "yes" ]; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

# Stop the wpa_supplicant process and wait for it to actually exit.
# This is the key to clearing the corrupted auth state observed in
# dmesg: the old wpa_supplicant instance, after a driver reload, will
# immediately abort any new authentication with "DEAUTH_LEAVING"
# because its internal state machine thinks it is still associated
# with the now-defunct interface. Killing the process and letting NM
# start a fresh one clears that state.
# Args: <timeout-seconds>
stop_wpa_supplicant() {
    local timeout_s="$1"
    local i max

    # Send SIGTERM (graceful). If no process matches, pkill returns
    # non-zero, which we treat as "already gone" and return success.
    if ! pkill -TERM -x wpa_supplicant 2>/dev/null; then
        # Either there was no wpa_supplicant, or it exited before we
        # could check. Either way, it is not running now.
        return 0
    fi

    # Wait up to timeout_s for the process to actually exit.
    max=$((timeout_s * 2))
    for i in $(seq 1 "$max"); do
        if ! pgrep -x wpa_supplicant >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.5
    done

    # Still alive after the timeout. Force-kill.
    pkill -KILL -x wpa_supplicant 2>/dev/null || true
    sleep 0.5
    if ! pgrep -x wpa_supplicant >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Wait for a wpa_supplicant process to be running. After we kill the
# old one and tell NM to re-enable the radio, NM will spawn a fresh
# wpa_supplicant. This helper confirms the new instance is up before
# we proceed to wait for the device to reach a usable state.
# Args: <timeout-seconds>
wait_for_wpa_supplicant_running() {
    local timeout_s="$1"
    local i max
    max=$((timeout_s * 2))
    for i in $(seq 1 "$max"); do
        if pgrep -x wpa_supplicant >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

# ===========================================================================
# Backend dispatch: iwd vs wpa_supplicant.
# ===========================================================================
# Detect which wifi daemon is currently running. On Bazzite / Fedora
# Atomic this is iwd (`/usr/lib/NetworkManager/conf.d/50-iwd.conf:
# wifi.backend=iwd`); on most other distros it is wpa_supplicant. The
# state-reset step below acts on whichever is running — each retains
# stale internal state after a driver reload or radio toggle, and that
# stale state is what causes the next auth to abort immediately with
# DEAUTH_LEAVING (kernel log) on this hardware.
WIFI_DAEMON=""
if systemctl is-active --quiet iwd.service 2>/dev/null; then
    WIFI_DAEMON="iwd"
elif pgrep -x wpa_supplicant >/dev/null 2>&1; then
    WIFI_DAEMON="wpa_supplicant"
fi

# Reset the wifi daemon's internal state so the next association attempt
# runs against a clean state machine, not one that still references the
# now-defunct interface. This is the daemon-specific equivalent of the
# wpa_supplicant-only "pkill and let NM respawn" trick that originally
# fixed the wpa_supplicant flavor of the DEAUTH_LEAVING loop.
# Args: <timeout-seconds>
reset_wifi_daemon() {
    local timeout_s="$1"
    case "$WIFI_DAEMON" in
        iwd)
            # A full service restart clears all of iwd's internal state:
            # known-network cache, scan history, station state, and the
            # adapter object. On startup iwd reads rfkill again and
            # starts with the adapter Powered=false if NM currently has
            # the radio disabled — `nmcli radio wifi on` later will turn
            # it back on cleanly. NM reattaches to the new iwd instance
            # and resumes autoconnect on the first scan.
            log "step 4c.5: restarting iwd.service to clear stale adapter state"
            systemctl restart iwd.service 2>/dev/null || true
            local i max
            max=$((timeout_s * 2))
            for i in $(seq 1 "$max"); do
                if systemctl is-active --quiet iwd.service 2>/dev/null; then
                    return 0
                fi
                sleep 0.5
            done
            return 1
            ;;
        wpa_supplicant)
            log "step 4c.5: killing stale wpa_supplicant to clear corrupted auth state"
            stop_wpa_supplicant "$timeout_s"
            ;;
        *)
            log "step 4c.5: no wifi daemon detected; skipping state reset"
            return 0
            ;;
    esac
}

# Wait for the wifi daemon to be ready (post-reset) and have registered
# an adapter with the kernel. After the radio comes back on, NM tells
# the daemon to claim the device again; this helper confirms the daemon
# is up and visible to NM before we proceed to wait for device / scan.
# Args: <timeout-seconds>
wait_for_daemon_ready() {
    local timeout_s="$1"
    case "$WIFI_DAEMON" in
        iwd)
            # iwd is up AND has at least one adapter registered. We poll
            # `iwctl adapter list` rather than `pgrep iwd` because a
            # freshly-restarted iwd can be running for ~100ms before it
            # has finished enumerating adapters — and `systemctl
            # is-active` would already be true at that point.
            local i max
            max=$((timeout_s * 2))
            for i in $(seq 1 "$max"); do
                if iwctl adapter list 2>/dev/null | grep -q '^[[:space:]]*phy'; then
                    return 0
                fi
                sleep 0.5
            done
            return 1
            ;;
        wpa_supplicant)
            wait_for_wpa_supplicant_running "$timeout_s"
            ;;
        *)
            return 0
            ;;
    esac
}

# ===========================================================================
# 1. Reload the driver. Skip cleanly on hardware that doesn't have mt7921e.
#    Also skip modprobe on cold boot if the kernel has already loaded it
#    and a wireless interface is present — re-modprobing causes kernel
#    interface churn that NM ends up rejecting ("unmanaged-link-not-init").
# ===========================================================================
if ! modinfo -F filename mt7921e >/dev/null 2>&1; then
    exit 0
fi

NEEDS_MODPROBE=0
# If the module is not loaded yet, we need to modprobe. On cold boot
# the kernel may still be mid-PCI-enumeration when boot-fix runs (we
# saw `/sys/module/mt7921e` not yet present even though the device
# was about to be probed), so checking ONLY the module directory —
# not the wireless interface directory — is the right gate. The
# original `&&` against the wireless dir caused us to modprobe when
# the interface simply hadn't been created yet, which then triggered
# kernel re-probe churn.
if [ ! -d /sys/module/mt7921e ]; then
    NEEDS_MODPROBE=1
fi

if [ "$NEEDS_MODPROBE" -eq 1 ]; then
    log "step 1/5: loading mt7921e driver"
    if ! modprobe mt7921e 2>/dev/null; then
        log "step 1/5: modprobe failed; continuing so the interface may still come up"
    fi
else
    log "step 1/5: mt7921e already loaded with wireless interface present; skipping modprobe to avoid re-probe churn"
fi

log "step 1/5: detected wifi daemon: ${WIFI_DAEMON:-none}"

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

# 3.5. Wait for NM to actually claim the wifi device. On cold boot, NM
#      can answer `nmcli general status` long before it has finished
#      initializing devices. The state-driven toggle below relies on NM
#      being able to propagate the radio state to a device; without
#      this wait the toggle silently no-ops and every subsequent wait
#      (4b, 4d.5, 4e, 4f, 4g) times out. On resume NM already owns the
#      device, so this returns immediately.
if wait_for_nm_wifi_device "$WIFI_IFACE" 15; then
    log "step 3.5/5: NetworkManager has claimed $WIFI_IFACE"
else
    log "step 3.5/5: TIMEOUT waiting for NM to claim $WIFI_IFACE (15s); continuing (toggle may not take effect)"
fi

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

# 4c.5. Reset the wifi daemon's stale state. After a driver reload or
#       global radio toggle, the daemon (iwd or wpa_supplicant)
#       retains internal state that still references the now-defunct
#       interface. The next auth attempt aborts immediately with
#       DEAUTH_LEAVING because the daemon's state machine thinks it is
#       already associated. Killing (wpa_supplicant) or restarting
#       (iwd) the daemon makes NM establish it fresh against the new
#       interface. Dispatched by `reset_wifi_daemon` because the fix
#       differs by backend — on Bazzite iwd is the backend; on most
#       other distros wpa_supplicant is.
if reset_wifi_daemon 15; then
    log "step 4c.5: wifi daemon reset complete"
else
    log "step 4c.5: TIMEOUT resetting wifi daemon (15s); continuing"
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

# 4d.5. Wait for the wifi daemon to be back up with an adapter. This
#       confirms that the daemon reset in 4c.5 has taken effect AND a
#       new adapter registration is visible to NM before we proceed to
#       wait for the device / scan to settle. The check dispatched by
#       `wait_for_daemon_ready` differs by backend: iwd is checked via
#       `iwctl adapter list` (a freshly restarted iwd registers the
#       adapter within ~100ms — but in practice on this hardware it
#       can take 5-15s, so the timeout is generous); wpa_supplicant
#       is checked via `pgrep -x` (NM spawns a fresh one when it sees
#       the radio on).
if wait_for_daemon_ready 30; then
    log "step 4d.5: wifi daemon is ready (adapter visible to NM)"
else
    log "step 4d.5: TIMEOUT waiting for daemon ready (30s); continuing"
fi

# 4d.6. If iwd is the backend, force an explicit scan now. iwd's
#       natural autoconnect timer can take 60+ seconds to fire its
#       first scan after a service restart (autoconnect_quick /
#       autoconnect_full cadence). `iwctl station <iface> scan`
#       triggers an immediate scan that races with iwd's startup and
#       gives step 4g something to verify quickly. Without this kick,
#       iwd sits idle for ~60s after our reset, and the user sees a
#       working wifi radio that doesn't connect for a minute. We only
#       do this if 4d.5 saw the adapter (otherwise iwctl will error).
if [ "$WIFI_DAEMON" = "iwd" ] && [ -n "$WIFI_IFACE" ]; then
    log "step 4d.6: triggering fresh iwd scan on $WIFI_IFACE"
    if iwctl station "$WIFI_IFACE" scan 2>/dev/null; then
        log "step 4d.6: iwd scan requested"
    else
        log "step 4d.6: iwctl scan returned non-zero; continuing"
    fi
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

# 4f. Wait for the kernel to report the interface is operational. The
#     operstate can be "up", "unknown", or "dormant" depending on the
#     driver's state machine; what matters is that it is not "down"
#     or "notpresent". The mt7921e driver in particular can show
#     "unknown" briefly while the firmware finishes initializing.
#     Treat any of {up, unknown, dormant, testing} as good enough; the
#     real verification is step 4g, which waits for the scan to
#     actually return results.
wait_for_iface_operational_lenient() {
    local iface="$1" timeout_s="$2"
    local i max oper
    max=$((timeout_s * 2))
    for i in $(seq 1 "$max"); do
        if [ -e "/sys/class/net/$iface/operstate" ]; then
            oper=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null) || oper=""
            case "$oper" in
                up|unknown|dormant|testing)
                    return 0
                    ;;
            esac
        fi
        sleep 0.5
    done
    return 1
}
if wait_for_iface_operational_lenient "$WIFI_IFACE" 30; then
    log "step 4f: kernel reports interface $WIFI_IFACE is operational (firmware ready)"
else
    log "step 4f: TIMEOUT waiting for interface to be operational (30s); continuing"
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
#
#     For the iwd backend we use `iwctl station <iface> connect <SSID>`
#     rather than `nmcli connection up`. NM's connection profile store
#     and iwd's known-networks cache can disagree (NM may have a profile
#     bound to a specific BSSID that is no longer responding), which
#     makes `nmcli connection up` return non-zero even when the saved
#     network is right there. `iwctl station connect` bypasses NM's
#     profile lookup and asks iwd directly to find and associate — iwd
#     picks the best responding BSS for the SSID and connects in one
#     step. This sidesteps the "nmcli returns non-zero, user has to
#     toggle and click" failure mode on Bazzite.
log "step 5d: bringing up saved connection: $saved"
case "$WIFI_DAEMON" in
    iwd)
        # iwd rejects an explicit `iwctl station connect` while it is
        # mid-autoconnect-cycle. After our step 4c.5 iwd restart, iwd
        # is sitting in `autoconnect_quick` / `autoconnect_full`
        # cooldown, and iwctl commands that don't fit its internal
        # state machine get rejected with `Operation failed`. The
        # rejection doesn't break anything — iwd continues its
        # autoconnect cycle on its own — but it means our explicit
        # connect never lands.
        #
        # The fix is to retry: iwd's full autoconnect cycle is ~60s,
        # and during each cycle there is a brief `disconnected` window
        # where iwd will accept an explicit connect. 12 attempts × 5s
        # covers one full cycle. If any attempt lands, iwd connects
        # immediately. If not, iwd's own autoconnect may have already
        # connected (fast path detected inside the loop) or it will
        # eventually (handled by step 5e's 120s wait).
        log "step 5d: iwd backend; retrying iwctl station connect to '$saved_ssid'"
        connected=0
        for attempt in 1 2 3; do
            if iwctl station "$WIFI_IFACE" connect "$saved_ssid" 2>/dev/null; then
                log "step 5d: iwctl connect accepted on attempt $attempt"
                connected=1
                break
            fi
            # Fast path: iwd's own autoconnect may have succeeded
            # between our attempts. If so, we're done.
            state=$(nmcli -t -f DEVICE,STATE device status 2>/dev/null \
                | awk -F: -v d="$WIFI_IFACE" '$1==d {print $2; exit}')
            if [ "$state" = "connected" ]; then
                log "step 5d: device already connected (iwd autoconnect); attempt $attempt"
                connected=1
                break
            fi
            log "step 5d: iwctl connect attempt $attempt rejected; retrying in 5s"
            sleep 5
        done
        if [ "$connected" -ne 1 ]; then
            log "step 5d: iwctl connect did not land in 3 attempts; will wait for iwd's autoconnect"
        fi
        ;;
    *)
        if ! nmcli connection up "$saved" ifname "$WIFI_IFACE" 2>/dev/null; then
            log "step 5d: nmcli connection up returned non-zero; user must connect manually"
            exit 0
        fi
        ;;
esac

# 5e. Wait for the device to actually be in the "connected" state. This
#     is the real verification — `connection up` (or `iwctl connect`)
#     returning 0 only means the request was accepted, not that the
#     link is up.
#
#     For iwd this also covers the autoconnect-recovery case: when
#     step 5d's retries all get rejected, iwd's autoconnect cycle
#     runs in the background and eventually lands on a working BSS.
#     Empirically that takes 60-120s on this hardware, so the timeout
#     here is generous. The previous 15s timeout was wrong: iwd's
#     autoconnect_full scan fires roughly once a minute, and the
#     first BSS it tries (QQ2025_5G here) tends to fail with
#     DEAUTH_LEAVING; iwd then has to retry with a different BSS.
if wait_for_device_state "$WIFI_IFACE" "connected" 120; then
    log "step 5e: device $WIFI_IFACE is now connected; done"
else
    log "step 5e: TIMEOUT waiting for 'connected' state (120s); user must retry manually"
fi

exit 0
