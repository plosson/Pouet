# Makefile — Pouet Audio Server Plugin + companion app
#
# Requirements:
#   - macOS 12+ SDK (Xcode Command Line Tools)
#   - Apple Developer ID certificate for code-signing
#   - Developer ID Installer certificate for pkg signing
#
# Usage:
#   make                  # build everything (unsigned)
#   make sign             # build + sign driver & app
#   make pkg              # build + sign + create installer pkg
#   make install          # install driver locally for testing (requires sudo)
#   make uninstall        # remove driver
#   make clean

BUNDLE_ID     = com.pouet.driver
VERSION       = $(shell git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo "0.0.0")

# ---- Paths ----
DRIVER_SRC    = Driver/PouetDriver.c
DRIVER_BUNDLE = build/Pouet.driver
DRIVER_BINARY = $(DRIVER_BUNDLE)/Contents/MacOS/PouetDriver
DRIVER_PLIST  = Driver/Pouet.driver/Contents/Info.plist

GUI_SRC       = App/PouetGUI.swift App/Log.swift App/AppService.swift App/AudioService.swift App/AudioMixing.swift App/ContentView.swift
GUI_BUNDLE    = build/Pouet.app
GUI_BINARY    = $(GUI_BUNDLE)/Contents/MacOS/Pouet
GUI_BUNDLE_ID = com.pouet.gui

UNINSTALLER   = build/Uninstall Pouet.app

PKG_ROOT      = build/pkg_root
PKG_OUT       = build/Pouet-$(VERSION).pkg

HAL_DIR       = /Library/Audio/Plug-Ins/HAL

# ---- Signing identities (set via env or override) ----
DEVID         ?= Developer ID Application: SPRL Losson (427N276E3Q)
INSTALLER_ID  ?= Developer ID Installer: SPRL Losson (427N276E3Q)

# ---- Compiler flags ----
CC            = clang
CFLAGS        = -arch arm64 -arch x86_64 \
                -mmacosx-version-min=12.0 \
                -O2 -fvisibility=hidden -fstack-protector-strong \
                -Wall -Wextra \
                -framework CoreAudio \
                -framework CoreFoundation

SWIFTC        = swiftc
SWIFTFLAGS    = -target arm64-apple-macos13.0 \
                -sdk $(shell xcrun --show-sdk-path) \
                -O

# ============================================================
.PHONY: all driver gui uninstaller sign pkg install uninstall clean test test-c test-swift test-audio test-webrtc

all: driver gui uninstaller

# ---- Driver bundle ----
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

# ---- GUI app ----
gui: $(GUI_BINARY)

$(GUI_BINARY): $(GUI_SRC) $(DRIVER_BINARY)
	@killall Pouet 2>/dev/null || true
	@sleep 0.5
	@mkdir -p $(GUI_BUNDLE)/Contents/MacOS
	@mkdir -p $(GUI_BUNDLE)/Contents/Resources
	$(SWIFTC) $(SWIFTFLAGS) \
	    -parse-as-library \
	    -import-objc-header App/BridgingHeader.h \
	    -framework CoreAudio \
	    -framework AVFoundation \
	    -framework AudioToolbox \
	    -o $(GUI_BINARY) \
	    $(GUI_SRC)
	@cp App/Info.plist $(GUI_BUNDLE)/Contents/Info.plist
	@/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" $(GUI_BUNDLE)/Contents/Info.plist
	@/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(VERSION)" $(GUI_BUNDLE)/Contents/Info.plist
	@cp App/AppIcon.icns $(GUI_BUNDLE)/Contents/Resources/AppIcon.icns
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
	    $(DRIVER_BUNDLE)
	codesign --force --options runtime \
	    --sign "$(DEVID)" \
	    --identifier $(BUNDLE_ID) \
	    $(GUI_BUNDLE)/Contents/Resources/Pouet.driver
	codesign --force --options runtime \
	    --sign "$(DEVID)" \
	    --identifier $(GUI_BUNDLE_ID) \
	    --entitlements App/entitlements.plist \
	    $(GUI_BUNDLE)
	codesign --force --options runtime \
	    --sign "$(DEVID)" \
	    --identifier com.pouet.uninstaller \
	    "$(UNINSTALLER)"
	@echo "✓ Signed"

# ---- Notarize (fill in your Apple ID + app-specific password) ----
notarize: sign
	@echo "Zipping for notarization …"
	ditto -c -k --keepParent $(DRIVER_BUNDLE) build/Pouet_driver.zip
	xcrun notarytool submit build/Pouet_driver.zip \
	    --apple-id "$$APPLE_ID" \
	    --password "$$APPLE_APP_PASSWORD" \
	    --team-id "$$TEAM_ID" \
	    --wait
	xcrun stapler staple $(DRIVER_BUNDLE)
	@echo "✓ Notarized"

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

test-swift: Tests/test_app.swift App/shm_bridge.h App/AudioMixing.swift
	@mkdir -p build
	$(SWIFTC) $(SWIFTFLAGS) \
	    -parse-as-library \
	    -import-objc-header App/shm_bridge.h \
	    -o build/test_app \
	    Tests/test_app.swift App/AudioMixing.swift
	@echo "--- Swift app tests ---"
	./build/test_app

test-audio: Tests/tone_injector.c Tests/test_audio.mjs
	@mkdir -p build
	node Tests/test_audio.mjs

test-webrtc: Tests/tone_injector.c Tests/webrtc_loopback.html Tests/test_webrtc.mjs
	@mkdir -p build
	@cd "$(CURDIR)" && npm ls playwright >/dev/null 2>&1 || npm install playwright
	node Tests/test_webrtc.mjs

clean:
	rm -rf build .build
