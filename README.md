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

On certain Ayaneo / GPD handhelds, the `mt7921e` WiFi driver misbehaves in two
situations:

1. **After a suspend/resume cycle** — the driver does not bring the WiFi
   interface back up reliably.
2. **On a clean cold boot** — the same broken state is present, so even a
   freshly booted system may not see the WiFi interface.

## The fix

A pair of helper scripts plus three systemd units that unload and reload the
driver at exactly the right moments:

| Trigger              | Unit                  | Runs        | Action                       |
|----------------------|-----------------------|-------------|------------------------------|
| Going to sleep       | `suspend-fix.service` | `suspend-mods` (`modprobe -r mt7921e`) | Unloads the driver before suspend |
| Waking from sleep    | `resume-fix.service`  | `resume-mods` (`modprobe mt7921e`)     | Reloads the driver after wake     |
| Cold boot            | `boot-fix.service`    | `resume-mods` (`modprobe mt7921e`)     | Reloads the driver at boot        |

`modprobe` on an already-loaded module is a safe no-op, so reloading the
driver at boot is harmless on systems where the autoloader has already done
its job.

### Why these three triggers?

- **`suspend-fix.service` (before `suspend.target`)** — removes the
  misbehaving driver from the kernel so it does not carry broken state into
  the sleep image.
- **`resume-fix.service` (after `suspend.target`)** — reloads the driver
  after the system resumes, restoring WiFi.
- **`boot-fix.service` (`WantedBy=multi-user.target`,
  `After=systemd-modules-load.service network-pre.target`)** — guarantees the
  same reload runs after a clean cold boot, after the kernel module subsystem
  has settled. Ordering it after `systemd-modules-load.service` ensures kmod's
  autoload queue has already had a chance to load `mt7921e` (or try and fail)
  before we reload it, so our `modprobe` is the last word on driver state.

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
- `resume-mods.sh` — helper that reloads `mt7921e` (`modprobe mt7921e`),
  shared by `resume-fix.service` and `boot-fix.service`
- `suspend-fix.service` — systemd unit, `Before=suspend.target`,
  `WantedBy=suspend.target`
- `resume-fix.service` — systemd unit, `After=suspend.target`,
  `WantedBy=suspend.target`
- `boot-fix.service` — systemd unit, `Type=oneshot`, `RemainAfterExit=yes`,
  `After=systemd-modules-load.service network-pre.target`,
  `WantedBy=multi-user.target`
- `README.md` — directory-level notes

## Verifying the install

After installing and rebooting:

```
systemctl is-enabled suspend-fix.service resume-fix.service boot-fix.service
lsmod | grep mt7921e
journalctl -b -u boot-fix.service
```

Then test a suspend/resume cycle:

```
systemctl suspend
# wake the device
journalctl -u suspend-fix.service -u resume-fix.service
```
