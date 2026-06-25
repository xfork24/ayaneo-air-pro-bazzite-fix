This workaround has been modified to load and unload the mt7921e wifi driver on suspend-resume cycles, and to reload it on cold boot. It is meant as a workaround for specific Ayaneo devices.

# What it does

By default, this script:

1. Reloads `mt7921e` (`modprobe mt7921e`).
2. Waits for a wireless interface to appear (≤ ~10s).
3. **Turns the wifi radio OFF** via `nmcli radio wifi off`. The user
   starts from a known "wifi disabled" state on every boot and resume
   regardless of what the radio state was before.

# Opt-in: automatic re-association

If the radio toggle / rescan / connect dance works reliably on this
hardware, you can have the script perform it automatically. Create the
marker file:

```
sudo mkdir -p /etc/mt7921e-fix
sudo touch /etc/mt7921e-fix/auto-connect
```

With the marker present, the script additionally:

- Enables the wifi radio (the default would have just turned it off).
- Unblocks the radio if it has been soft-blocked by a BIOS / hotkey.
- Performs up to 3 radio-toggle / rescan / wait cycles, with 2 s between
  off and on, and up to 8 s of waiting for a connection after each.
- As a last resort, brings up the most recently used saved network
  explicitly (covers `autoconnect=false` profiles and hidden SSIDs).

To opt out:

```
sudo rm /etc/mt7921e-fix/auto-connect
```

The opt-in is best-effort. On hardware where the driver has a deeper
firmware issue, manual intervention may still be required. With the
marker absent, the script's only wifi-related action is to ensure the
radio is off.

# Install instructions

run the following in terminal

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

The script logs the stage of every step (driver reload, interface detection,
NM readiness, wifi radio off, radio toggle, scan, explicit connection up)
under the `mt7921e-fix` syslog tag.
