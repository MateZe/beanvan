PRODUCT := Beanvan
CONFIGURATION ?= release
APP := dist/$(PRODUCT).app
ICON_SOURCE := Support/icon-1024.png
ICON_BUILD_DIR := dist/icon-build
ICONSET := $(ICON_BUILD_DIR)/AppIcon.iconset
ICON := $(ICON_BUILD_DIR)/AppIcon.icns

.PHONY: run icon bundle clean

run:
	swift run $(PRODUCT)

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

bundle:
	./scripts/build-app.sh "$(CONFIGURATION)"

clean:
	rm -rf dist
	swift package clean
