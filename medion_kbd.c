// SPDX-License-Identifier: GPL-2.0
/*
 * Custom Linux serio driver for the internal keyboard of the Medion Signium
 * 14 S1 OLED (board NM14RPL, Tongfang/Clevo barebone).
 *
 * Addresses the following hardware/EC firmware quirks on Linux:
 * - Non-standard AT Set 1 scancode translation
 * - Inverted Right Alt (AltGr) make/break state tracking
 * - Fn multimedia, sleep, and configurable touchpad toggle hotkeys
 * - Caps/Num/Scroll Lock indicator LED control via PS/2 0xED (SETLEDS)
 *
 * Based on https://github.com/MrElmida/medion-signium-keyboard and
 * LED handling from https://github.com/bolado-dev/medion-14-s1-oled-linux.
 */
#include <linux/init.h>
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/bitops.h>
#include <linux/serio.h>
#include <linux/input.h>
#include <linux/slab.h>

#define MEDION_KBD_CMD_SETLEDS	0xed
#define MEDION_KBD_RET_ACK	0xfa
#define MEDION_KBD_RET_NAK	0xfe

/* Optional model-specific touchpad make code, e.g. 0x76 or 0xe076. */
static unsigned short touchpad_scancode;
module_param(touchpad_scancode, ushort, 0644);
MODULE_PARM_DESC(touchpad_scancode, "Touchpad toggle make code (0 disables override; E0 prefix encoded as 0xe000)");

static bool debug_unknown;
module_param(debug_unknown, bool, 0644);
MODULE_PARM_DESC(debug_unknown, "Log unmapped scan codes for hotkey diagnosis");

struct medion_kbd {
	struct serio *serio;
	struct input_dev *dev;
	bool is_escaped;
	bool left_alt_pressed;
	bool right_alt_pressed;
	bool capslock;
	bool numlock;
	bool scrolllock;
};

static unsigned short medion_kbd_translate_normal(unsigned char scancode) {
	switch (scancode) {
		case 0x01: return KEY_ESC;
		case 0x02: return KEY_1;
		case 0x03: return KEY_2;
		case 0x04: return KEY_3;
		case 0x05: return KEY_4;
		case 0x06: return KEY_5;
		case 0x07: return KEY_6;
		case 0x08: return KEY_7;
		case 0x09: return KEY_8;
		case 0x0a: return KEY_9;
		case 0x0b: return KEY_0;
		case 0x0c: return KEY_MINUS;
		case 0x0d: return KEY_EQUAL;
		case 0x0e: return KEY_BACKSPACE;
		case 0x0f: return KEY_TAB;
		case 0x10: return KEY_Q;
		case 0x11: return KEY_W;
		case 0x12: return KEY_E;
		case 0x13: return KEY_R;
		case 0x14: return KEY_T;
		case 0x15: return KEY_Y;
		case 0x16: return KEY_U;
		case 0x17: return KEY_I;
		case 0x18: return KEY_O;
		case 0x19: return KEY_P;
		case 0x1a: return KEY_LEFTBRACE;
		case 0x1b: return KEY_RIGHTBRACE;
		case 0x1c: return KEY_ENTER;
		case 0x1d: return KEY_LEFTCTRL;
		case 0x1e: return KEY_A;
		case 0x1f: return KEY_S;
		case 0x20: return KEY_D;
		case 0x21: return KEY_F;
		case 0x22: return KEY_G;
		case 0x23: return KEY_H;
		case 0x24: return KEY_J;
		case 0x25: return KEY_K;
		case 0x26: return KEY_L;
		case 0x27: return KEY_SEMICOLON;
		case 0x28: return KEY_APOSTROPHE;
		case 0x29: return KEY_GRAVE;
		case 0x2a: return KEY_LEFTSHIFT;
		case 0x2b: return KEY_BACKSLASH;
		case 0x2c: return KEY_Z;
		case 0x2d: return KEY_X;
		case 0x2e: return KEY_C;
		case 0x2f: return KEY_V;
		case 0x30: return KEY_B;
		case 0x31: return KEY_N;
		case 0x32: return KEY_M;
		case 0x33: return KEY_COMMA;
		case 0x34: return KEY_DOT;
		case 0x35: return KEY_SLASH;
		case 0x36: return KEY_RIGHTSHIFT;
		case 0x39: return KEY_SPACE;
		case 0x3a: return KEY_CAPSLOCK;
		case 0x3b: return KEY_F1;
		case 0x3c: return KEY_F2;
		case 0x3d: return KEY_F3;
		case 0x3e: return KEY_F4;
		case 0x3f: return KEY_F5;
		case 0x40: return KEY_F6;
		case 0x41: return KEY_F7;
		case 0x42: return KEY_F8;
		case 0x43: return KEY_F9;
		case 0x44: return KEY_F10;
		case 0x56: return KEY_102ND;
		case 0x57: return KEY_F11;
		case 0x58: return KEY_F12;
		default: return KEY_RESERVED;
	}
}

static unsigned short medion_kbd_translate_escaped(unsigned char scancode) {
	switch (scancode) {
		/* Standard PS/2 Set 1 multimedia and sleep make codes. */
		case 0x10: return KEY_PREVIOUSSONG;
		case 0x19: return KEY_NEXTSONG;
		case 0x1c: return KEY_KPENTER;
		case 0x1d: return KEY_RIGHTCTRL;
		case 0x20: return KEY_MUTE;
		case 0x22: return KEY_PLAYPAUSE;
		case 0x24: return KEY_STOPCD;
		case 0x2e: return KEY_VOLUMEDOWN;
		case 0x30: return KEY_VOLUMEUP;
		case 0x35: return KEY_KPSLASH;
		case 0x37: return KEY_SYSRQ;
		case 0x38: return KEY_RIGHTALT;
		case 0x47: return KEY_HOME;
		case 0x49: return KEY_PAGEUP;
		case 0x4f: return KEY_END;
		case 0x51: return KEY_PAGEDOWN;
		case 0x52: return KEY_INSERT;
		case 0x5b: return KEY_LEFTMETA;
		case 0x5c: return KEY_RIGHTMETA;
		case 0x5d: return KEY_MENU;
		case 0x5f: return KEY_SLEEP;
		default: return KEY_RESERVED;
	}
}

static irqreturn_t medion_kbd_interrupt(struct serio *serio, unsigned char data, unsigned int flags) {
	struct medion_kbd *kbd = serio_get_drvdata(serio);
	if (!kbd)
		return IRQ_HANDLED;

	if (data == MEDION_KBD_RET_ACK || data == MEDION_KBD_RET_NAK)
		return IRQ_HANDLED;

	if (data == 0xe0) {
		kbd->is_escaped = true;
		return IRQ_HANDLED;
	}

	bool escaped = kbd->is_escaped;
	kbd->is_escaped = false;

	unsigned short keycode = KEY_RESERVED;
	unsigned short scancode = (escaped ? 0xe000 : 0) | (data & 0x7f);
	bool down = true;

	if (escaped) {
		switch (data) {
			/* Left Arrow (Standard) */
			case 0x4b: keycode = KEY_LEFT; down = true; break;
			case 0xcb: keycode = KEY_LEFT; down = false; break;

			/* Delete (Standard) */
			case 0x53: keycode = KEY_DELETE; down = true; break;
			case 0xd3: keycode = KEY_DELETE; down = false; break;

			/* Left Meta (Windows Key) */
			case 0x5b: keycode = KEY_LEFTMETA; down = true; break;
			case 0xdb: keycode = KEY_LEFTMETA; down = false; break;

			/* Up Arrow (Standard) */
			case 0x48: keycode = KEY_UP; down = true; break;
			case 0xc8: keycode = KEY_UP; down = false; break;

			/* Down Arrow (Standard) */
			case 0x50: keycode = KEY_DOWN; down = true; break;
			case 0xd0: keycode = KEY_DOWN; down = false; break;

			/* Right Arrow (Standard) */
			case 0x4d: keycode = KEY_RIGHT; down = true; break;
			case 0xcd: keycode = KEY_RIGHT; down = false; break;

			default:
				down = !(data & 0x80);
				keycode = medion_kbd_translate_escaped(data & 0x7f);
				break;
		}
	} else {
		/* Non-escaped */
		switch (data) {
			/* Left Alt & Right Alt state tracking (Right Alt is inverted and shares codes) */
			case 0x38:
				if (kbd->right_alt_pressed) {
					/* Right Alt Release (sends 0x38) */
					kbd->right_alt_pressed = false;
					keycode = KEY_RIGHTALT;
					down = false;
				} else {
					/* Left Alt Press (sends 0x38) */
					kbd->left_alt_pressed = true;
					keycode = KEY_LEFTALT;
					down = true;
				}
				break;

			case 0xb8:
				if (kbd->left_alt_pressed) {
					/* Left Alt Release (sends 0xb8) */
					kbd->left_alt_pressed = false;
					keycode = KEY_LEFTALT;
					down = false;
				} else {
					/* Right Alt Press (sends 0xb8) */
					kbd->right_alt_pressed = true;
					keycode = KEY_RIGHTALT;
					down = true;
				}
				break;

			default:
				down = !(data & 0x80);
				keycode = medion_kbd_translate_normal(data & 0x7f);
				break;
		}
	}

	if (touchpad_scancode && scancode == touchpad_scancode) {
		keycode = KEY_TOUCHPAD_TOGGLE;
		down = !(data & 0x80);
	}

	/* Expose unmapped scan codes so diagnosis does not require unbinding the driver. */
	input_event(kbd->dev, EV_MSC, MSC_SCAN, scancode);
	if (keycode != KEY_RESERVED) {
		input_report_key(kbd->dev, keycode, down);
	} else if (debug_unknown) {
		pr_info_ratelimited("medion_kbd: unmapped scancode=0x%04x %s (byte=0x%02x)\n",
				    scancode, down ? "press" : "release", data);
	}
	input_sync(kbd->dev);

	return IRQ_HANDLED;
}

static void medion_kbd_write_leds(struct medion_kbd *kbd, unsigned char leds) {
	if (!kbd || !kbd->serio)
		return;
	serio_write(kbd->serio, MEDION_KBD_CMD_SETLEDS);
	serio_write(kbd->serio, leds);
}

static unsigned char medion_kbd_get_led_mask(struct input_dev *dev,
					     unsigned int override_code,
					     int override_value) {
	bool scrolll = test_bit(LED_SCROLLL, dev->led);
	bool numl = test_bit(LED_NUML, dev->led);
	bool capsl = test_bit(LED_CAPSL, dev->led);

	if (override_code == LED_SCROLLL)
		scrolll = !!override_value;
	else if (override_code == LED_NUML)
		numl = !!override_value;
	else if (override_code == LED_CAPSL)
		capsl = !!override_value;

	return (scrolll ? 0x01 : 0x00) |
	       (numl ? 0x02 : 0x00) |
	       (capsl ? 0x04 : 0x00);
}

/*
 * Forward Caps/Num/Scroll Lock LED state to the EC using the standard
 * AT keyboard SETLEDS command (0xED + bitmask).
 */
static int medion_kbd_event(struct input_dev *dev, unsigned int type,
			    unsigned int code, int value) {
	struct medion_kbd *kbd = input_get_drvdata(dev);
	unsigned char leds;

	if (type != EV_LED || !kbd)
		return -1;

	switch (code) {
		case LED_CAPSL:
			kbd->capslock = !!value;
			break;
		case LED_NUML:
			kbd->numlock = !!value;
			break;
		case LED_SCROLLL:
			kbd->scrolllock = !!value;
			break;
		default:
			return -1;
	}

	leds = medion_kbd_get_led_mask(dev, code, value);
	medion_kbd_write_leds(kbd, leds);
	return 0;
}

static int medion_kbd_connect(struct serio *serio, struct serio_driver *drv) {
	struct medion_kbd *kbd;
	struct input_dev *input_dev;
	int err, i;
	unsigned short keycode;
	static const unsigned short extra_keys[] = {
		KEY_LEFTALT, KEY_RIGHTALT, KEY_LEFT, KEY_RIGHT,
		KEY_UP, KEY_DOWN, KEY_DELETE, KEY_TOUCHPAD_TOGGLE,
	};

	kbd = kzalloc(sizeof(struct medion_kbd), GFP_KERNEL);
	input_dev = input_allocate_device();
	if (!kbd || !input_dev) {
		err = -ENOMEM;
		goto fail1;
	}

	kbd->serio = serio;
	kbd->dev = input_dev;
	input_set_drvdata(input_dev, kbd);

	input_dev->name = "Medion Signium Custom Keyboard";
	input_dev->phys = "serio0/input0";
	input_dev->id.bustype = BUS_I8042;
	input_dev->id.vendor = 0x0001;
	input_dev->id.product = 0x0001;
	input_dev->id.version = 0x0100;

	/* Set input device capabilities */
	__set_bit(EV_KEY, input_dev->evbit);
	__set_bit(EV_REP, input_dev->evbit);
	__set_bit(EV_LED, input_dev->evbit);
	__set_bit(LED_CAPSL, input_dev->ledbit);
	__set_bit(LED_NUML, input_dev->ledbit);
	__set_bit(LED_SCROLLL, input_dev->ledbit);
	input_dev->event = medion_kbd_event;
	input_set_capability(input_dev, EV_MSC, MSC_SCAN);

	/* Advertise the keys we can emit, without claiming mouse buttons. */
	for (i = 0; i < 128; i++) {
		keycode = medion_kbd_translate_normal(i);
		if (keycode != KEY_RESERVED)
			input_set_capability(input_dev, EV_KEY, keycode);
		keycode = medion_kbd_translate_escaped(i);
		if (keycode != KEY_RESERVED)
			input_set_capability(input_dev, EV_KEY, keycode);
	}
	for (i = 0; i < ARRAY_SIZE(extra_keys); i++)
		input_set_capability(input_dev, EV_KEY, extra_keys[i]);

	serio_set_drvdata(serio, kbd);

	err = serio_open(serio, drv);
	if (err)
		goto fail2;

	err = input_register_device(kbd->dev);
	if (err)
		goto fail3;

	medion_kbd_write_leds(kbd, medion_kbd_get_led_mask(kbd->dev, LED_CNT, 0));

	pr_info("medion_kbd: Connected to serio port\n");
	return 0;

fail3:
	serio_close(serio);
fail2:
	serio_set_drvdata(serio, NULL);
fail1:
	input_free_device(input_dev);
	kfree(kbd);
	return err;
}

static void medion_kbd_disconnect(struct serio *serio) {
	struct medion_kbd *kbd = serio_get_drvdata(serio);
	if (kbd) {
		serio_close(serio);
		input_unregister_device(kbd->dev);
		serio_set_drvdata(serio, NULL);
		kfree(kbd);
	}
	pr_info("medion_kbd: Disconnected from serio port\n");
}

static const struct serio_device_id medion_kbd_serio_ids[] = {
	{
		.type	= SERIO_8042,
		.proto	= SERIO_ANY,
		.extra	= SERIO_ANY,
		.id	= SERIO_ANY,
	},
	{ 0 }
};
MODULE_DEVICE_TABLE(serio, medion_kbd_serio_ids);

static int medion_kbd_reconnect(struct serio *serio) {
	struct medion_kbd *kbd = serio_get_drvdata(serio);
	if (kbd) {
		kbd->is_escaped = false;
		kbd->left_alt_pressed = false;
		kbd->right_alt_pressed = false;
		if (kbd->dev)
			medion_kbd_write_leds(kbd, medion_kbd_get_led_mask(kbd->dev, LED_CNT, 0));
	}
	return 0;
}

static struct serio_driver medion_kbd_driver = {
	.driver		= {
		.name	= "medion_kbd",
	},
	.description	= "Medion Signium Custom Keyboard Driver",
	.id_table	= medion_kbd_serio_ids,
	.interrupt	= medion_kbd_interrupt,
	.connect	= medion_kbd_connect,
	.reconnect	= medion_kbd_reconnect,
	.fast_reconnect	= medion_kbd_reconnect,
	.disconnect	= medion_kbd_disconnect,
};

static int __init medion_kbd_init(void) {
	return serio_register_driver(&medion_kbd_driver);
}

static void __exit medion_kbd_exit(void) {
	serio_unregister_driver(&medion_kbd_driver);
}

module_init(medion_kbd_init);
module_exit(medion_kbd_exit);

MODULE_LICENSE("GPL");
MODULE_VERSION("1.2");
MODULE_AUTHOR("mrelmida, Alejandro Bolado, Nylord5578ygt");
MODULE_DESCRIPTION("Medion Signium Custom Keyboard Driver with Fn Hotkeys and Caps/Num/Scroll Lock LED Support");
