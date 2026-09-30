ARCHS = armv7
TARGET = iphone:clang:latest:6.0
GO_EASY_ON_ME = 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CH33ZENavTunesImporter
CH33ZENavTunesImporter_FILES = Tweak.xm
CH33ZENavTunesImporter_FRAMEWORKS = Foundation UIKit
CH33ZENavTunesImporter_LIBRARIES = substrate

TOOL_NAME = navtunesimport
navtunesimport_FILES = navtunesimport.mm
navtunesimport_FRAMEWORKS = Foundation
navtunesimport_INSTALL_PATH = /usr/bin

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/tool.mk
