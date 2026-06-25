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

On certain Ayaneo / GPD handhelds, the `mt7921e` WiFi driver misbehaves in
two ways:

1. **After a suspend/resume cycle or on a clean cold boot**, the driver
   does not bring the WiFi interface back up reliably. The interface may
   be missing entirely, or it may appear but be stuck in a broken state.
2. **Even after the interface is recognized**, NetworkManager often does
   not auto-associate to a saved WiFi network — the radio is "up" but
   `wpa_supplicant` is in a stale state. Toggling the WiFi radio off and
   on by hand is usually enough to recover, but that is exactly the kind
   of manual step we want to avoid after a suspend.

## The fix

A pair of helper scripts plus three systemd units that unload, reload, and
re-initialize the radio at exactly the right moments:

| Trigger              | Unit                  | Script + action                                                                                                                          |
|----------------------|-----------------------|------------------------------------------------------------------------------------------------------------------------------------------|
| Going to sleep       | `suspend-fix.service` | `suspend-mods` runs `modprobe -r mt7921e` to unload the driver before suspend                                                            |
| Waking from sleep    | `resume-fix.service`  | `resume-mods` reloads the driver, unblocks rfkill, toggles the NM radio, rescans, and brings up the most recently used saved connection |
| Cold boot            | `boot-fix.service`    | same `resume-mods` script — covers the case where the broken state is present on first boot                                              |

`modprobe` on an already-loaded module is a safe no-op, so reloading the
driver at boot is harmless on systems where the autoloader has already done
its job.

### What the resume / boot script does, step by step

1. **Skip cleanly** if the `mt7921e` module is not present in this kernel.
2. **`modprobe mt7921e`** to (re)load the driver.
3. Wait up to ~10s for a wireless interface to appear under `/sys/class/net`
   (its name is whatever udev assigned — do not hard-code `wlan0`).
4. Unblock the radio via `rfkill unblock wifi` if it has been soft-blocked
   by a BIOS / hotkey.
5. Wait up to ~15s for `NetworkManager` to report a stable state — early
   on boot NM may still be initializing.
6. **`nmcli radio wifi off && sleep 1 && nmcli radio wifi on`** to reset
   NM's state machine for the interface. This is the same as toggling the
   radio off and on in the system tray, and is the reliable workaround for
   the post-modprobe "radio up but won't auto-connect" symptom.
7. `nmcli device wifi rescan` to force a fresh scan and refresh the
   known-networks list.
8. As a safety net, if the interface is still disconnected after 5s,
   explicitly `nmcli connection up` the most recently used saved
   connection. This covers connection profiles with `autoconnect=false`
   and hidden SSIDs that scan-based autoconnect cannot pick up.

The script is best-effort: it exits 0 even when individual steps fail, so
the calling systemd unit never goes into "failed" state. Every step is
logged to the journal under the `mt7921e-fix` syslog tag for easy
debugging across boots.

### Why these three triggers?

- **`suspend-fix.service` (before `suspend.target`)** — removes the
  misbehaving driver from the kernel so it does not carry broken state into
  the sleep image.
- **`resume-fix.service` (after `suspend.target`)** — reloads the driver
  and re-associates after the system resumes.
- **`boot-fix.service` (`WantedBy=multi-user.target`,
  `After=systemd-modules-load.service network-pre.target`)** — guarantees
  the same reload + re-association runs after a clean cold boot, after the
  kernel module subsystem has settled. Ordering it after
  `systemd-modules-load.service` ensures kmod's autoload queue has already
  had a chance to load `mt7921e` (or try and fail) before we reload it, so
  our `modprobe` is the last word on driver state.

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
5. On Bazzite, apply the SELinux `chcon` labels required for the helper
   scripts to launch under confined SELinux.
6. Clean up the temporary clone in `/tmp`.

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
```

## Files in this directory

- `install.sh` — installer described above
- `suspend-mods.sh` — helper that unloads `mt7921e` (`modprobe -r mt7921e`)
- `resume-mods.sh` — helper that reloads `mt7921e` and re-associates with
  the most recently used saved WiFi network; shared by `resume-fix.service`
  and `boot-fix.service`
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
re-associated automatically:

```
systemctl is-enabled suspend-fix.service resume-fix.service boot-fix.service
lsmod | grep mt7921e
nmcli -t -f DEVICE,STATE device status | grep -v "^lo:"
journalctl -b -u boot-fix.service
journalctl -b -t mt7921e-fix
```

Then test a suspend / resume cycle:

```
systemctl suspend
# wake the device
journalctl -u suspend-fix.service -u resume-fix.service
nmcli -t -f DEVICE,STATE device status | grep -v "^lo:"
```

If WiFi is still not auto-connecting, the `journalctl -t mt7921e-fix`
output will identify which step failed.
