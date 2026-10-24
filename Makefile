THEOS_PACKAGE_SCHEME = rootless
ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:16.0

include $(THEOS)/makefiles/common.mk
# Xcode 16 ld warns on this obsolete flag supplied by the pinned Theos target.
# Remove the deprecated option rather than suppressing linker diagnostics.
_THEOS_TARGET_LDFLAGS := $(subst -multiply_defined suppress,,$(_THEOS_TARGET_LDFLAGS))

TWEAK_NAME = Powercuff
Powercuff_FILES = Powercuff.x
Powercuff_FRAMEWORKS = Foundation
Powercuff_CFLAGS = -fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter

TOOL_NAME = powercuffctl
powercuffctl_FILES = tools/powercuffctl.m
powercuffctl_FRAMEWORKS = Foundation
powercuffctl_CFLAGS = -fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter -I.
powercuffctl_INSTALL_PATH = /usr/bin
powercuffctl_CODESIGN_FLAGS = -Sentitlements.plist

INSTALL_TARGET_PROCESSES = thermalmonitord SpringBoard
include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/tool.mk
