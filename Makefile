obj-m += medion_kbd.o

KVERSION ?= $(shell uname -r)
KDIR ?= /lib/modules/$(KVERSION)/build

# Detect if the target kernel was built with Clang/LLVM (e.g. CachyOS) or GCC
LLVM ?= $(shell grep -qE "clang|CONFIG_CC_IS_CLANG=y" "$(KDIR)/include/generated/compile.h" "$(KDIR)/.config" 2>/dev/null && echo 1 || echo 0)
ifeq ($(LLVM),1)
LLVM_OPT := LLVM=1
endif

all:
	$(MAKE) -C "$(KDIR)" M="$(CURDIR)" $(LLVM_OPT) modules

clean:
	$(MAKE) -C "$(KDIR)" M="$(CURDIR)" clean
