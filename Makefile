APP_NAME ?= MultiWhispr
BUNDLE_ID ?= com.izdi.multiwhispr
BUILD_DIR = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
CODESIGN_IDENTITY ?= -
CONTENTS = $(APP_BUNDLE)/Contents
MACOS_DIR = $(CONTENTS)/MacOS
RESOURCES = $(CONTENTS)/Resources
APP_EXECUTABLE = $(MACOS_DIR)/$(APP_NAME)
ARCH ?= $(shell uname -m)
TARGET = $(ARCH)-apple-macosx14.2
SDK = $(shell xcrun --show-sdk-path)

SOURCES = $(shell find Sources -name '*.swift' -type f | LC_ALL=C sort)
TEST_RUNNER = $(BUILD_DIR)/MultiWhisprTests
TEST_PRODUCTION_SOURCES = $(shell find Sources/MeetingCore -name '*.swift' -type f | LC_ALL=C sort)
TEST_SOURCES = $(shell find Tests -name '*.swift' -type f | LC_ALL=C sort)
ICON_SOURCE = Resources/AppIcon-Source.png
ICON_ICNS = Resources/AppIcon.icns

.PHONY: all check clean run icon test typecheck validate

all: $(APP_EXECUTABLE)

$(APP_EXECUTABLE): $(SOURCES) Info.plist $(ICON_ICNS)
	@mkdir -p "$(MACOS_DIR)" "$(RESOURCES)"
	swiftc -parse-as-library -o "$(APP_EXECUTABLE)" -sdk $(SDK) -target $(TARGET) $(SOURCES)
	@cp Info.plist "$(CONTENTS)/"
	@plutil -replace CFBundleName -string "$(APP_NAME)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleDisplayName -string "$(APP_NAME)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleExecutable -string "$(APP_NAME)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleIdentifier -string "$(BUNDLE_ID)" "$(CONTENTS)/Info.plist"
	@plutil -replace MultiWhisprBuildDate -string "$$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(CONTENTS)/Info.plist"
	@cp $(ICON_ICNS) "$(RESOURCES)/AppIcon.icns"
	@codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" --entitlements MultiWhispr.entitlements "$(APP_BUNDLE)"
	@echo "Built $(APP_BUNDLE)"

check: typecheck test validate

typecheck:
	swiftc -parse-as-library -typecheck -warnings-as-errors -sdk $(SDK) -target $(TARGET) $(SOURCES)

test:
	@mkdir -p "$(BUILD_DIR)"
	swiftc -parse-as-library -warnings-as-errors -o "$(TEST_RUNNER)" -sdk $(SDK) -target $(TARGET) $(TEST_PRODUCTION_SOURCES) $(TEST_SOURCES)
	@$(TEST_RUNNER)

validate:
	plutil -lint Info.plist MultiWhispr.entitlements

icon: $(ICON_ICNS)

$(ICON_ICNS): $(ICON_SOURCE)
	@mkdir -p $(BUILD_DIR)/AppIcon.iconset
	@for size in 16 32 128 256 512; do \
		sips -z $$size $$size $< --out $(BUILD_DIR)/AppIcon.iconset/icon_$${size}x$${size}.png > /dev/null; \
		sips -z $$((size*2)) $$((size*2)) $< --out $(BUILD_DIR)/AppIcon.iconset/icon_$${size}x$${size}@2x.png > /dev/null; \
	done
	@iconutil -c icns -o $@ $(BUILD_DIR)/AppIcon.iconset
	@rm -rf $(BUILD_DIR)/AppIcon.iconset
	@echo "Generated $@"

clean:
	rm -rf $(BUILD_DIR)

run: all
	open "$(APP_BUNDLE)"
