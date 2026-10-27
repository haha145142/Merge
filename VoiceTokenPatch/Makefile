TARGET = iphone:clang:latest:15.0
ARCHS = arm64
FINALPACKAGE = 1
include $(THEOS)/makefiles/common.mk
TWEAK_NAME = VoiceTokenPatch
VoiceTokenPatch_FILES = Sources/VoiceTokenPatch.m
VoiceTokenPatch_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter
VoiceTokenPatch_FRAMEWORKS = Foundation UIKit
VoiceTokenPatch_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries
include $(THEOS_MAKE_PATH)/tweak.mk
