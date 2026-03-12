# Makefile — VirtualMic Audio Server Plugin + companion app
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

BUNDLE_ID     = com.virtualmicdrv.driver
APP_BUNDLE_ID = com.virtualmicdrv.app
VERSION       = 1.0.0

# ---- Paths ----
DRIVER_SRC    = Driver/VirtualMicDriver.c
DRIVER_BUNDLE = build/VirtualMic.driver
DRIVER_BINARY = $(DRIVER_BUNDLE)/Contents/MacOS/VirtualMicDriver
DRIVER_PLIST  = Driver/VirtualMic.driver/Contents/Info.plist

APP_SRC       = App/main.swift App/server.swift
APP_BINARY    = build/VirtualMicApp

GUI_SRC       = MacApp/VirtualMicGUI.swift MacApp/ServerManager.swift MacApp/APIClient.swift MacApp/ContentView.swift
GUI_BUNDLE    = build/VirtualMic.app
GUI_BINARY    = $(GUI_BUNDLE)/Contents/MacOS/VirtualMic
GUI_BUNDLE_ID = com.virtualmicdrv.gui

PKG_ROOT      = build/pkg_root
PKG_OUT       = build/VirtualMic-$(VERSION).pkg

HAL_DIR       = /Library/Audio/Plug-Ins/HAL

# ---- Signing identities (set via env or override) ----
DEVID         ?= Developer ID Application: SPRL Losson (427N276E3Q)
INSTALLER_ID  ?= Developer ID Installer: SPRL Losson (427N276E3Q)

# ---- Compiler flags ----
CC            = clang
CFLAGS        = -arch arm64 -arch x86_64 \
                -mmacosx-version-min=12.0 \
                -O2 -fvisibility=hidden \
                -Wall -Wextra \
                -framework CoreAudio \
                -framework CoreFoundation

SWIFTC        = swiftc
SWIFTFLAGS    = -target arm64-apple-macos12.0 \
                -sdk $(shell xcrun --show-sdk-path) \
                -O

# ============================================================
.PHONY: all driver app gui sign pkg install uninstall clean

all: driver app gui

# ---- Driver bundle ----
driver: $(DRIVER_BINARY)

$(DRIVER_BINARY): $(DRIVER_SRC) $(DRIVER_PLIST)
	@mkdir -p $(DRIVER_BUNDLE)/Contents/MacOS
	@mkdir -p $(DRIVER_BUNDLE)/Contents/Resources
	$(CC) $(CFLAGS) \
	    -dynamiclib \
	    -install_name "@rpath/VirtualMicDriver" \
	    -exported_symbols_list Driver/exports.lds \
	    -o $(DRIVER_BINARY) \
	    $(DRIVER_SRC)
	@cp $(DRIVER_PLIST) $(DRIVER_BUNDLE)/Contents/Info.plist
	@echo "✓ Driver bundle built → $(DRIVER_BUNDLE)"

# ---- Companion app ----
app: $(APP_BINARY)

$(APP_BINARY): $(APP_SRC)
	@mkdir -p build
	$(SWIFTC) $(SWIFTFLAGS) \
	    -import-objc-header App/shm_bridge.h \
	    -framework AVFoundation \
	    -framework Foundation \
	    -framework Accelerate \
	    -framework CoreAudio \
	    -framework AudioToolbox \
	    -o $(APP_BINARY) \
	    $(APP_SRC)
	codesign --force --sign - --entitlements App/entitlements.plist $(APP_BINARY)
	@echo "✓ App binary built → $(APP_BINARY)"

# ---- GUI app ----
gui: $(GUI_BINARY)

$(GUI_BINARY): $(GUI_SRC) $(APP_BINARY)
	@mkdir -p $(GUI_BUNDLE)/Contents/MacOS
	@mkdir -p $(GUI_BUNDLE)/Contents/Resources
	$(SWIFTC) -target arm64-apple-macos13.0 \
	    -sdk $(shell xcrun --show-sdk-path) \
	    -O -parse-as-library \
	    -o $(GUI_BINARY) \
	    $(GUI_SRC)
	@cp MacApp/Info.plist $(GUI_BUNDLE)/Contents/Info.plist
	@cp $(APP_BINARY) $(GUI_BUNDLE)/Contents/Resources/VirtualMicApp
	codesign --force --sign - --entitlements App/entitlements.plist $(GUI_BUNDLE)
	@echo "✓ GUI app built → $(GUI_BUNDLE)"

# ---- Code signing ----
sign: all
	codesign --force --options runtime \
	    --sign "$(DEVID)" \
	    --identifier $(BUNDLE_ID) \
	    $(DRIVER_BUNDLE)
	codesign --force --options runtime \
	    --sign "$(DEVID)" \
	    --identifier $(APP_BUNDLE_ID) \
	    --entitlements App/entitlements.plist \
	    $(APP_BINARY)
	codesign --force --options runtime \
	    --sign "$(DEVID)" \
	    --identifier $(GUI_BUNDLE_ID) \
	    --entitlements App/entitlements.plist \
	    $(GUI_BUNDLE)
	@echo "✓ Signed"

# ---- Notarize (fill in your Apple ID + app-specific password) ----
notarize: sign
	@echo "Zipping for notarization …"
	ditto -c -k --keepParent $(DRIVER_BUNDLE) build/VirtualMic_driver.zip
	xcrun notarytool submit build/VirtualMic_driver.zip \
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
	@mkdir -p $(PKG_ROOT)/usr/local/bin
	@mkdir -p $(PKG_ROOT)/Applications
	@cp -R $(DRIVER_BUNDLE) $(PKG_ROOT)$(HAL_DIR)/
	@cp    $(APP_BINARY)    $(PKG_ROOT)/usr/local/bin/VirtualMicApp
	@cp -R $(GUI_BUNDLE)    $(PKG_ROOT)/Applications/
	pkgbuild \
	    --root $(PKG_ROOT) \
	    --identifier $(BUNDLE_ID) \
	    --version $(VERSION) \
	    --scripts Installer/scripts \
	    build/VirtualMic_component.pkg
	productbuild \
	    --distribution Installer/distribution.xml \
	    --package-path build \
	    --sign "$(INSTALLER_ID)" \
	    $(PKG_OUT)
	@echo "✓ Installer → $(PKG_OUT)"

# ---- Local install for testing ----
install: driver app
	sudo mkdir -p $(HAL_DIR)
	sudo rm -rf $(HAL_DIR)/VirtualMic.driver
	sudo cp -R $(DRIVER_BUNDLE) $(HAL_DIR)/
	sudo chown -R root:wheel $(HAL_DIR)/VirtualMic.driver
	sudo cp $(APP_BINARY) /usr/local/bin/VirtualMicApp
	sudo killall -9 coreaudiod 2>/dev/null || true
	@sleep 2
	@echo "✓ Installed. Virtual mic should appear in Sound settings."

uninstall:
	sudo rm -rf $(HAL_DIR)/VirtualMic.driver
	sudo rm -f  /usr/local/bin/VirtualMicApp
	sudo killall -9 coreaudiod 2>/dev/null || true
	@sleep 2
	@echo "✓ Uninstalled. VirtualMic driver removed."

clean:
	rm -rf build
