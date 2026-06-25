This workaround has been modified to load and unload the mt7921e wifi driver on suspend-resume cycles, and to reload it on cold boot. It is meant as a workaround for specific Ayaneo devices.

# What it does

The script is **state-driven**: every transition is verified by polling
the actual state of NetworkManager and the kernel — never by sleeping
for an assumed amount of time. `sleep 0.5` appears only inside polling
loops as the polling interval.

By default, the script:

1. Reloads `mt7921e` (`modprobe mt7921e`).
2. Waits for a wireless interface to appear (≤ ~10s, polled).
3. Waits for NetworkManager to be reachable (≤ ~10s, polled).
4. Performs a state-driven radio toggle on the wifi interface:
   - `nmcli radio wifi off`, then **wait for NM to confirm `disabled`** (≤ 10s)
   - **wait for the device state to reach `unavailable`** (≤ 5s)
   - **wait for the kernel to report the interface is no longer up**
     (this is the actual "firmware has torn down" signal) (≤ 5s)
   - **`pkill wpa_supplicant`** and **wait for the process to actually
     exit** (≤ 5s). This is the critical fix for the post-driver-reload
     auth loop: the old `wpa_supplicant` instance has internal state
     referencing a now-removed interface, and would otherwise
     immediately abort any new authentication with `DEAUTH_LEAVING`
     (visible in `dmesg`).
   - `nmcli radio wifi on`, then **wait for NM to confirm `enabled`** (≤ 10s)
   - **wait for a fresh `wpa_supplicant` process to be running** (≤ 5s)
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
