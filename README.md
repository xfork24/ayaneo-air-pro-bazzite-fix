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

## Default behavior: driver reload + wifi off

By default, the `resume-mods` script does the following on every boot and
resume:

1. Reload `mt7921e`.
2. Wait for a wireless interface to appear (≤ ~10s).
3. **Turn the wifi radio OFF** via `nmcli radio wifi off`. The user
   starts from a known "wifi disabled" state regardless of what the
   radio state was before. NetworkManager's saved connections are
   preserved — they are not deleted — but the radio is disabled until
   the user re-enables it.

The user enables wifi and picks a network by hand. This is the **safe
default** — the script enforces a deterministic post-boot / post-resume
state.

## Opt-in: automatic re-association

The user-reported symptom after a suspend is that the radio is up but
won't auto-connect to a saved network, and a manual "wifi off, wifi on"
is needed to recover. To make the script handle this automatically, create
the marker file:

```
sudo mkdir -p /etc/mt7921e-fix
sudo touch /etc/mt7921e-fix/auto-connect
```

With the marker present, `resume-mods` additionally:

- Enables the wifi radio (it may have been disabled).
- Unblocks the radio if it has been soft-blocked by a BIOS / hotkey.
- Performs up to 3 radio-toggle / rescan / wait cycles, with 2 s between
  off and on, and up to 8 s of waiting for a connection after each.
- As a last resort, brings up the most recently used saved network
  explicitly (covers `autoconnect=false` profiles and hidden SSIDs).

To opt out:

```
sudo rm /etc/mt7921e-fix/auto-connect
```

This is best-effort. On hardware where the driver has a deeper firmware
issue, manual intervention may still be required.

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
is off:

```
systemctl is-enabled suspend-fix.service resume-fix.service boot-fix.service
lsmod | grep mt7921e
nmcli radio wifi          # should print "disabled"
journalctl -b -u boot-fix.service
journalctl -b -t mt7921e-fix
```

Then test a suspend / resume cycle:

```
systemctl suspend
# wake the device
nmcli radio wifi          # should still print "disabled"
journalctl -u suspend-fix.service -u resume-fix.service
journalctl -t mt7921e-fix
```

The default behavior reloads the driver and turns the radio off — you
will need to enable wifi in the applet and pick a network. If you have
created the opt-in marker, the journal will show the re-association
attempts.
