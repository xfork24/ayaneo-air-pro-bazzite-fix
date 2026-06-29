#!/usr/bin/bash

if [ "$(id -u)" -eq 0 ]; then
    echo "This script must not be run as root. don't use sudo" >&2
    exit 1
fi

echo "starting install of mt7921e fix"

# remove if somehow already present
sudo rm -rf /tmp/ayaneo-air-pro-bazzite-fix

cd /tmp

git clone -b mt7921e_fix --single-branch https://github.com/xfork24/ayaneo-air-pro-bazzite-fix.git

cd ayaneo-air-pro-bazzite-fix/suspend-fix

sudo cp ./suspend-mods.sh /usr/local/bin/suspend-mods
sudo cp ./resume-mods.sh /usr/local/bin/resume-mods

sudo chmod +x /usr/local/bin/suspend-mods
sudo chmod +x /usr/local/bin/resume-mods

# disable services if they already exist
sudo systemctl disable --now resume-fix.service
sudo systemctl disable --now suspend-fix.service
sudo systemctl disable --now boot-fix.service

sudo cp resume-fix.service /etc/systemd/system
sudo cp suspend-fix.service /etc/systemd/system
sudo cp boot-fix.service /etc/systemd/system

sudo systemctl daemon-reload
sudo systemctl enable resume-fix.service
sudo systemctl enable suspend-fix.service
sudo systemctl enable boot-fix.service

echo "installation complete!"

sudo rm -rf /tmp/ayaneo-air-pro-bazzite-fix

# Prepare directory for the opt-in auto-connect marker. The directory is
# created, but the marker file is NOT created — the default behavior is
# to only reload the driver and leave the wifi radio state untouched.
sudo mkdir -p /etc/mt7921e-fix

# bazzite only

sudo chcon -u system_u -r object_r --type=bin_t /usr/local/bin/suspend-mods
sudo chcon -u system_u -r object_r --type=bin_t /usr/local/bin/resume-mods

echo ""
echo "================================================================="
echo "  on boot: a minimal script (boot-mods.sh) just activates the"
echo "  mt7921e driver. ~1 second. no radio toggle, no daemon reset,"
echo "  no auto-connect."
echo ""
echo "  on resume from suspend: resume-mods.sh does a full state-driven"
echo "  radio toggle (off → on) and resets the wifi daemon (iwd or"
echo "  wpa_supplicant) to clear stale state. The user picks a network"
echo "  by hand after resume."
echo ""
echo "  to opt into automatic connection to your most recently used"
echo "  saved network on resume (state-driven), run:"
echo ""
echo "    sudo touch /etc/mt7921e-fix/auto-connect"
echo ""
echo "  to opt out, run:"
echo ""
echo "    sudo rm /etc/mt7921e-fix/auto-connect"
echo "================================================================="
