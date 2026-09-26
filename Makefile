.PHONY: project build test install clean ios install-ios

PROJECT := Shokonotes.xcodeproj
SCHEME := Shokonotes
IOS_SCHEME := ShokonotesIOS
IOS_BUNDLE := com.jcbaptiste.shokonotes
DERIVED := /tmp/shokonotes-build
IOS_DERIVED := /tmp/shokonotes-ios-build
IOS_APP := $(IOS_DERIVED)/Build/Products/Debug-iphoneos/Shokonotes.app
# Team ID is the certificate OU, not the (XXXXXXXXXX) in the common name.
IOS_TEAM ?= $(shell security find-certificate -c "Apple Development" -p 2>/dev/null | openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null | sed -n 's/.*OU=\([^,]*\).*/\1/p')
# First connected physical iPhone UDID. Override: make install-ios IOS_DEVICE="My iPhone"
IOS_DEVICE ?= $(shell xcrun devicectl list devices 2>/dev/null | awk '/physical$$/ { for (i = 1; i <= NF; i++) if ($$i ~ /^[0-9A-F]{8}-/) { print $$i; exit } }')

project:
	xcodegen generate

build: project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		-destination 'platform=macOS' -derivedDataPath $(DERIVED) \
		CODE_SIGNING_ALLOWED=NO build
	codesign --force --deep --sign - $(DERIVED)/Build/Products/Release/Shokonotes.app
	codesign --verify --deep --verbose=2 $(DERIVED)/Build/Products/Release/Shokonotes.app

test: project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-destination 'platform=macOS' -derivedDataPath $(DERIVED) \
		CODE_SIGNING_ALLOWED=NO test

install: build
	osascript -e 'tell application "Shokonotes" to quit' || true
	mkdir -p /Applications
	rm -rf /Applications/Shokonotes.app
	ditto $(DERIVED)/Build/Products/Release/Shokonotes.app /Applications/Shokonotes.app
	codesign --force --deep --sign - /Applications/Shokonotes.app

ios: project
	xcodebuild -project $(PROJECT) -scheme $(IOS_SCHEME) -configuration Debug \
		-destination 'generic/platform=iOS Simulator' -derivedDataPath $(IOS_DERIVED) \
		CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES build

# Signed Debug build on the plugged-in iPhone, then launch. Phone unlocked, cable on.
install-ios: project
	@test -n "$(IOS_TEAM)" || { echo "No Apple Development team in the keychain. Open Xcode once: ShokonotesIOS → Signing & Capabilities → Team."; exit 1; }
	@test -n "$(IOS_DEVICE)" || { echo "No iPhone connected. Plug it in, unlock it, then retry."; exit 1; }
	xcodebuild -project $(PROJECT) -scheme $(IOS_SCHEME) -configuration Debug \
		-destination 'platform=iOS,id=$(IOS_DEVICE)' \
		-derivedDataPath $(IOS_DERIVED) \
		-allowProvisioningUpdates \
		DEVELOPMENT_TEAM=$(IOS_TEAM) \
		build
	xcrun devicectl device install app --device $(IOS_DEVICE) "$(IOS_APP)"
	xcrun devicectl device process launch --device $(IOS_DEVICE) $(IOS_BUNDLE) \
		|| echo "Installed. Unlock the iPhone and tap Shokonotes if it did not open."

clean:
	rm -rf $(DERIVED) $(IOS_DERIVED) Shokonotes.xcodeproj
