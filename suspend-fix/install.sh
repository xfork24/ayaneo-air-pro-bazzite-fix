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
echo "  default: state-driven wifi enable on every boot and resume."
echo ""
echo "  the script reloads the driver, then drives the radio through a"
echo "  full off -> on transition. each transition is verified by polling"
echo "  the actual state of NetworkManager and the kernel — no fixed"
echo "  sleeps, no races. the user still picks a network by hand."
echo ""
echo "  to opt into automatic connection to your most recently used"
echo "  saved network (state-driven), run:"
echo ""
echo "    sudo touch /etc/mt7921e-fix/auto-connect"
echo ""
echo "  to opt out, run:"
echo ""
echo "    sudo rm /etc/mt7921e-fix/auto-connect"
echo "================================================================="
