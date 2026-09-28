ARCHS = armv7
TARGET = iphone:clang:latest:6.0
GO_EASY_ON_ME = 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CH33ZEBrightnessTray
CH33ZEBrightnessTray_FILES = Tweak.xm
CH33ZEBrightnessTray_FRAMEWORKS = UIKit Foundation
CH33ZEBrightnessTray_PRIVATE_FRAMEWORKS = SpringBoardServices
CH33ZEBrightnessTray_CFLAGS = -fobjc-arc=0

include $(THEOS_MAKE_PATH)/tweak.mk
