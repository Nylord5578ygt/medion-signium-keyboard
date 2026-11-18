#!/usr/bin/env bash
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script requires root privileges." >&2
    echo "Please run: sudo ./uninstall.sh" >&2
    exit 1
fi

echo "Uninstalling Medion Signium keyboard driver..."

# 1. Stop and disable the systemd service
systemctl stop medion_kbd.service 2>/dev/null || true
systemctl disable medion_kbd.service 2>/dev/null || true
rm -f /etc/systemd/system/medion_kbd.service
systemctl daemon-reload

# 2. Rebind serio0 back to the default atkbd driver
if [[ -d /sys/bus/serio/devices/serio0 ]]; then
    printf '%s' none > /sys/bus/serio/devices/serio0/drvctl 2>/dev/null || true
    printf '%s' atkbd > /sys/bus/serio/devices/serio0/drvctl 2>/dev/null || true
fi

# 3. Unload the kernel module
modprobe -r medion_kbd 2>/dev/null || true

# 4. Remove installed scripts, configs, and module binaries
rm -f /usr/local/bin/load_kbd_module.sh
rm -f /usr/local/bin/medion_kbd_sign.sh
rm -f /usr/lib/systemd/system-sleep/medion_kbd_resume.sh
rm -f /etc/modprobe.d/medion_kbd.conf
for kdir in /lib/modules/*; do
    [[ -d "$kdir" ]] || continue
    kver="$(basename "$kdir")"
    if [[ -f "$kdir/extra/medion_kbd.ko" || -f "$kdir/extra/medion_kbd.ko.zst" ]]; then
        rm -f "$kdir/extra/medion_kbd.ko" "$kdir/extra/medion_kbd.ko.zst"
        depmod -a "$kver" 2>/dev/null || true
    fi
done

# 5. Remove DKMS registration and source directories
if command -v dkms &>/dev/null; then
    for ver in 1.0 1.1 1.2; do
        dkms remove -m medion-signium-keyboard -v "$ver" --all 2>/dev/null || true
    done
fi
rm -rf /usr/src/medion-signium-keyboard-*

echo "Uninstallation completed."
