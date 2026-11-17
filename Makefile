# Tone build + stable signing.
#   make install   build, sign with the stable identity, copy to /Applications, verify
#   make ci        unsigned build plus the update self-check, no secrets (used by GitHub Actions)
#   make release NOTES=build/notes.md [DRY_RUN=1]   build Tone.dmg and publish a GitHub release

APP_NAME    := Tone
BUNDLE_ID   := com.sowyu.tone
BUILD_DIR   := build
DERIVED     := $(BUILD_DIR)/DerivedData
PRODUCT     := $(DERIVED)/Build/Products/Release/$(APP_NAME).app
INSTALL_APP := /Applications/$(APP_NAME).app
ENTITLEMENTS:= Tone/Resources/Tone.entitlements
LOCAL_CONF  := Config/Signing.local.xcconfig
IDENTITY    := $(shell sed -n 's/^TONE_SIGNING_IDENTITY *= *//p' $(LOCAL_CONF) 2>/dev/null)

.PHONY: all project build sign install verify ci check release clean identity run

all: install

$(LOCAL_CONF):
	cp Config/Signing.example.xcconfig $(LOCAL_CONF)

identity:
	./scripts/create-signing-identity.sh

project:
	xcodegen generate --quiet

build: project $(LOCAL_CONF)
	@test -n "$(IDENTITY)" || { echo "Set TONE_SIGNING_IDENTITY in $(LOCAL_CONF)"; exit 1; }
	xcodebuild -project $(APP_NAME).xcodeproj -scheme $(APP_NAME) -configuration Release \
		-derivedDataPath $(DERIVED) -destination 'generic/platform=macOS' -quiet build

# Re-sign with an explicit designated requirement (identifier + certificate leaf hash,
# no code hash) so TCC grants survive every rebuild.
sign: build
	@HASH=$$(security find-certificate -c "$(IDENTITY)" -Z | awk '/SHA-1/{print $$3}'); \
	test -n "$$HASH" || { echo "Identity '$(IDENTITY)' not found. Run: make identity"; exit 1; }; \
	echo "designated => identifier \"$(BUNDLE_ID)\" and certificate leaf = H\"$$HASH\"" > $(BUILD_DIR)/requirement.txt; \
	for f in $(PRODUCT)/Contents/Frameworks/*.framework; do \
		codesign --force --options runtime --timestamp=none -s "$(IDENTITY)" "$$f" || exit 1; \
	done; \
	codesign --force --options runtime --timestamp=none \
		--entitlements $(ENTITLEMENTS) \
		--requirements "=$$(cat $(BUILD_DIR)/requirement.txt)" \
		-s "$(IDENTITY)" $(PRODUCT)

install: sign
	-@pkill -x $(APP_NAME) && sleep 0.5 || true
	rm -rf $(INSTALL_APP)
	ditto $(PRODUCT) $(INSTALL_APP)
	@$(MAKE) --no-print-directory verify
	open $(INSTALL_APP)

verify:
	codesign -dv --verbose=4 $(INSTALL_APP) 2>&1 | grep -E "Identifier|Authority|TeamIdentifier|Runtime|flags|CDHash="
	codesign -d -r- $(INSTALL_APP) 2>&1 | grep designated

run:
	open $(INSTALL_APP)

# Release parsing and version ordering for the in-app updater.
check:
	@mkdir -p $(BUILD_DIR)
	swiftc -parse-as-library Tone/Services/Updates.swift scripts/check-updates.swift -o $(BUILD_DIR)/check-updates
	$(BUILD_DIR)/check-updates
	swiftc -O -parse-as-library Tone/Audio/DSPKernel.swift Tone/Services/Models.swift scripts/check-dsp.swift -o $(BUILD_DIR)/check-dsp
	$(BUILD_DIR)/check-dsp

release:
	./scripts/release.sh $(if $(DRY_RUN),--dry-run) $(NOTES)

ci: project check
	xcodebuild -project $(APP_NAME).xcodeproj -scheme $(APP_NAME) -configuration Release \
		-derivedDataPath $(DERIVED) -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" build

clean:
	xcodebuild -project $(APP_NAME).xcodeproj -scheme $(APP_NAME) -derivedDataPath $(DERIVED) clean
