#!/usr/bin/env bash
# Fixes BAT0._BST always reporting "Discharging" on the Medion Signium 14 S1 OLED
# (board NM14RPL) by patching a copy of the DSDT and loading it as an
# ACPI table override via the initrd (Documentation/admin-guide/acpi/initrd_table_override.rst).
#
# Safety model: on GRUB systems this builds a separate test menu entry first
# without modifying your default boot entry. Once verified, promote it with --make-default.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="/root/medion-battery-fix-build"
KVER="$(uname -r)"
ENTRY_TITLE="MEDION 14 S1 OLED (battery charging fix)"
MARKER="### medion-battery-charging-fix ###"

MAKE_DEFAULT=0
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --make-default) MAKE_DEFAULT=1 ;;
        --force) FORCE=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script requires root privileges." >&2
    echo "Please run: sudo ./battery-charging-fix/install.sh" >&2
    exit 1
fi

BOARD="$(cat /sys/class/dmi/id/board_name 2>/dev/null || true)"
if [[ "$BOARD" != "NM14RPL" && "$FORCE" -ne 1 ]]; then
    echo "This fix targets board NM14RPL (Medion Signium 14 S1 OLED)." >&2
    echo "Detected board: '${BOARD:-unknown}'. Refusing to continue." >&2
    echo "If you have verified the same DSDT bug on your board, re-run with --force." >&2
    exit 1
fi

install_acpi_deps() {
    if command -v pacman &>/dev/null; then
        pacman -S --needed --noconfirm acpica cpio || true
    elif command -v dnf &>/dev/null; then
        dnf install -y acpica-tools cpio || true
    elif command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y acpica-tools cpio || true
    fi
}

if ! command -v iasl &>/dev/null || ! command -v cpio &>/dev/null; then
    echo "==> Installing acpica-tools (iasl) and cpio..."
    install_acpi_deps
fi

rm -rf "$WORK"
mkdir -p "$WORK"

echo "==> Dumping the live DSDT"
cp /sys/firmware/acpi/tables/DSDT "$WORK/dsdt.dat"

echo "==> Disassembling DSDT"
(cd "$WORK" && iasl -d dsdt.dat >/dev/null)

echo "==> Applying the BAT0._BST charging-state patch"
python3 "$DIR/patch_bst.py" "$WORK/dsdt.dsl"

echo "==> Recompiling DSDT"
(cd "$WORK" && iasl -tc dsdt.dsl)
if [[ ! -f "$WORK/dsdt.aml" ]]; then
    echo "ERROR: DSDT compilation failed, aborting." >&2
    exit 1
fi

echo "==> Building the ACPI table override cpio archive"
rm -rf "$WORK/override"
mkdir -p "$WORK/override/kernel/firmware/acpi"
cp "$WORK/dsdt.aml" "$WORK/override/kernel/firmware/acpi/dsdt.aml"
(cd "$WORK/override" && find kernel | cpio -H newc --create > "$WORK/acpi_override.cpio")
install -m 644 "$WORK/acpi_override.cpio" /boot/acpi_override.cpio

ORIG_INITRD=""
for candidate in \
    "/boot/initrd.img-${KVER}" \
    "/boot/initramfs-${KVER}.img" \
    "/boot/initramfs-linux-cachyos.img" \
    "/boot/initramfs-linux.img"
do
    if [[ -f "$candidate" ]]; then
        ORIG_INITRD="$candidate"
        break
    fi
done

if [[ -n "$ORIG_INITRD" && -d /boot/grub ]]; then
    NEW_INITRD="/boot/initrd.img-${KVER}-battery-fix"
    cat "$WORK/acpi_override.cpio" "$ORIG_INITRD" > "$NEW_INITRD"
    chmod 644 "$NEW_INITRD"

    VMLINUZ="/boot/vmlinuz-${KVER}"
    if [[ ! -f "$VMLINUZ" ]]; then
        for v in /boot/vmlinuz-linux-cachyos /boot/vmlinuz-linux; do
            [[ -f "$v" ]] && VMLINUZ="$v" && break
        done
    fi

    echo "==> Writing the GRUB test entry (/boot/grub/custom.cfg)"
    ROOTUUID="$(findmnt -n -o UUID /)"
    BOOT_PARAMS="$(sed -E 's/^BOOT_IMAGE=\S+\s*//; s/\s*root=\S+\s*//' /proc/cmdline)"

    touch /boot/grub/custom.cfg
    if ! grep -q "$MARKER" /boot/grub/custom.cfg; then
        cat >> /boot/grub/custom.cfg <<EOF

$MARKER
menuentry '${ENTRY_TITLE}' {
    load_video
    insmod gzio
    insmod part_gpt
    insmod ext2
    linux ${VMLINUZ} root=UUID=${ROOTUUID} ${BOOT_PARAMS}
    initrd ${NEW_INITRD}
}
EOF
    fi

    echo "==> Regenerating grub.cfg"
    if command -v update-grub &>/dev/null; then
        update-grub
    elif command -v grub-mkconfig &>/dev/null; then
        grub-mkconfig -o /boot/grub/grub.cfg
    fi

    if [[ "$MAKE_DEFAULT" -eq 1 && -f /etc/default/grub ]]; then
        echo "==> Setting '${ENTRY_TITLE}' as the default boot entry"
        cp -n /etc/default/grub /etc/default/grub.bak-pre-battery-fix || true
        if grep -q '^GRUB_DEFAULT=' /etc/default/grub; then
            sed -i "s|^GRUB_DEFAULT=.*|GRUB_DEFAULT=\"${ENTRY_TITLE}\"|" /etc/default/grub
        else
            echo "GRUB_DEFAULT=\"${ENTRY_TITLE}\"" >> /etc/default/grub
        fi
        if command -v update-grub &>/dev/null; then
            update-grub
        elif command -v grub-mkconfig &>/dev/null; then
            grub-mkconfig -o /boot/grub/grub.cfg
        fi
        echo "Done. The system will boot into the battery fix entry by default."
    else
        echo ""
        echo "Done. Reboot and manually select '${ENTRY_TITLE}' from the GRUB menu"
        echo "to test it (your normal entry is untouched and remains default)."
        echo ""
        echo "Once you have confirmed 'cat /sys/class/power_supply/BAT0/status' reports"
        echo "Charging while plugged in, make it permanent with:"
        echo "  sudo bash $DIR/install.sh --make-default"
    fi
else
    echo ""
    echo "Done. The ACPI override archive has been written to: /boot/acpi_override.cpio"
    echo "Load /boot/acpi_override.cpio before your main initramfs image in your bootloader"
    echo "(e.g. Limine or systemd-boot) to apply the patched DSDT at boot."
fi
