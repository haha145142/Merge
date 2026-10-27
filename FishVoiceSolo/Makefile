TARGET = iphone:clang:latest:15.0
ARCHS = arm64
FINALPACKAGE = 1
include $(THEOS)/makefiles/common.mk
LIBRARY_NAME = FishVoiceSolo
FishVoiceSolo_FILES = Sources/FishVoiceSolo.m
FishVoiceSolo_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter
FishVoiceSolo_FRAMEWORKS = Foundation UIKit AVFoundation Security
FishVoiceSolo_INSTALL_PATH = /usr/lib
include $(THEOS_MAKE_PATH)/library.mk
