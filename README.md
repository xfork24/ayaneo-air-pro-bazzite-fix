# ayaneo-air-pro-bazzite-fix

Fixes for running Bazzite Linux on Ayaneo / GPD handheld devices.

**The only actively maintained functionality in this repository is the
[`suspend-fix/`](./suspend-fix) directory.** It works around a known issue
with the `mt7921e` WiFi driver on these devices. All other directories and
top-level scripts in this repository are kept for historical reference and
are not part of the supported setup.

---

# suspend-fix: mt7921e WiFi driver fix

## The problem

On certain Ayaneo / GPD handhelds, the `mt7921e` WiFi driver does not bring
the WiFi interface back up reliably after a suspend/resume cycle, and the
same broken state is present on a clean cold boot. The interface may be
missing entirely, or it may appear but be stuck in a broken state.

## The fix

A pair of helper scripts plus three systemd units that unload and reload
the driver at exactly the right moments:

| Trigger              | Unit                  | Script + action                                                  |
|----------------------|-----------------------|------------------------------------------------------------------|
| Going to sleep       | `suspend-fix.service` | `suspend-mods` runs `modprobe -r mt7921e` to unload the driver   |
| Waking from sleep    | `resume-fix.service`  | `resume-mods` reloads the driver (and, if opted in, re-associates) |
| Cold boot            | `boot-fix.service`    | same `resume-mods` script — covers the case where the broken state is present on first boot |

`modprobe` on an already-loaded module is a safe no-op, so reloading the
driver at boot is harmless on systems where the autoloader has already done
its job.

## Default behavior: state-driven wifi enable

By default, the `resume-mods` script does the following on every boot and
resume. Every transition is verified by polling the actual state — never
assumed to have completed after a fixed sleep:

1. Reload `mt7921e`.
2. Wait for a wireless interface to appear (≤ ~10s, polled).
3. Wait for NetworkManager to be reachable (≤ ~10s, polled).
4. **State-driven radio toggle** on the wifi interface:
   - `nmcli radio wifi off`, then **wait for NM to report `disabled`** (≤ 10s)
   - **wait for the device state to reach `unavailable`** (≤ 5s)
   - **wait for the kernel to report the interface is no longer up** —
     this is the actual "firmware has torn down" signal (≤ 5s)
   - **`pkill wpa_supplicant`** and **wait for the process to actually
     exit** (≤ 5s). This clears the corrupted auth state that causes
     the post-driver-reload "DEAUTH_LEAVING" loop visible in `dmesg`.
   - `nmcli radio wifi on`, then **wait for NM to report `enabled`** (≤ 10s)
   - **wait for a fresh `wpa_supplicant` process to be running** (≤ 5s)
   - **wait for the device state to reach `disconnected`** (≤ 10s)
   - **wait for the kernel to report the interface is operational** —
     `up`, `unknown`, or `dormant` are all accepted (≤ 10s)
   - **wait for the first scan to return at least one network** (≤ 15s)
5. The user picks a network by hand.

The user starts from a known "wifi enabled, fully initialized" state on
every boot and resume, regardless of what the radio state was before.

## Why state-driven, not fixed-sleep

The mt7921e driver reload races with the chip's firmware load,
regulatory-domain re-setup, `wpa_supplicant`'s initial scan, and
NetworkManager's internal state machine. A fixed-sleep approach
(`sleep 2` between off and on) can complete each toggle before the
state actually transitions, so the next step is still racy — that is
why a single fixed-sleep toggle requires a manual retry.

Polling for the actual state eliminates the race: each step is gated
on NM / the kernel / `wpa_supplicant` having truly reached the desired
state. The script returns from each helper as soon as the state is
observed, so a fast machine completes in a few seconds, and a slow
machine just waits longer (within the timeout) instead of giving up
too early. If the wifi stack hangs at any step, the journal will say
exactly which step is blocked.

## Why we explicitly kill `wpa_supplicant`

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

## Opt-in: automatic re-association

If you want the script to also try to connect to your most recently
used saved network, create the marker file:

```
sudo mkdir -p /etc/mt7921e-fix
sudo touch /etc/mt7921e-fix/auto-connect
```

With the marker present, `resume-mods` additionally:

- Unblocks the radio via `rfkill` if it has been soft-blocked by a
  BIOS / hotkey.
- Finds the most recently used saved wifi connection.
- **Waits for that SSID to appear in the scan** (≤ 15s, polled).
- Brings up the connection with `nmcli connection up`.
- **Waits for the device state to reach `connected`** (≤ 15s, polled)
  to verify the link actually came up — `connection up` returning 0
  only means the request was accepted, not that the link is up.

To opt out:

```
sudo rm /etc/mt7921e-fix/auto-connect
```

This is best-effort. With the `wpa_supplicant` kill described above
already in place, NM's normal autoconnect will usually connect
without needing the opt-in at all — the opt-in just helps when
autoconnect is disabled on a specific connection profile, or when
the network is hidden.

### Why these three triggers?

- **`suspend-fix.service` (before `suspend.target`)** — removes the
  misbehaving driver from the kernel so it does not carry broken state into
  the sleep image.
- **`resume-fix.service` (after `suspend.target`)** — reloads the driver
  (and re-associates, if opted in) after the system resumes.
- **`boot-fix.service` (`WantedBy=multi-user.target`,
  `After=systemd-modules-load.service network-pre.target`)** — guarantees
  the same logic runs after a clean cold boot, after the kernel module
  subsystem has settled. Ordering it after `systemd-modules-load.service`
  ensures kmod's autoload queue has already had a chance to load `mt7921e`
  (or try and fail) before we reload it, so our `modprobe` is the last
  word on driver state.

## Installation

Run the following in a terminal:

```
curl -L https://raw.githubusercontent.com/xfork24/ayaneo-air-pro-bazzite-fix/mt7921e_fix/suspend-fix/install.sh | sh
```

The install script will:

1. Clone this repository into `/tmp`.
2. Copy `suspend-mods.sh` and `resume-mods.sh` to `/usr/local/bin/` and make
   them executable.
3. Copy `suspend-fix.service`, `resume-fix.service`, and `boot-fix.service`
   to `/etc/systemd/system/`.
4. Run `systemctl daemon-reload` and enable all three services.
5. Create `/etc/mt7921e-fix/` for the opt-in marker file (the marker itself
   is NOT created — the default is driver-reload-only).
6. On Bazzite, apply the SELinux `chcon` labels required for the helper
   scripts to launch under confined SELinux.
7. Clean up the temporary clone in `/tmp`.

> The install script refuses to run as root. Run it as a normal user with
> `sudo` available — it will prompt for elevation as needed.

## Uninstallation

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

## Files in this directory

- `install.sh` — installer described above
- `suspend-mods.sh` — helper that unloads `mt7921e` (`modprobe -r mt7921e`)
- `resume-mods.sh` — helper that reloads `mt7921e`; in opt-in mode also
  re-associates with the most recently used saved WiFi network. Shared
  by `resume-fix.service` and `boot-fix.service`.
- `suspend-fix.service` — systemd unit, `Type=oneshot`,
  `Before=suspend.target`, `WantedBy=suspend.target`
- `resume-fix.service` — systemd unit, `Type=oneshot`, `After=suspend.target`,
  `WantedBy=suspend.target`
- `boot-fix.service` — systemd unit, `Type=oneshot`, `RemainAfterExit=yes`,
  `After=systemd-modules-load.service network-pre.target`,
  `WantedBy=multi-user.target`
- `README.md` — directory-level notes

## Verifying the install

After installing and rebooting, confirm the driver loaded and the radio
came up cleanly:

```
systemctl is-enabled suspend-fix.service resume-fix.service boot-fix.service
lsmod | grep mt7921e
nmcli radio wifi          # should print "enabled"
journalctl -b -u boot-fix.service
journalctl -b -t mt7921e-fix
```

You should see a `step 1/5 ... step 4/5` sequence in the journal, with
each step reporting the actual state observed (e.g. `step 4d: NM
reports wifi radio = enabled`). If any step times out, the log will
say so explicitly.

Then test a suspend / resume cycle:

```
systemctl suspend
# wake the device
nmcli radio wifi          # should still print "enabled"
journalctl -u suspend-fix.service -u resume-fix.service
journalctl -t mt7921e-fix
```

The default behavior ends at `step 4/5` — you will still need to pick
a network in the applet. If you have created the opt-in marker, the
log will continue with `step 5/5` and the connection attempt.
