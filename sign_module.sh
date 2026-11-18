#!/usr/bin/env bash
# Signs medion_kbd.ko with a locally-generated MOK key for systems that enforce
# UEFI Secure Boot (unsigned out-of-tree modules are refused by the kernel when
# Secure Boot is active). Not required when Secure Boot is disabled.
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script requires root privileges." >&2
    echo "Please run: sudo ./sign_module.sh" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KVER="${KVER:-$(uname -r)}"
SIGN_ONLY=0
MODULE_PATH=""

for arg in "$@"; do
    case "$arg" in
        --sign-only)
            SIGN_ONLY=1
            ;;
        *)
            MODULE_PATH="$arg"
            ;;
    esac
done

if [[ -z "$MODULE_PATH" ]]; then
    if [[ -f "$SCRIPT_DIR/medion_kbd.ko" ]]; then
        MODULE_PATH="$SCRIPT_DIR/medion_kbd.ko"
    elif [[ -f "/lib/modules/${KVER}/extra/medion_kbd.ko" ]]; then
        MODULE_PATH="/lib/modules/${KVER}/extra/medion_kbd.ko"
    else
        echo "ERROR: medion_kbd.ko was not found. Run 'make' first." >&2
        exit 1
    fi
fi

# 1. Locate sign-file across distribution paths
SIGN_FILE=""
for candidate in \
    "/lib/modules/${KVER}/build/scripts/sign-file" \
    "/usr/src/kernels/${KVER}/scripts/sign-file" \
    "/usr/src/linux-headers-${KVER}/scripts/sign-file"
do
    if [[ -x "$candidate" ]]; then
        SIGN_FILE="$candidate"
        break
    fi
done

if [[ -z "$SIGN_FILE" ]]; then
    echo "ERROR: Could not find 'sign-file' for kernel ${KVER}. Install your kernel headers package." >&2
    exit 1
fi

# 2. Use a persistent directory for MOK keys so kernel upgrades reuse the same enrolled key
MOK_DIR="/etc/medion-kbd/mok"
mkdir -p "$MOK_DIR"
chmod 700 "$MOK_DIR"

if [[ -f "$SCRIPT_DIR/MOK.priv" && -f "$SCRIPT_DIR/MOK.der" && ! -f "$MOK_DIR/MOK.priv" ]]; then
    install -m 600 "$SCRIPT_DIR/MOK.priv" "$MOK_DIR/MOK.priv"
    install -m 644 "$SCRIPT_DIR/MOK.der" "$MOK_DIR/MOK.der"
fi

if [[ ! -f "$MOK_DIR/MOK.priv" || ! -f "$MOK_DIR/MOK.der" ]]; then
    echo "Generating MOK key pair in $MOK_DIR..."
    openssl req -new -x509 -newkey rsa:2048 \
        -keyout "$MOK_DIR/MOK.priv" \
        -outform DER -out "$MOK_DIR/MOK.der" \
        -nodes -days 36500 \
        -subj "/CN=Medion Signium Keyboard MOK/"
    chmod 600 "$MOK_DIR/MOK.priv"
    chmod 644 "$MOK_DIR/MOK.der"
fi

# 3. Sign the module
echo "Signing $MODULE_PATH with $SIGN_FILE..."
"$SIGN_FILE" sha256 "$MOK_DIR/MOK.priv" "$MOK_DIR/MOK.der" "$MODULE_PATH"

if [[ "$SIGN_ONLY" -eq 1 ]]; then
    exit 0
fi

# 4. Enroll the key if mokutil is available and the key is not yet enrolled
if command -v mokutil &>/dev/null; then
    if mokutil --test-key "$MOK_DIR/MOK.der" 2>&1 | grep -q "is enrolled"; then
        echo "MOK key is already enrolled."
    else
        echo "Registering MOK key with mokutil..."
        printf '123456\n123456\n' | mokutil --import "$MOK_DIR/MOK.der"
        echo "MOK registration completed. Temporary enrollment password set to: 123456"
        echo "IMPORTANT: On your next reboot, the blue UEFI MOK Manager screen will appear."
        echo "Select: Enroll MOK -> Continue -> Yes -> Enter password '123456' -> Reboot."
    fi
fi
