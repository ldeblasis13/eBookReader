.PHONY: build clean install dmg verify-dmg

APP_NAME = EBookReader
SCHEME = $(APP_NAME)
PROJECT = $(APP_NAME).xcodeproj
BUILD_DIR = build
CONFIG = Release
APP_PATH = $(BUILD_DIR)/Build/Products/$(CONFIG)/$(APP_NAME).app
DMG_NAME ?= $(APP_NAME).dmg
VOLUME_NAME ?= Luca's Ebook Reader

build:
	@mkdir -p "$(BUILD_DIR)"
	@LOG="$(BUILD_DIR)/xcodebuild.log"; \
	if xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-derivedDataPath $(BUILD_DIR) ONLY_ACTIVE_ARCH=YES ARCHS=arm64 > "$$LOG" 2>&1; then \
		tail -3 "$$LOG"; \
	else \
		tail -40 "$$LOG"; \
		exit 1; \
	fi
	@echo "\n✓ Built at: $(APP_PATH)"

install: build
	@echo "Installing to /Applications..."
	rm -rf /Applications/$(APP_NAME).app
	cp -R "$(APP_PATH)" /Applications/
	@echo "✓ Installed to /Applications/$(APP_NAME).app"

dmg: build
	@TMP=$$(mktemp -d); \
	trap 'rm -rf "$$TMP"' EXIT; \
	rm -f "$(DMG_NAME)"; \
	ditto "$(APP_PATH)" "$$TMP/$(APP_NAME).app"; \
	ln -s /Applications "$$TMP/Applications"; \
	test -d "$$TMP/$(APP_NAME).app"; \
	test -L "$$TMP/Applications"; \
	hdiutil create -volname "$(VOLUME_NAME)" -srcfolder "$$TMP" -ov -format UDZO "$(DMG_NAME)"; \
	hdiutil verify "$(DMG_NAME)"
	@echo "\n✓ Created $(DMG_NAME) with $(APP_NAME).app and Applications link"

verify-dmg:
	@echo "Mount the DMG and confirm it contains:"
	@echo "  - $(APP_NAME).app"
	@echo "  - Applications -> /Applications"
	@echo ""
	@echo "Build a versioned release with:"
	@echo "  make dmg DMG_NAME=$(APP_NAME)-vX.Y.Z.dmg"

clean:
	rm -rf $(BUILD_DIR) $(APP_NAME).dmg
