#!/bin/bash
# Boot-time mt7921e driver activation.
#
# === What this does (and doesn't do) ===
#
# On cold boot the kernel often fails to fully bind mt7921e during PCI
# enumeration — the device shows up but firmware doesn't load cleanly
# and the wireless interface never comes up. This script does an
# explicit `modprobe mt7921e` (only if the module isn't already loaded,
# to avoid kernel re-probe churn) and then ensures the wifi radio is
# turned ON, so the user lands in a state where NM/iwd can manage the
# interface and either auto-connect or wait for a manual pick.
#
# The boot path is intentionally minimal: NO daemon restart, NO NM
# state polling, NO iwd connect retry. iwd's autoconnect state machine
# (autoconnect_quick ~10s / autoconnect_full ~60s) doesn't cooperate
# with explicit commands mid-cycle on this hardware, so trying to
# "push" a connect from boot just burns 60-90s without reliably
# producing a connection. resume-mods.sh runs that dance after
# suspend, where it works because NM has owned the device all along.
#
# Total runtime on this hardware: 1-5s.
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

# Step 1: load the module if not already loaded. On most boots the
# kernel loads mt7921e during PCI enumeration before we get here, in
# which case we skip the modprobe entirely (avoiding the kernel
# interface churn that causes NM to drop the device with
# 'unmanaged-link-not-init').
if [ ! -d /sys/module/mt7921e ]; then
    log "boot-fix: loading mt7921e driver"
    modprobe mt7921e 2>/dev/null || \
        log "boot-fix: modprobe failed; continuing"
else
    log "boot-fix: mt7921e already loaded; skipping modprobe"
fi

# Step 2: wait briefly for the wireless interface to appear under
# /sys. This is a fast poll: 10 iterations × 0.5s = 5s budget. We
# exit as soon as a wireless interface exists, regardless of whether
# NM has claimed it yet — that's NM's job, not ours.
iface=""
for i in 1 2 3 4 5 6 7 8 9 10; do
    for d in /sys/class/net/*/wireless; do
        [ -d "$d" ] || continue
        iface=$(basename "$(dirname "$d")")
        break 2
    done
    sleep 0.5
done

if [ -n "$iface" ]; then
    log "boot-fix: wireless interface ready: $iface"
else
    log "boot-fix: no wireless interface appeared within 5s; skipping radio enable"
    exit 0
fi

# Step 3: turn the wifi radio ON if it's currently off. This is the
# step that makes wifi "activated after reboot" instead of "stuck
# off from the last session". The previous "disable wifi by default"
# behaviour turned it OFF here; we do the opposite. No state
# polling, no daemon restart — just a single `nmcli radio wifi on`.
#
# We do the radio on directly even if NM isn't fully ready yet:
# `nmcli radio wifi` writes the rfkill state via D-Bus, and NM
# picks up the new state on its next event loop tick (typically
# within a few hundred milliseconds). This avoids a 5-10s wait
# for `nmcli -t -f STATE general status` to succeed.
if command -v nmcli >/dev/null 2>&1; then
    # Check current radio state, but with a short timeout — if NM
    # isn't up yet, just issue the radio on and let NM reconcile.
    current=$(timeout 3 nmcli -t -f WIFI general status 2>/dev/null)
    if [ "$current" = "disabled" ]; then
        log "boot-fix: wifi radio was off; enabling"
        nmcli radio wifi on 2>/dev/null || \
            log "boot-fix: nmcli radio wifi on failed; continuing"
    elif [ -z "$current" ]; then
        log "boot-fix: NM not yet reachable; issuing radio wifi on anyway"
        nmcli radio wifi on 2>/dev/null || true
    else
        log "boot-fix: wifi radio is already $current"
    fi
fi

exit 0