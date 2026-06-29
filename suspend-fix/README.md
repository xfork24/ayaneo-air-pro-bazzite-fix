This workaround has been modified to load and unload the mt7921e wifi driver on suspend-resume cycles, and to reload it on cold boot. It is meant as a workaround for specific Ayaneo devices.

# What it does

The script is **state-driven**: every transition is verified by polling
the actual state of NetworkManager and the kernel — never by sleeping
for an assumed amount of time. `sleep 0.5` appears only inside polling
loops as the polling interval.

The same `resume-mods.sh` runs in two contexts:

- `boot-fix.service` runs it once at boot (after NetworkManager and
  iwd are up) to drive the wifi driver through a clean
  modprobe → radio-toggle → iwd-restart → scan → connect sequence.
- `resume-fix.service` runs it after every suspend/resume cycle, where
  the same sequence is needed because resume is when the kernel and
  daemon state is most likely to need a reset.

By default, the script:

The script is **state-driven**: every transition is verified by
polling the actual state of NetworkManager and the kernel — never by
sleeping for an assumed amount of time. `sleep 0.5` appears only
inside polling loops as the polling interval.

By default, the script:

1. Reloads `mt7921e` (`modprobe mt7921e`) — **only if not already
   loaded**. On cold boot the kernel loads mt7921e during PCI
   enumeration and a wireless interface is already present; re-running
   `modprobe` causes kernel interface churn (kernel removes and
   re-adds the interface, NetworkManager ends up with two devices
   fighting over the same predictable name, drops one with
   `unmanaged-link-not-init`, and the wifi never comes up). On resume,
   `suspend-mods` unloaded the module, so `modprobe` is required.
   The script detects the cold-boot case and skips the reload.
2. Waits for a wireless interface to appear (≤ ~10s, polled).
3. Waits for NetworkManager to be reachable (≤ ~10s, polled).
3.5. Waits for NetworkManager to actually claim the wifi device
   (≤ ~15s, polled). NM can answer `general status` long before it
   has finished initializing devices, so without this wait a global
   `nmcli radio wifi off/on` issued from boot-fix races NM's
   device-init and silently no-ops. On resume NM already owns the
   device, so this returns immediately.
4. Performs a state-driven radio toggle on the wifi interface:
   - `nmcli radio wifi off`, then **wait for NM to confirm `disabled`** (≤ 10s)
   - **wait for the device state to reach `unavailable`** (≤ 5s)
   - **wait for the kernel to report the interface is no longer up**
     (this is the actual "firmware has torn down" signal) (≤ 5s)
   - **Reset the wifi daemon's stale state**. On Bazzite the daemon
     is iwd; on most other distros it is wpa_supplicant. The fix
     differs by backend (see `# Why we reset the wifi daemon`
     below):
     - iwd: `systemctl restart iwd.service` + wait for it to be
       running again (≤ 15s). iwd's adapter state is corrupted at
       this point; a full service restart is the only reliable reset.
     - wpa_supplicant: `pkill -TERM wpa_supplicant` + wait for the
       process to actually exit (≤ 5s); NM spawns a fresh one.
   - `nmcli radio wifi on`, then **wait for NM to confirm `enabled`** (≤ 10s)
   - **Wait for the wifi daemon to be back with an adapter**
     (≤ 10s). For iwd this is `iwctl adapter list` showing a `phy`
     row; for wpa_supplicant this is `pgrep -x wpa_supplicant`.
   - **wait for the device state to reach `disconnected`** (≤ 10s)
   - **wait for the kernel to report the interface is operational**
     (`up`, `unknown`, or `dormant` are all accepted) (≤ 10s)
   - **wait for the first scan to return at least one network** (≤ 15s)
5. The user picks a network by hand.

If any of those waits times out, the script logs the timeout and
continues to the next step — the rest of the sequence is still useful,
and the journal will show exactly which step blocked.

# Opt-in: automatic re-association

If you want the script to also try to connect to your most recently
used saved network, create the marker file:

```
sudo mkdir -p /etc/mt7921e-fix
sudo touch /etc/mt7921e-fix/auto-connect
```

With the marker present, the script additionally:

- Unblocks the radio via `rfkill` if it has been soft-blocked.
- Finds the most recently used saved wifi connection.
- **Waits for that SSID to appear in the scan** (≤ 15s).
- Brings up the connection with `nmcli connection up`.
- **Waits for the device state to reach `connected`** (≤ 15s) to verify
  the link actually came up (the `connection up` command only returns
  success when the request is accepted, not when the link is up).

To opt out:

```
sudo rm /etc/mt7921e-fix/auto-connect
```

# Why state-driven, not fixed-sleep

The mt7921e driver reload races with the chip's firmware load,
regulatory-domain re-setup, `wpa_supplicant`'s initial scan, and
NetworkManager's internal state machine. Fixed-sleep approaches (e.g.
`sleep 2` between off and on) often miss the actual transition — the
first toggle can complete before the firmware is unloaded, the second
toggle can complete before the first scan returns, and so on. That is
why a single fixed-sleep toggle requires a manual retry.

Polling for the actual state eliminates the race: each step is gated
on the kernel/NM/wpa_supplicant having truly reached the desired state.
The script returns from each helper as soon as the state is observed,
so a fast machine completes in a few seconds, and a slow machine just
waits longer (within the timeout) instead of giving up too early.

# Boot-time ordering

`boot-fix.service` is ordered `After=NetworkManager.service
iwd.service` (not `network-pre.target`, which is reached *before* NM
has finished initializing its devices). Even with that ordering, NM
can be "reachable" while still mid-init, so the script also waits
explicitly for the wifi device to show up in `nmcli device status`
as type `wifi` before issuing the radio toggle — this is step 3.5 in
the log.

# Why we explicitly kill `wpa_supplicant`

`nmcli radio wifi off` does not actually stop the `wpa_supplicant`
process — it just tells it to stop scanning. After the driver is
reloaded and a new interface appears, the same `wpa_supplicant`
process tries to manage it, but its internal state machine still
references the old (now-removed) interface. The first authentication
attempt therefore aborts immediately with `DEAUTH_LEAVING` (visible
in `dmesg`), and the connection never comes up. The user has to
manually toggle the radio several times to clear the state.

The script works around this by `pkill`-ing `wpa_supplicant` after
`nmcli radio wifi off` and before `nmcli radio wifi on`. NM detects
the death and spawns a fresh `wpa_supplicant` instance with no stale
state. The radio toggle then operates on a clean supplicant, and
NM's autoconnect can complete in a single cycle.

# Why we reset the wifi daemon (iwd-aware)

The `DEAUTH_LEAVING` loop is not specific to wpa_supplicant: it is a
property of any daemon that retains state across a driver reload or
radio toggle. On Bazzite / Fedora Atomic, NetworkManager uses iwd
(`/usr/lib/NetworkManager/conf.d/50-iwd.conf: wifi.backend=iwd`),
so killing wpa_supplicant is a no-op — the script's `pkill` runs
against a process that does not exist.

The fix in step 4c.5 dispatches on the detected backend:

- **iwd**: full service restart (`systemctl restart iwd.service`).
  iwd's adapter state holds a handle to the now-defunct interface;
  the only reliable reset is to drop the whole service and let
  systemd bring it back up clean. On iwd restart the adapter
  registration is lost; NM reattaches when it next sees an iwd
  adapter, and iwd's first scan triggers autoconnect to a known
  network.
- **wpa_supplicant**: `pkill -TERM`, wait for exit, NM spawns fresh.

The script auto-detects: it checks for an active `iwd.service`
first, then falls back to checking for a running `wpa_supplicant`
process. The detected backend is logged as `step 1/5: detected wifi
daemon: iwd|wpa_supplicant|none`.

# Install instructions

```
curl -L https://raw.githubusercontent.com/xfork24/ayaneo-air-pro-bazzite-fix/mt7921e_fix/suspend-fix/install.sh | sh
```

# uninstall instructions

```
sudo systemctl disable --now resume-fix.service
sudo systemctl disable --now suspend-fix.service
sudo systemctl disable --now boot-fix.service

sudo rm /usr/local/bin/suspend-mods
sudo rm /usr/local/bin/resume-mods

sudo rm /etc/systemd/system/resume-fix.service
sudo rm /etc/systemd/system/suspend-fix.service
sudo rm /etc/systemd/system/boot-fix.service

sudo rm -rf /etc/mt7921e-fix
```

# troubleshooting

If WiFi does not come up after a resume or boot, inspect the journal:

```
journalctl -b -u boot-fix.service -u resume-fix.service
journalctl -t mt7921e-fix
```

Every step logs a `step N/5: ...` line. If a step times out, the log
will say so explicitly (e.g. `step 4f: TIMEOUT waiting for interface to
be up (5s); continuing`). This tells you exactly which state transition
the hardware is failing to complete.
