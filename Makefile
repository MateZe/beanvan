PRODUCT := CuppaJoe
CONFIGURATION ?= release
APP := dist/$(PRODUCT).app

.PHONY: run bundle clean

run:
	swift run $(PRODUCT)

bundle:
	swift build -c $(CONFIGURATION) --product $(PRODUCT)
	@BIN_PATH="$$(swift build -c $(CONFIGURATION) --show-bin-path)"; \
	APP="$(APP)"; \
	rm -rf "$$APP"; \
	mkdir -p "$$APP/Contents/MacOS" "$$APP/Contents/Resources"; \
	cp "$$BIN_PATH/$(PRODUCT)" "$$APP/Contents/MacOS/$(PRODUCT)"; \
	cp "Support/Info.plist" "$$APP/Contents/Info.plist"; \
	for RESOURCE_BUNDLE in "$$BIN_PATH"/*.bundle; do \
		[ -e "$$RESOURCE_BUNDLE" ] || continue; \
		BUNDLE_NAME="$$(basename "$$RESOURCE_BUNDLE")"; \
		cp -R "$$RESOURCE_BUNDLE" "$$APP/Contents/Resources/$$BUNDLE_NAME"; \
		ln -s "Contents/Resources/$$BUNDLE_NAME" "$$APP/$$BUNDLE_NAME"; \
	done; \
	printf 'Built %s\n' "$$APP"

clean:
	rm -rf dist
	swift package clean
