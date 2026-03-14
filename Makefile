# Makefile — Pouet (xcodebuild wrapper)
#
# Usage:
#   make                  # build app + driver (ad-hoc signed)
#   make sign             # build with Developer ID signing
#   make pkg              # build + sign + create installer pkg
#   make install          # install driver locally for testing (requires sudo)
#   make uninstall        # remove driver
#   make test             # run tests
#   make clean

PROJECT       = Pouet.xcodeproj
SCHEME        = Pouet
SYMROOT       = $(CURDIR)/build
CONFIG        = Release
PRODUCTS      = $(SYMROOT)/$(CONFIG)

VERSION       = $(shell git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo "0.0.0")

BUNDLE_ID     = com.pouet.driver
HAL_DIR       = /Library/Audio/Plug-Ins/HAL

PKG_ROOT      = build/pkg_root
PKG_OUT       = build/Pouet-$(VERSION).pkg

# ---- Signing identities (set via env or override) ----
DEVID         ?= Developer ID Application: SPRL Losson (427N276E3Q)
INSTALLER_ID  ?= Developer ID Installer: SPRL Losson (427N276E3Q)

# ============================================================
.PHONY: all clean sign pkg install uninstall uninstaller test test-c test-swift test-audio test-webrtc

all:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
	    SYMROOT=$(SYMROOT) \
	    CODE_SIGN_IDENTITY=- \
	    CODE_SIGN_STYLE=Manual \
	    MARKETING_VERSION=$(VERSION) \
	    CURRENT_PROJECT_VERSION=$(VERSION) \
	    build
	@echo "✓ Built → $(PRODUCTS)/Pouet.app"

clean:
	rm -rf build

sign:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
	    SYMROOT=$(SYMROOT) \
	    CODE_SIGN_IDENTITY="$(DEVID)" \
	    CODE_SIGN_STYLE=Manual \
	    ENABLE_HARDENED_RUNTIME=YES \
	    MARKETING_VERSION=$(VERSION) \
	    CURRENT_PROJECT_VERSION=$(VERSION) \
	    build
	@echo "✓ Signed build → $(PRODUCTS)/Pouet.app"

# ---- Uninstaller app (shell script wrapper) ----
uninstaller:
	@mkdir -p "build/Uninstall Pouet.app/Contents/MacOS"
	@mkdir -p "build/Uninstall Pouet.app/Contents/Resources"
	@cp Uninstaller/uninstall.sh "build/Uninstall Pouet.app/Contents/MacOS/uninstall.sh"
	@chmod +x "build/Uninstall Pouet.app/Contents/MacOS/uninstall.sh"
	@cp Uninstaller/Info.plist "build/Uninstall Pouet.app/Contents/Info.plist"
	@cp App/UninstallIcon.icns "build/Uninstall Pouet.app/Contents/Resources/AppIcon.icns"
	codesign --force --options runtime --sign "$(DEVID)" --identifier com.pouet.uninstaller "build/Uninstall Pouet.app"
	@echo "✓ Uninstaller built"

# ---- Installer package ----
pkg: sign uninstaller
	@rm -rf $(PKG_ROOT)
	@mkdir -p $(PKG_ROOT)$(HAL_DIR)
	@mkdir -p $(PKG_ROOT)/Applications
	@cp -R $(PRODUCTS)/Pouet.driver $(PKG_ROOT)$(HAL_DIR)/
	@cp -R $(PRODUCTS)/Pouet.app    $(PKG_ROOT)/Applications/
	@cp -R "build/Uninstall Pouet.app" "$(PKG_ROOT)/Applications/"
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
install: all
	sudo mkdir -p $(HAL_DIR)
	sudo rm -rf $(HAL_DIR)/Pouet.driver
	sudo cp -R $(PRODUCTS)/Pouet.driver $(HAL_DIR)/
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

test-swift: Tests/test_app.swift App/shm_bridge.h App/Services/AudioMixing.swift
	@mkdir -p build
	swiftc -target arm64-apple-macos13.0 \
	    -sdk $(shell xcrun --show-sdk-path) \
	    -O \
	    -parse-as-library \
	    -import-objc-header App/shm_bridge.h \
	    -o build/test_app \
	    Tests/test_app.swift App/Services/AudioMixing.swift
	@echo "--- Swift app tests ---"
	./build/test_app

test-audio: Tests/tone_injector.c Tests/test_audio.mjs
	@mkdir -p build
	node Tests/test_audio.mjs

test-webrtc: Tests/tone_injector.c Tests/webrtc_loopback.html Tests/test_webrtc.mjs
	@mkdir -p build
	@cd "$(CURDIR)" && npm ls playwright >/dev/null 2>&1 || npm install playwright
	node Tests/test_webrtc.mjs
