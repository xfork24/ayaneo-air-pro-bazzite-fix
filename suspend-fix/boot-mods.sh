#!/bin/bash
# Boot-time mt7921e driver activation.
#
# The kernel often fails to fully bind mt7921e during PCI enumeration
# on first boot — the device shows up but the firmware doesn't load
# cleanly and the wireless interface never comes up. This script does
# an explicit `modprobe mt7921e` after the kernel settles, which
# re-probes the device and gets firmware loaded.
#
# === Intentionally minimal ===
# This script does NOT do the radio toggle, daemon restart, or NM
# state polling that resume-mods.sh does. The boot-time variant only
# needs to make the driver / interface available; iwd or wpa_supplicant
# then pick up from there and either auto-connect or wait for the
# user to pick a network. Doing more here burns 60-90s of boot time
# without reliably producing an auto-connect (iwd's autoconnect state
# machine rejects explicit commands mid-cycle).
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

# Load the module only if not already loaded. On most boots the kernel
# loads mt7921e during PCI enumeration before we get here, in which
# case we skip the modprobe entirely (avoiding the kernel interface
# churn that causes NM to drop the device with
# 'unmanaged-link-not-init').
if [ ! -d /sys/module/mt7921e ]; then
    log "boot-fix: loading mt7921e driver"
    modprobe mt7921e 2>/dev/null || \
        log "boot-fix: modprobe failed; continuing"
else
    log "boot-fix: mt7921e already loaded; skipping modprobe"
fi

# Wait briefly for the wireless interface to appear. This is a fast
# poll: 10 iterations × 0.5s = 5s budget. We exit as soon as a
# wireless interface exists under /sys/class/net/*/wireless, regardless
# of whether NM has claimed it yet — that's NM's job, not ours.
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
    log "boot-fix: no wireless interface appeared within 5s"
fi

exit 0