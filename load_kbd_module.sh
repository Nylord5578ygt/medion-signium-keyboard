#!/usr/bin/env bash
# Medion Signium internal keyboard serio0 binding and self-healing loader script
set -euo pipefail

KVER="$(uname -r)"

sign_if_needed() {
    local ko_path="$1"
    if command -v mokutil &>/dev/null && mokutil --sb-state 2>/dev/null | grep -qi "enabled"; then
        if [[ -x /usr/local/bin/medion_kbd_sign.sh && -f /etc/medion-kbd/mok/MOK.priv ]]; then
            KVER="$KVER" /usr/local/bin/medion_kbd_sign.sh --sign-only "$ko_path" || true
        fi
    fi
}

rebuild_for_running_kernel() {
    if command -v dkms &>/dev/null; then
        dkms autoinstall -k "$KVER" &>/dev/null || true
        if [[ -f "/lib/modules/${KVER}/extra/medion_kbd.ko" ]]; then
            sign_if_needed "/lib/modules/${KVER}/extra/medion_kbd.ko"
        elif [[ -f "/lib/modules/${KVER}/extra/medion_kbd.ko.zst" ]] && command -v zstd &>/dev/null; then
            true
        fi
        depmod -a "$KVER" &>/dev/null || true
        if modprobe medion_kbd 2>/dev/null; then
            return 0
        fi
    fi

    local src_dir=""
    for candidate in /usr/src/medion-signium-keyboard-*; do
        if [[ -f "$candidate/medion_kbd.c" && -f "$candidate/Makefile" ]]; then
            src_dir="$candidate"
        fi
    done

    if [[ -n "$src_dir" && -f "/lib/modules/${KVER}/build/Makefile" ]] && command -v make &>/dev/null; then
        local tmp_dir
        tmp_dir="$(mktemp -d)"
        cp "$src_dir/medion_kbd.c" "$src_dir/Makefile" "$tmp_dir/"
        if make -C "$tmp_dir" KVERSION="$KVER" KDIR="/lib/modules/${KVER}/build" all &>/dev/null; then
            mkdir -p "/lib/modules/${KVER}/extra"
            install -m 644 "$tmp_dir/medion_kbd.ko" "/lib/modules/${KVER}/extra/medion_kbd.ko"
            sign_if_needed "/lib/modules/${KVER}/extra/medion_kbd.ko"
            depmod -a "$KVER"
        fi
        rm -rf "$tmp_dir"
    fi
}

if [[ "${1:-}" == "--reload" && -d /sys/module/medion_kbd ]]; then
    modprobe -r medion_kbd || true
fi

if ! modprobe medion_kbd 2>/dev/null; then
    echo "medion_kbd module not found for kernel ${KVER}, attempting automatic rebuild..." >&2
    rebuild_for_running_kernel
    modprobe medion_kbd
fi

SERIO_DIR=/sys/bus/serio/devices/serio0
for _ in {1..25}; do
    [[ -d "$SERIO_DIR" ]] && break
    sleep 0.2
done

if [[ ! -d "$SERIO_DIR" ]]; then
    echo "ERROR: Internal keyboard port serio0 was not found." >&2
    exit 1
fi

if [[ "$(basename "$(readlink "$SERIO_DIR/driver" || true)")" != medion_kbd ]]; then
    printf '%s' none > "$SERIO_DIR/drvctl"
    printf '%s' medion_kbd > "$SERIO_DIR/drvctl"
fi

if [[ "$(basename "$(readlink "$SERIO_DIR/driver" || true)")" != medion_kbd ]]; then
    echo "ERROR: Failed to bind medion_kbd to serio0." >&2
    exit 1
fi
