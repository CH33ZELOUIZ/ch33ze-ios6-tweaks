ARCHS = armv7
TARGET = iphone:clang:latest:6.0
GO_EASY_ON_ME = 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CH33ZEOptimized
CH33ZEOptimized_FILES = Tweak.xm
CH33ZEOptimized_FRAMEWORKS = UIKit Foundation

BUNDLE_NAME = Optimized
Optimized_FILES = OptimizedRootListController.mm
Optimized_INSTALL_PATH = /Library/PreferenceBundles
Optimized_FRAMEWORKS = UIKit Foundation
Optimized_PRIVATE_FRAMEWORKS = Preferences

TOOL_NAME = optimizedctl
optimizedctl_FILES = optimizedctl.mm
optimizedctl_FRAMEWORKS = Foundation
optimizedctl_INSTALL_PATH = /usr/bin

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk
include $(THEOS_MAKE_PATH)/tool.mk
