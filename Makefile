ARCHS = armv7
TARGET = iphone:clang:7.1:6.0
INSTALL_TARGET_PROCESSES = MuyuMusic

ifneq ($(THEOS),)
include $(THEOS)/makefiles/common.mk
APPLICATION_NAME = MuyuMusic
MuyuMusic_FILES = $(wildcard Sources/Core/*.m Sources/Core/*.c Sources/UI/*.m Sources/Network/*.m Sources/Library/*.m Sources/Library/*.c Sources/Playback/*.m Sources/Playback/*.c)
MuyuMusic_FRAMEWORKS = UIKit Foundation AVFoundation AudioToolbox MediaPlayer CoreMedia Security CoreGraphics ImageIO QuartzCore
MuyuMusic_LIBRARIES = sqlite3 z
MuyuMusic_CFLAGS = -fobjc-arc -I.build/quickjs/include -I.build/deps/include -ISources/Core -ISources/UI -ISources/Network -ISources/Library -ISources/Playback
MuyuMusic_LDFLAGS = -Wl,-U,__availability_version_check .build/quickjs/armv7/libquickjs.a .build/deps/lib/libFLAC.a .build/deps/lib/libcurl.a .build/deps/lib/libmbedtls.a .build/deps/lib/libmbedx509.a .build/deps/lib/libmbedcrypto.a
MuyuMusic_RESOURCE_DIRS = Resources
MuyuMusic_CODESIGN_FLAGS = -SResources/Entitlements.plist
include $(THEOS_MAKE_PATH)/application.mk
before-all::
	@if [ ! -f .build/deps/lib/libcurl.a ] || [ "$$(cat .build/deps/.target 2>/dev/null)" != armv7-apple-ios6.0 ]; then bash scripts/build-deps.sh; fi
	bash scripts/build-quickjs.sh
else
.PHONY: all deps ipa test clean
all: ipa
deps:
	bash scripts/build-deps.sh
	bash scripts/build-quickjs.sh
ipa:
	bash scripts/build.sh
test:
	bash scripts/test.sh
clean:
	rm -rf .build/obj .build/package
endif
