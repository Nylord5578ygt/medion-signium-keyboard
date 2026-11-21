# Medion Signium 14 S1 OLED Linux Keyboard Driver

Custom Linux `serio` kernel driver, automated DKMS installer, Fn hotkey handler, and Caps Lock LED support for the **Medion Signium 14 S1 OLED** (board `NM14RPL`, Tongfang/Clevo barebone, and compatible laptops using the `INTC816` / non-standard AT Set 1 embedded controller interface).

This repository extends [`MrElmida/medion-signium-keyboard`](https://github.com/MrElmida/medion-signium-keyboard) into a complete, self-healing keyboard driver package.

## Overview of the Hardware Issues

Out of the box on Linux distributions (Arch Linux, CachyOS, Fedora, Ubuntu, Debian, etc.), the built-in keyboard on the Medion Signium 14 S1 OLED does not work properly with the standard `atkbd` driver due to several embedded controller (EC) firmware quirks:

1. **Non-standard scancode translation:** The EC emits a custom AT Set 1 layout that causes the standard `atkbd` driver to misinterpret or ignore keystrokes.
2. **Inverted modifier state:** Non-escaped `Right Alt` (`AltGr`) sends inverted make/break bytes (`0xb8` on press and `0x38` on release), sharing codes with `Left Alt`.
3. **ACPI port deactivation:** Without `i8042.nopnp=1 i8042.direct=1`, ACPI initialization can leave `serio0` inactive.
4. **Missing Caps Lock LED and Fn hotkeys:** Without explicit `EV_LED` (`0xed` `SETLEDS`) handling and extended scancode mappings, the Caps Lock indicator LED never lights up and multimedia/Fn keys (`Mute`, `Volume Down`, `Volume Up`, `Touchpad Toggle`, `Sleep`, etc.) do not function.

## Key Features

- **Full keyboard and modifier support:** Accurately decodes standard typing keys, function keys (`F1` through `F12`), arrow/navigation keys, and the inverted `Right Alt` (`AltGr`) state machine.
- **Caps Lock, Num Lock, and Scroll Lock LED support:** Implements `EV_LED` (`LED_CAPSL`, `LED_NUML`, `LED_SCROLLL`) using the PS/2 `0xed` (`SETLEDS`) command over `serio0`, filtering controller `0xfa`/`0xfe` responses and re-synchronizing LED state on connect and resume.
- **Fn multimedia and touchpad hotkeys:** Supports `Mute`, `Volume Down`, `Volume Up`, `Play/Pause`, `Next/Previous Track`, `Stop`, `Sleep`, and configurable `Touchpad Toggle` (`touchpad_scancode=0x76` by default for `Fn+F1`).
- **Raw scan code reporting (`MSC_SCAN`):** Exposes raw scan codes and an optional `debug_unknown=1` module parameter for diagnosing unmapped hotkeys without unbinding the driver.
- **Kernel update survival (DKMS + boot-time self-healing):** Installs `dkms`, registers the module across all installed kernel trees, and includes a boot-time fallback in `load_kbd_module.sh` that automatically rebuilds and loads the module if a kernel upgrade occurs without a prior DKMS build.
- **Automatic Clang/LLVM and GCC detection:** Detects whether the target kernel was compiled with Clang/LLVM (such as CachyOS) or GCC and passes `LLVM=1` automatically.
- **UEFI Secure Boot support:** Automatically signs the module via `sign_module.sh` when Secure Boot is enabled, storing MOK keys persistently in `/etc/medion-kbd/mok` so kernel upgrades can re-sign automatically without re-enrolling a new key.
- **Suspend/resume recovery:** Installs a `systemd-sleep` hook (`medion_kbd_resume.sh`) so the keyboard and LEDs recover cleanly after waking from sleep or hibernation.

## Quick Installation

1. Enter the repository directory:
   ```bash
   cd medion-signium-keyboard-fix
   ```

2. Run the automated setup script as root:
   ```bash
   sudo ./setup.sh
   ```

3. Your internal keyboard, Caps Lock LED, and Fn hotkeys will be activated immediately. If bootloader kernel parameters (`i8042.nopnp=1 i8042.direct=1`) were added for the first time, reboot once so they take full effect.

## What `setup.sh` Does

1. **Dependency and DKMS installation:** Installs missing build tools (`make`, `gcc`/`clang`), matching kernel headers (`linux-headers`, `linux-cachyos-headers`, `kernel-devel`, etc.), and `dkms` using `pacman`, `dnf`, or `apt-get`.
2. **Bootloader configuration:** Detects Limine (`/etc/default/limine`), GRUB (`/etc/default/grub`), `grubby`, or `systemd-boot` (`/etc/kernel/cmdline`) and ensures `i8042.nopnp=1 i8042.direct=1` is present in the kernel command line.
3. **Module compilation and Secure Boot signing:** Builds `medion_kbd.ko` (v1.2) using the toolchain matching your kernel, and signs it with a local MOK key if UEFI Secure Boot is enabled.
4. **DKMS registration across installed kernels:** Copies the driver source to `/usr/src/medion-signium-keyboard-1.2` and builds/installs the DKMS module for every installed kernel tree on the system.
5. **Service and sleep hooks:** Installs `/etc/modprobe.d/medion_kbd.conf`, `/usr/local/bin/load_kbd_module.sh`, `/usr/local/bin/medion_kbd_sign.sh`, `/usr/lib/systemd/system-sleep/medion_kbd_resume.sh`, and enables `medion_kbd.service`.
6. **Immediate activation:** Reloads `medion_kbd` and binds it to `serio0` without requiring a reboot first.

## UEFI Secure Boot Signing

If UEFI Secure Boot is enabled on your system, `setup.sh` automatically runs `sign_module.sh` (or you can invoke `sudo ./sign_module.sh` manually). On the first run, it generates a local Machine Owner Key (MOK) pair in `/etc/medion-kbd/mok`, signs `medion_kbd.ko`, and queues the key for enrollment via `mokutil` with the temporary password `123456`. On the next reboot, select **Enroll MOK -> Continue -> Yes**, enter `123456`, and reboot.

## Testing and Diagnostics

### Run the Scancode and LED Unit Tests

To verify the driver's scancode translation, `Right Alt` state tracking, touchpad override, and Caps Lock LED `0xed` protocol handling in userspace:

```bash
python3 tests/test_scancodes.py
```

### Monitor Function Keys and Hotkeys Live

To inspect `F1`-`F12`, media hotkeys, and any unmapped scan codes in real time without grabbing the keyboard or recording normal typing:

```bash
sudo python3 watch_hotkeys.py --seconds 60
```

## Uninstallation

To remove the keyboard driver, systemd service, sleep hook, modprobe configuration, and DKMS registration, and rebind `serio0` back to `atkbd`:

```bash
sudo ./uninstall.sh
```

## License and Credits

- Licensed under the GNU General Public License v2.0 (see [LICENSE](LICENSE)).
- Based on the original [`MrElmida/medion-signium-keyboard`](https://github.com/MrElmida/medion-signium-keyboard) driver, with PS/2 `SETLEDS` Caps Lock LED control inspired by [`bolado-dev/medion-14-s1-oled-linux`](https://github.com/bolado-dev/medion-14-s1-oled-linux).
