This workaround has been modified to load and unload the mt7921e wifi driver on suspend-resume cycles, to reload it on cold boot, and to force NetworkManager to re-associate with a saved WiFi network afterwards. It is meant as a workaround for specific Ayaneo devices.

# What it does

In addition to reloading the driver, the resume / boot path performs the same
sequence a user would do by hand when the radio comes up but won't auto-connect:

1. Loads `mt7921e`.
2. Waits for a wireless interface to appear (≤ ~10s).
3. Unblocks the radio if it has been soft-blocked by a BIOS / hotkey.
4. Waits for NetworkManager to report a stable state (≤ ~15s).
5. Toggles the radio off and back on to reset NM's internal state machine.
6. Triggers a fresh scan so NM's known-networks list is current.
7. As a safety net, brings up the most recently used saved connection
   explicitly — covers profiles with `autoconnect=false` and hidden SSIDs.

The script is best-effort: it exits 0 even when individual steps fail, so
the calling systemd unit never goes into "failed" state.

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
```

# troubleshooting

If WiFi does not auto-associate after a resume or boot, inspect the journal:

```
journalctl -b -u boot-fix.service -u resume-fix.service
journalctl -t mt7921e-fix
```

The script logs the stage of every step (driver reload, interface detection,
rfkill state, NM readiness, radio toggle, scan, explicit connection up) under
the `mt7921e-fix` syslog tag.
