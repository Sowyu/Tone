# Tone build + stable signing.
#   make install   build, sign with the stable identity, copy to /Applications, verify
#   make ci        unsigned build, no secrets (used by GitHub Actions)

APP_NAME    := Tone
BUNDLE_ID   := com.gooober.tone
BUILD_DIR   := build
DERIVED     := $(BUILD_DIR)/DerivedData
PRODUCT     := $(DERIVED)/Build/Products/Release/$(APP_NAME).app
INSTALL_APP := /Applications/$(APP_NAME).app
ENTITLEMENTS:= Tone/Resources/Tone.entitlements
LOCAL_CONF  := Config/Signing.local.xcconfig
IDENTITY    := $(shell sed -n 's/^TONE_SIGNING_IDENTITY *= *//p' $(LOCAL_CONF) 2>/dev/null)

.PHONY: all project build sign install verify ci clean identity run

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
	codesign --force --deep --options runtime --timestamp=none \
		--entitlements $(ENTITLEMENTS) \
		--requirements "=$$(cat $(BUILD_DIR)/requirement.txt)" \
		-s "$(IDENTITY)" $(PRODUCT)

install: sign
	-@pkill -x $(APP_NAME) && sleep 0.5 || true
	ditto $(PRODUCT) $(INSTALL_APP)
	@$(MAKE) --no-print-directory verify
	open $(INSTALL_APP)

verify:
	codesign -dv --verbose=4 $(INSTALL_APP) 2>&1 | grep -E "Identifier|Authority|TeamIdentifier|Runtime|flags|CDHash="
	codesign -d -r- $(INSTALL_APP) 2>&1 | grep designated

run:
	open $(INSTALL_APP)

ci: project
	xcodebuild -project $(APP_NAME).xcodeproj -scheme $(APP_NAME) -configuration Release \
		-derivedDataPath $(DERIVED) -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" build

clean:
	xcodebuild -project $(APP_NAME).xcodeproj -scheme $(APP_NAME) -derivedDataPath $(DERIVED) clean
