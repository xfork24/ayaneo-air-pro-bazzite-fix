#!/bin/bash
# Boot-time mt7921e driver activation.
#
# === Why boot needs more than just `modprobe` ===
#
# The kernel often fails to fully bind mt7921e during PCI enumeration
# on first boot — the device shows up but firmware doesn't load cleanly
# and the wireless interface never comes up. An explicit `modprobe
# mt7921e` after the kernel settles re-probes the device and gets
# firmware loaded. Smart-modprobe (skip if /sys/module/mt7921e
# already exists) avoids the kernel re-probe churn that causes NM to
# drop the device with 'unmanaged-link-not-init' on cold boot.
#
# After the driver is loaded and the interface exists, NetworkManager
# has to actually claim the device before any global `nmcli radio
# wifi on` will take effect — at that point NM's state machine knows
# the device exists and can propagate the radio state to it. Without
# that wait, the radio toggle silently no-ops and the user lands in
# a "wifi radio says on, but the device isn't really up" state.
# Hence the explicit "wait for NM to claim" step below.
#
# === What this script does NOT do ===
#
# The boot path is intentionally minimal: NO iwd restart, NO NM state
# polling, NO iwd connect retry. iwd's autoconnect state machine
# (autoconnect_quick ~10s / autoconnect_full ~60s) doesn't cooperate
# with explicit commands mid-cycle on this hardware, so trying to
# "push" a connect from boot just burns 60-90s without reliably
# producing a connection. resume-mods.sh runs that dance after
# suspend, where it works because NM has owned the device all along.
#
# === Boot time budget ===
#
# Step 1 (modprobe):         0-1s
# Step 2 (wait for iface):   0-5s
# Step 3 (wait for NM):      0-10s
# Step 4 (wait for claim):   0-15s
# Step 5 (radio on):         instant
# Total: 0-31s, typically 1-2s once NM is up.
#
# Exit status: always 0. This script must never mark the calling
# systemd unit as failed: the driver probe alone is the win.

set -u
LOG_TAG="mt7921e-fix"

log() {
    if command -v systemd-cat >/dev/null 2>&1; then
        printf '%s\n' "$*" | systemd-cat -t "$LOG_TAG" 2>/dev/null || true
    elif command -v logger >/dev/null 2>&1; then
        logger -t "$LOG_TAG" "$*" 2>/dev/null || true
    fi
}

# Skip cleanly on hardware that doesn't have mt7921e.
if ! modinfo -F filename mt7921e >/dev/null 2>&1; then
    exit 0
fi

# Step 1: load the module if not already loaded.
if [ ! -d /sys/module/mt7921e ]; then
    log "boot-fix: loading mt7921e driver"
    modprobe mt7921e 2>/dev/null || \
        log "boot-fix: modprobe failed; continuing"
else
    log "boot-fix: mt7921e already loaded; skipping modprobe"
fi

# Step 2: wait for the wireless interface to appear under /sys.
iface=""
for i in 1 2 3 4 5 6 7 8 9 10; do
    for d in /sys/class/net/*/wireless; do
        [ -d "$d" ] || continue
        iface=$(basename "$(dirname "$d")")
        break 2
    done
    sleep 0.5
done

if [ -z "$iface" ]; then
    log "boot-fix: no wireless interface appeared within 5s; skipping NM and radio steps"
    exit 0
fi
log "boot-fix: wireless interface ready: $iface"

# Step 3: wait for NetworkManager to be reachable. NM may still be
# initializing at the time boot-fix runs (it's after
# systemd-modules-load.service, which is before NetworkManager in
# the boot graph). Without this check the next nmcli calls would
# fail with "Could not get NMClient object".
if ! command -v nmcli >/dev/null 2>&1; then
    log "boot-fix: nmcli not found; cannot drive NetworkManager"
    exit 0
fi

nm_reachable=0
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if nmcli -t -f STATE general status >/dev/null 2>&1; then
        nm_reachable=1
        log "boot-fix: NetworkManager is reachable"
        break
    fi
    sleep 0.5
done

if [ "$nm_reachable" -ne 1 ]; then
    log "boot-fix: NetworkManager did not become reachable within 10s; skipping radio step"
    exit 0
fi

# Step 4: wait for NM to actually claim the wifi device. NM can be
# reachable and responsive long before it has finished initializing
# its devices. At that point `nmcli radio wifi on` is accepted by
# NM but the global toggle is never propagated to a device state.
# This is the critical "make sure radio toggle will actually take
# effect" wait. On the user's machine NM typically claims the
# device within ~0.5s; 15s is a generous upper bound.
claimed=0
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    found=$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null \
        | awk -F: -v d="$iface" '$1==d && $2=="wifi" {print "yes"; exit}')
    if [ "$found" = "yes" ]; then
        claimed=1
        log "boot-fix: NetworkManager has claimed $iface"
        break
    fi
    sleep 0.5
done

if [ "$claimed" -ne 1 ]; then
    log "boot-fix: NetworkManager did not claim $iface within 15s; skipping radio step (toggle may not take effect)"
    exit 0
fi

# Step 5: turn the wifi radio ON. This is what makes wifi
# "activated after reboot" instead of "stuck off from the last
# session". We only issue the command if it's currently off
# (avoids spurious rfkill events on the rare boot where the
# radio is already enabled).
current=$(nmcli -t -f WIFI general status 2>/dev/null)
if [ "$current" = "disabled" ]; then
    log "boot-fix: enabling wifi radio"
    nmcli radio wifi on 2>/dev/null || \
        log "boot-fix: nmcli radio wifi on failed; continuing"
elif [ -z "$current" ]; then
    log "boot-fix: could not read radio state; issuing radio wifi on anyway"
    nmcli radio wifi on 2>/dev/null || true
else
    log "boot-fix: wifi radio is already $current"
fi

exit 0