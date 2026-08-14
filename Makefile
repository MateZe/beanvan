PRODUCT := Beanvan
CONFIGURATION ?= release
APP := dist/$(PRODUCT).app
ICON_SOURCE := Support/icon-1024.png
ICON_BUILD_DIR := dist/icon-build
ICONSET := $(ICON_BUILD_DIR)/AppIcon.iconset
ICON := $(ICON_BUILD_DIR)/AppIcon.icns
PHRASE ?=

.PHONY: run run-a run-b icon bundle clean

run:
	swift run $(PRODUCT) --phrase "$(PHRASE)"

run-a:
	swift run $(PRODUCT) --name "Beanvan A" --port 0 --phrase "$(PHRASE)"

run-b:
	swift run $(PRODUCT) --name "Beanvan B" --port 0 --phrase "$(PHRASE)"

icon: $(ICON)

$(ICON): $(ICON_SOURCE) Makefile
	rm -rf "$(ICONSET)"
	mkdir -p "$(ICONSET)"
	sips -z 16 16 "$(ICON_SOURCE)" --out "$(ICONSET)/icon_16x16.png" >/dev/null
	sips -z 32 32 "$(ICON_SOURCE)" --out "$(ICONSET)/icon_16x16@2x.png" >/dev/null
	sips -z 32 32 "$(ICON_SOURCE)" --out "$(ICONSET)/icon_32x32.png" >/dev/null
	sips -z 64 64 "$(ICON_SOURCE)" --out "$(ICONSET)/icon_32x32@2x.png" >/dev/null
	sips -z 128 128 "$(ICON_SOURCE)" --out "$(ICONSET)/icon_128x128.png" >/dev/null
	sips -z 256 256 "$(ICON_SOURCE)" --out "$(ICONSET)/icon_128x128@2x.png" >/dev/null
	sips -z 256 256 "$(ICON_SOURCE)" --out "$(ICONSET)/icon_256x256.png" >/dev/null
	sips -z 512 512 "$(ICON_SOURCE)" --out "$(ICONSET)/icon_256x256@2x.png" >/dev/null
	sips -z 512 512 "$(ICON_SOURCE)" --out "$(ICONSET)/icon_512x512.png" >/dev/null
	sips -z 1024 1024 "$(ICON_SOURCE)" --out "$(ICONSET)/icon_512x512@2x.png" >/dev/null
	iconutil -c icns "$(ICONSET)" -o "$@"

bundle: icon
	swift build -c $(CONFIGURATION) --product $(PRODUCT)
	@BIN_PATH="$$(swift build -c $(CONFIGURATION) --show-bin-path)"; \
	APP="$(APP)"; \
	rm -rf "$$APP"; \
	mkdir -p "$$APP/Contents/MacOS" "$$APP/Contents/Resources"; \
	cp "$$BIN_PATH/$(PRODUCT)" "$$APP/Contents/MacOS/$(PRODUCT)"; \
	cp "Support/Info.plist" "$$APP/Contents/Info.plist"; \
	cp "$(ICON)" "$$APP/Contents/Resources/AppIcon.icns"; \
	for RESOURCE_BUNDLE in "$$BIN_PATH/$(PRODUCT)_$(PRODUCT).bundle"; do \
		[ -e "$$RESOURCE_BUNDLE" ] || continue; \
		BUNDLE_NAME="$$(basename "$$RESOURCE_BUNDLE")"; \
		cp -R "$$RESOURCE_BUNDLE" "$$APP/Contents/Resources/$$BUNDLE_NAME"; \
		ln -s "Contents/Resources/$$BUNDLE_NAME" "$$APP/$$BUNDLE_NAME"; \
	done; \
	printf 'Built %s\n' "$$APP"

clean:
	rm -rf dist
	swift package clean
