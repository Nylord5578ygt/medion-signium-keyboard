#!/usr/bin/env bash
# Removes the battery-charging-fix GRUB entry and override initrd archives,
# restoring the default boot configuration without modifying original kernel/initrd files.
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script requires root privileges." >&2
    echo "Please run: sudo ./battery-charging-fix/uninstall.sh" >&2
    exit 1
fi

KVER="$(uname -r)"
MARKER="### medion-battery-charging-fix ###"

if [[ -f /etc/default/grub ]]; then
    echo "==> Restoring GRUB_DEFAULT"
    if [[ -f /etc/default/grub.bak-pre-battery-fix ]]; then
        cp /etc/default/grub.bak-pre-battery-fix /etc/default/grub
        echo "Restored /etc/default/grub from backup."
    else
        sed -i '/^GRUB_DEFAULT=/d' /etc/default/grub
        echo 'GRUB_DEFAULT=0' >> /etc/default/grub
    fi
fi

if [[ -f /boot/grub/custom.cfg ]]; then
    echo "==> Removing the custom.cfg entry"
    awk -v marker="$MARKER" '
        $0 == marker {skip=1}
        skip && /^}/ {skip=0; next}
        !skip {print}
    ' /boot/grub/custom.cfg > /boot/grub/custom.cfg.tmp
    mv /boot/grub/custom.cfg.tmp /boot/grub/custom.cfg
fi

echo "==> Removing override initrd files"
rm -f "/boot/initrd.img-${KVER}-battery-fix" /boot/initrd.img-*-battery-fix /boot/acpi_override.cpio

if command -v update-grub &>/dev/null; then
    echo "==> Regenerating grub.cfg"
    update-grub
elif command -v grub-mkconfig &>/dev/null && [[ -f /boot/grub/grub.cfg ]]; then
    echo "==> Regenerating grub.cfg"
    grub-mkconfig -o /boot/grub/grub.cfg
fi

echo "Done. The next boot will use your original DSDT again."
