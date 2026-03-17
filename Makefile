# Makefile — Pouet Audio Server Plugin + companion app
#
# Requirements:
#   - macOS 13+ SDK (Xcode Command Line Tools)
#   - Apple Developer ID certificate for code-signing
#   - Developer ID Installer certificate for pkg signing
#
# Usage:
#   make                  # build everything (unsigned)
#   make run              # build + launch app
#   make sign             # build + sign driver & app
#   make pkg              # build + sign + create installer pkg
#   make install          # install driver locally for testing (requires sudo)
#   make uninstall        # remove driver
#   make test             # run unit tests
#   make test-integration # run integration tests (requires installed driver)
#   make clean

BUNDLE_ID     = com.pouet.driver
VERSION       := $(shell git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo "0.0.0")

# ---- Paths ----
DRIVER_SRC    = Driver/PouetDriver.c
DRIVER_BUNDLE = build/Pouet.driver
DRIVER_BINARY = $(DRIVER_BUNDLE)/Contents/MacOS/PouetDriver
DRIVER_PLIST  = Driver/Pouet.driver/Contents/Info.plist

GUI_BUNDLE    = build/Pouet.app
GUI_BINARY    = $(GUI_BUNDLE)/Contents/MacOS/Pouet
GUI_BUNDLE_ID = com.pouet.gui

UNINSTALLER   = build/UninstallPouet.app

PKG_ROOT      = build/pkg_root
PKG_OUT       = build/Pouet-$(VERSION).pkg

HAL_DIR       = /Library/Audio/Plug-Ins/HAL

# ---- Signing identities (set via env or override) ----
DEVID         ?= Developer ID Application: SPRL Losson (427N276E3Q)
INSTALLER_ID  ?= Developer ID Installer: SPRL Losson (427N276E3Q)

# ---- Compiler flags (driver only — Swift uses SPM) ----
CC            = clang
CFLAGS        = -arch arm64 -arch x86_64 \
                -mmacosx-version-min=12.0 \
                -O2 -fvisibility=hidden -fstack-protector-strong \
                -Wall -Wextra \
                -framework CoreAudio \
                -framework CoreFoundation

# ============================================================
.PHONY: all run driver gui uninstaller sign pkg install uninstall clean test test-c test-swift test-integration test-audio test-webrtc

all: driver gui uninstaller

run: gui
	@open $(GUI_BUNDLE)

# ---- Driver bundle (C, built with clang) ----
driver: $(DRIVER_BINARY)

$(DRIVER_BINARY): $(DRIVER_SRC) $(DRIVER_PLIST)
	@mkdir -p $(DRIVER_BUNDLE)/Contents/MacOS
	@mkdir -p $(DRIVER_BUNDLE)/Contents/Resources
	$(CC) $(CFLAGS) \
	    -dynamiclib \
	    -install_name "@rpath/PouetDriver" \
	    -exported_symbols_list Driver/exports.lds \
	    -o $(DRIVER_BINARY) \
	    $(DRIVER_SRC)
	@cp $(DRIVER_PLIST) $(DRIVER_BUNDLE)/Contents/Info.plist
	@/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" $(DRIVER_BUNDLE)/Contents/Info.plist
	@/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(VERSION)" $(DRIVER_BUNDLE)/Contents/Info.plist
	@echo "✓ Driver bundle built → $(DRIVER_BUNDLE)"

# ---- GUI app (Swift, built with SPM) ----
gui: $(GUI_BINARY)

$(GUI_BINARY): Package.swift $(DRIVER_BINARY)
	@killall Pouet 2>/dev/null && sleep 0.5 || true
	swift build -c release
	@mkdir -p $(GUI_BUNDLE)/Contents/MacOS
	@mkdir -p $(GUI_BUNDLE)/Contents/Resources
	@cp .build/release/Pouet $(GUI_BINARY)
	@cp App/Info.plist $(GUI_BUNDLE)/Contents/Info.plist
	@/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" $(GUI_BUNDLE)/Contents/Info.plist
	@/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(VERSION)" $(GUI_BUNDLE)/Contents/Info.plist
	@cp App/AppIcon.icns $(GUI_BUNDLE)/Contents/Resources/AppIcon.icns
	@cp App/Resources/* $(GUI_BUNDLE)/Contents/Resources/
	@cp -R $(DRIVER_BUNDLE) $(GUI_BUNDLE)/Contents/Resources/Pouet.driver
	codesign --force --sign - --entitlements App/entitlements.plist $(GUI_BUNDLE)
	@echo "✓ GUI app built → $(GUI_BUNDLE)"

# ---- Uninstaller app ----
uninstaller: $(UNINSTALLER)

$(UNINSTALLER): Uninstaller/uninstall.sh Uninstaller/Info.plist
	@mkdir -p "$(UNINSTALLER)/Contents/MacOS"
	@mkdir -p "$(UNINSTALLER)/Contents/Resources"
	@cp Uninstaller/uninstall.sh "$(UNINSTALLER)/Contents/MacOS/uninstall.sh"
	@chmod +x "$(UNINSTALLER)/Contents/MacOS/uninstall.sh"
	@cp Uninstaller/Info.plist "$(UNINSTALLER)/Contents/Info.plist"
	@cp App/UninstallIcon.icns "$(UNINSTALLER)/Contents/Resources/AppIcon.icns"
	@echo "✓ Uninstaller built → $(UNINSTALLER)"

# ---- Code signing ----
sign: all
	codesign --force --options runtime \
	    --sign "$(DEVID)" \
	    --identifier $(BUNDLE_ID) \
	    --timestamp \
	    $(DRIVER_BUNDLE)
	codesign --force --options runtime \
	    --sign "$(DEVID)" \
	    --identifier $(BUNDLE_ID) \
	    --timestamp \
	    $(GUI_BUNDLE)/Contents/Resources/Pouet.driver
	codesign --force --options runtime \
	    --sign "$(DEVID)" \
	    --identifier $(GUI_BUNDLE_ID) \
	    --entitlements App/entitlements.plist \
	    --timestamp \
	    $(GUI_BUNDLE)
	codesign --force --options runtime \
	    --sign "$(DEVID)" \
	    --identifier com.pouet.uninstaller \
	    --timestamp \
	    "$(UNINSTALLER)"
	@echo "✓ Signed"

# ---- Installer package ----
pkg: sign
	@rm -rf $(PKG_ROOT)
	@mkdir -p $(PKG_ROOT)$(HAL_DIR)
	@mkdir -p $(PKG_ROOT)/Applications
	@cp -R $(DRIVER_BUNDLE) $(PKG_ROOT)$(HAL_DIR)/
	@cp -R $(GUI_BUNDLE)    $(PKG_ROOT)/Applications/
	@cp -R "$(UNINSTALLER)" "$(PKG_ROOT)/Applications/"
	pkgbuild \
	    --root $(PKG_ROOT) \
	    --install-location / \
	    --component-plist Installer/component.plist \
	    --identifier $(BUNDLE_ID) \
	    --version $(VERSION) \
	    --scripts Installer/scripts \
	    build/Pouet_component.pkg
	@sed 's/version="1.0.0"/version="$(VERSION)"/' Installer/distribution.xml > build/distribution.xml
	productbuild \
	    --distribution build/distribution.xml \
	    --package-path build \
	    --sign "$(INSTALLER_ID)" \
	    $(PKG_OUT)
	@echo "✓ Installer → $(PKG_OUT)"

# ---- Local install for testing ----
install: driver gui
	sudo mkdir -p $(HAL_DIR)
	sudo rm -rf $(HAL_DIR)/Pouet.driver
	sudo cp -R $(DRIVER_BUNDLE) $(HAL_DIR)/
	sudo chown -R root:wheel $(HAL_DIR)/Pouet.driver
	sudo killall -9 coreaudiod 2>/dev/null || true
	@sleep 2
	@echo "✓ Installed. Virtual mic should appear in Sound settings."

uninstall:
	sudo rm -rf $(HAL_DIR)/Pouet.driver
	sudo killall -9 coreaudiod 2>/dev/null || true
	@sleep 2
	@echo "✓ Uninstalled. Pouet driver removed."

# ---- Tests ----
test: test-c test-swift
	@echo "✓ All tests passed"

test-c: Tests/test_driver.c
	@mkdir -p build
	clang -O0 -g -Wall -Wextra \
	    -o build/test_driver \
	    Tests/test_driver.c -lm -lpthread
	@echo "--- C driver tests ---"
	./build/test_driver

test-swift: Tests/test_app.swift Sources/SHMBridge/include/shm_bridge.h Sources/Pouet/Services/AudioMixing.swift
	@mkdir -p build
	swiftc -target arm64-apple-macos13.0 \
	    -sdk $(shell xcrun --show-sdk-path) \
	    -O -parse-as-library \
	    -import-objc-header Sources/SHMBridge/include/shm_bridge.h \
	    -o build/test_app \
	    Tests/test_app.swift Sources/Pouet/Services/AudioMixing.swift
	@echo "--- Swift app tests ---"
	./build/test_app

test-integration: Tests/test_integration.c
	@mkdir -p build
	clang -O0 -g -Wall -Wextra \
	    -framework CoreAudio -framework AudioToolbox -framework CoreFoundation \
	    -o build/test_integration \
	    Tests/test_integration.c
	@echo "--- Integration tests (requires installed driver) ---"
	./build/test_integration

test-audio: Tests/tone_injector.c Tests/test_audio.mjs
	@mkdir -p build
	node Tests/test_audio.mjs

test-webrtc: Tests/tone_injector.c Tests/webrtc_loopback.html Tests/test_webrtc.mjs
	@mkdir -p build
	@cd "$(CURDIR)" && npm ls playwright >/dev/null 2>&1 || npm install playwright
	node Tests/test_webrtc.mjs

clean:
	rm -rf build .build
