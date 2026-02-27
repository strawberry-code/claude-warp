APP_NAME = ClaudeWarp
BUILD_DIR = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
CONTENTS = $(APP_BUNDLE)/Contents
MACOS = $(CONTENTS)/MacOS
SRC_DIR = ClaudeWarp

SOURCES = $(SRC_DIR)/ClaudeWarpApp.swift \
          $(SRC_DIR)/AppState.swift \
          $(SRC_DIR)/ProxyServer.swift \
          $(SRC_DIR)/ClaudeBridge.swift \
          $(SRC_DIR)/MenuBarView.swift \
          $(SRC_DIR)/SettingsView.swift

SWIFT_FLAGS = -O -parse-as-library \
              -target arm64-apple-macosx14.0 \
              -sdk $(shell xcrun --show-sdk-path)

.PHONY: all clean install run

all: $(APP_BUNDLE)

$(APP_BUNDLE): $(SOURCES) $(SRC_DIR)/Info.plist
	@echo "Building $(APP_NAME)..."
	@mkdir -p $(MACOS) $(CONTENTS)/Resources
	swiftc $(SWIFT_FLAGS) $(SOURCES) -o $(MACOS)/$(APP_NAME)
	cp $(SRC_DIR)/Info.plist $(CONTENTS)/Info.plist
	cp $(SRC_DIR)/AppIcon.icns $(CONTENTS)/Resources/AppIcon.icns
	@echo "Built: $(APP_BUNDLE)"

clean:
	rm -rf $(BUILD_DIR)

install: $(APP_BUNDLE)
	cp -r $(APP_BUNDLE) /Applications/
	xattr -cr "/Applications/$(APP_NAME).app"
	@echo "Installed to /Applications/$(APP_NAME).app"

run: $(APP_BUNDLE)
	@echo "Launching $(APP_NAME)..."
	open $(APP_BUNDLE)

.PHONY: all clean install run
