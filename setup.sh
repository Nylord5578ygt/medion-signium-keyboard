#!/usr/bin/env bash
set -euo pipefail

# Medion Signium 14 S1 OLED Keyboard Driver Installer
# Installs and configures the custom serio keyboard driver, DKMS auto-rebuild,
# Secure Boot MOK signing (if active), bootloader kernel parameters,
# systemd service, and suspend/resume hook.

PACKAGE_NAME="medion-signium-keyboard"
PACKAGE_VERSION="1.2"

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script requires root privileges." >&2
    echo "Please run: sudo ./setup.sh" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=========================================================="
echo "  Medion Signium 14 S1 Internal Keyboard & Hotkey Setup"
echo "=========================================================="
echo ""

CURRENT_KVER="$(uname -r)"
echo "[1/6] Checking kernel headers, build tools, and DKMS ($CURRENT_KVER)..."

install_deps() {
    if command -v pacman &>/dev/null; then
        echo "--> Detected Arch / CachyOS based distribution."
        local pkgs=("make" "clang" "llvm" "lld" "dkms")
        if [[ "$CURRENT_KVER" == *"cachyos-lts"* ]]; then
            pkgs+=("linux-cachyos-lts-headers")
        elif [[ "$CURRENT_KVER" == *"cachyos"* ]]; then
            pkgs+=("linux-cachyos-headers")
        elif [[ "$CURRENT_KVER" == *"-lts"* ]]; then
            pkgs+=("linux-lts-headers")
        elif [[ "$CURRENT_KVER" == *"-zen"* ]]; then
            pkgs+=("linux-zen-headers")
        elif [[ "$CURRENT_KVER" == *"-hardened"* ]]; then
            pkgs+=("linux-hardened-headers")
        else
            pkgs+=("linux-headers")
        fi
        echo "--> Installing required packages if missing: ${pkgs[*]}"
        pacman -S --needed --noconfirm "${pkgs[@]}" || true
    elif command -v dnf &>/dev/null; then
        echo "--> Detected Fedora / RHEL based distribution."
        dnf install -y kernel-devel make gcc clang dkms || true
    elif command -v apt-get &>/dev/null; then
        echo "--> Detected Debian / Ubuntu based distribution."
        apt-get update -qq || true
        apt-get install -y "linux-headers-$CURRENT_KVER" build-essential dkms || true
    fi
}

if [[ ! -f "/lib/modules/${CURRENT_KVER}/build/Makefile" ]] || ! command -v make &>/dev/null || ! command -v dkms &>/dev/null; then
    echo "--> Installing missing build dependencies or DKMS..."
    install_deps
fi

if [[ ! -f "/lib/modules/${CURRENT_KVER}/build/Makefile" ]]; then
    echo "ERROR: /lib/modules/${CURRENT_KVER}/build/Makefile was not found." >&2
    echo "Please install the kernel headers package matching your running kernel (${CURRENT_KVER})." >&2
    exit 1
fi

echo "[2/6] Configuring bootloader kernel parameters..."
PARAM="i8042.nopnp=1 i8042.direct=1"

# A. Limine bootloader
if [[ -f /etc/default/limine ]]; then
    if grep -q "i8042.nopnp=1" /etc/default/limine; then
        echo "--> Limine: '$PARAM' is already configured."
    else
        echo "--> Limine: Adding '$PARAM'..."
        cp /etc/default/limine /etc/default/limine.bak."$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
        sed -i -E 's/(KERNEL_CMDLINE\[default\]\+?="[^"]*)/\1 i8042.nopnp=1 i8042.direct=1/' /etc/default/limine
    fi
    if command -v limine-update &>/dev/null; then
        echo "--> Running limine-update..."
        limine-update || true
    fi
# B. GRUB bootloader
elif [[ -f /etc/default/grub ]]; then
    if grep -q "i8042.nopnp=1" /etc/default/grub; then
        echo "--> GRUB: '$PARAM' is already configured."
    else
        echo "--> GRUB: Adding '$PARAM'..."
        cp /etc/default/grub /etc/default/grub.bak."$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
        if grep -q "GRUB_CMDLINE_LINUX_DEFAULT" /etc/default/grub; then
            sed -i -E 's/(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*)/\1 i8042.nopnp=1 i8042.direct=1/' /etc/default/grub
        else
            sed -i -E 's/(GRUB_CMDLINE_LINUX="[^"]*)/\1 i8042.nopnp=1 i8042.direct=1/' /etc/default/grub
        fi
    fi
    if command -v update-grub &>/dev/null; then
        update-grub || true
    elif command -v grub-mkconfig &>/dev/null; then
        grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || grub-mkconfig -o /boot/efi/EFI/*/grub.cfg 2>/dev/null || true
    fi
# C. Grubby (Fedora)
elif command -v grubby &>/dev/null; then
    echo "--> Updating kernel parameters via grubby..."
    grubby --update-kernel=ALL --args="$PARAM" --remove-args="i8042.unlock=1" 2>/dev/null || true
fi

# D. systemd-boot / /etc/kernel/cmdline
if [[ -f /etc/kernel/cmdline ]] && ! grep -q "i8042.nopnp=1" /etc/kernel/cmdline; then
    echo "--> Updating /etc/kernel/cmdline..."
    sed -i "s/$/ $PARAM/" /etc/kernel/cmdline
fi

echo "[3/6] Compiling medion_kbd driver (v${PACKAGE_VERSION})..."
make clean &>/dev/null || true
make

if [[ ! -f "$SCRIPT_DIR/medion_kbd.ko" ]]; then
    echo "ERROR: Failed to build medion_kbd.ko." >&2
    exit 1
fi

install -m 755 "$SCRIPT_DIR/sign_module.sh" /usr/local/bin/medion_kbd_sign.sh
if command -v mokutil &>/dev/null && mokutil --sb-state 2>/dev/null | grep -qi "enabled"; then
    echo "--> UEFI Secure Boot is enabled; signing medion_kbd.ko..."
    bash "$SCRIPT_DIR/sign_module.sh" "$SCRIPT_DIR/medion_kbd.ko"
fi

echo "[4/6] Installing driver and registering with DKMS for kernel update persistence..."
# Always install source tree to /usr/src so both DKMS and boot-time self-healing can rebuild on kernel updates
DKMS_SRC="/usr/src/${PACKAGE_NAME}-${PACKAGE_VERSION}"
mkdir -p "$DKMS_SRC"
install -m 644 "$SCRIPT_DIR/medion_kbd.c" "$SCRIPT_DIR/Makefile" "$SCRIPT_DIR/dkms.conf" "$DKMS_SRC/"

# Direct install for the running kernel
EXTRA_DIR="/lib/modules/${CURRENT_KVER}/extra"
mkdir -p "$EXTRA_DIR"
install -m 644 "$SCRIPT_DIR/medion_kbd.ko" "$EXTRA_DIR/medion_kbd.ko"
depmod -a "$CURRENT_KVER"

# Register and build via DKMS for all installed kernels with headers
if command -v dkms &>/dev/null; then
    echo "--> Configuring DKMS (${PACKAGE_NAME}/${PACKAGE_VERSION})..."
    for old_ver in 1.0 1.1 "${PACKAGE_VERSION}"; do
        dkms remove -m "$PACKAGE_NAME" -v "$old_ver" --all 2>/dev/null || true
        if [[ "$old_ver" != "$PACKAGE_VERSION" ]]; then
            rm -rf "/usr/src/${PACKAGE_NAME}-${old_ver}"
        fi
    done
    dkms add -m "$PACKAGE_NAME" -v "$PACKAGE_VERSION"
    for kbuild in /lib/modules/*/build/Makefile; do
        [[ -f "$kbuild" ]] || continue
        kver="$(basename "$(dirname "$(dirname "$kbuild")")")"
        echo "--> Building and installing DKMS module for kernel ${kver}..."
        dkms build -m "$PACKAGE_NAME" -v "$PACKAGE_VERSION" -k "$kver" || true
        dkms install -m "$PACKAGE_NAME" -v "$PACKAGE_VERSION" -k "$kver" --force || true
        if command -v mokutil &>/dev/null && mokutil --sb-state 2>/dev/null | grep -qi "enabled"; then
            if [[ -f "/lib/modules/${kver}/extra/medion_kbd.ko" ]]; then
                KVER="$kver" /usr/local/bin/medion_kbd_sign.sh --sign-only "/lib/modules/${kver}/extra/medion_kbd.ko" || true
            fi
        fi
        depmod -a "$kver" || true
    done
else
    echo "WARNING: dkms command was not found; boot-time self-healing fallback will use $DKMS_SRC." >&2
fi

echo "[5/6] Installing configuration, systemd service, and suspend/resume hook..."
mkdir -p /etc/modprobe.d
install -m 644 "$SCRIPT_DIR/medion_kbd.conf" /etc/modprobe.d/medion_kbd.conf

install -m 755 "$SCRIPT_DIR/load_kbd_module.sh" /usr/local/bin/load_kbd_module.sh

mkdir -p /usr/lib/systemd/system-sleep
install -m 755 "$SCRIPT_DIR/medion_kbd_resume.sh" /usr/lib/systemd/system-sleep/medion_kbd_resume.sh

install -m 644 "$SCRIPT_DIR/medion_kbd.service" /etc/systemd/system/medion_kbd.service
systemctl daemon-reload
systemctl enable medion_kbd.service

echo "[6/6] Activating driver now..."
/usr/local/bin/load_kbd_module.sh --reload || true

CURRENT_DRIVER="$(readlink /sys/bus/serio/devices/serio0/driver 2>/dev/null | xargs basename 2>/dev/null || echo "unknown")"
LOADED_VERSION="$(cat /sys/module/medion_kbd/version 2>/dev/null || echo "not loaded")"
if command -v dkms &>/dev/null && dkms status -m "$PACKAGE_NAME" -v "$PACKAGE_VERSION" 2>/dev/null | grep -q "$PACKAGE_NAME"; then
    DKMS_STATE="Active (auto-rebuilds on kernel updates)"
else
    DKMS_STATE="Fallback only (/usr/src self-healing)"
fi

echo ""
echo "=========================================================="
echo "  INSTALLATION COMPLETED SUCCESSFULLY"
echo "=========================================================="
echo "  - serio0 Active Driver : $CURRENT_DRIVER"
echo "  - medion_kbd Version   : $LOADED_VERSION"
echo "  - DKMS Persistence     : $DKMS_STATE"
echo "  - Boot Service         : medion_kbd.service (Enabled)"
echo "  - Suspend/Resume Hook  : Enabled"
echo "  - Caps Lock LED & Fn   : Enabled"
echo "=========================================================="
echo ""
echo "Your internal keyboard, Caps Lock LED, and Fn media keys should now be active."
echo "A system reboot is recommended if bootloader parameters were added for the first time."
