.PHONY: build clean install dmg

APP_NAME = EBookReader
SCHEME = $(APP_NAME)
PROJECT = $(APP_NAME).xcodeproj
BUILD_DIR = build
CONFIG = Release
APP_PATH = $(BUILD_DIR)/Build/Products/$(CONFIG)/$(APP_NAME).app

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-derivedDataPath $(BUILD_DIR) ONLY_ACTIVE_ARCH=YES ARCHS=arm64 2>&1 | tail -3
	@echo "\n✓ Built at: $(APP_PATH)"

install: build
	@echo "Installing to /Applications..."
	rm -rf /Applications/$(APP_NAME).app
	cp -R "$(APP_PATH)" /Applications/
	@echo "✓ Installed to /Applications/$(APP_NAME).app"

dmg: build
	$(eval TMP := $(shell mktemp -d))
	cp -R "$(APP_PATH)" "$(TMP)/"
	ln -s /Applications "$(TMP)/Applications"
	hdiutil create -volname "$(APP_NAME)" -srcfolder "$(TMP)" -ov -format UDZO $(APP_NAME).dmg
	rm -rf "$(TMP)"
	@echo "\n✓ Created $(APP_NAME).dmg"

clean:
	rm -rf $(BUILD_DIR) $(APP_NAME).dmg
