-include .pulse-build.local.mk

PROJECT := Pulse.xcodeproj
SCHEME := Pulse
DERIVED_DATA ?= /private/tmp/PulseDerivedData
DESTINATION := platform=macOS,arch=arm64
APP_BUNDLE := $(DERIVED_DATA)/Build/Products/Release/Pulse.app
VERSION ?=
VERSION_FLAG := $(if $(VERSION),MARKETING_VERSION=$(VERSION),)
XCODE_FLAGS := -project "$(PROJECT)" -scheme "$(SCHEME)" -destination "$(DESTINATION)" -derivedDataPath "$(DERIVED_DATA)" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES
LOCAL_SIGNING := CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
RELEASE_SIGN_IDENTITY ?= -

.PHONY: build test release dmg

build:
	xcodebuild -quiet $(XCODE_FLAGS) -configuration Debug $(LOCAL_SIGNING) build

test:
	xcodebuild -quiet $(XCODE_FLAGS) -configuration Debug $(LOCAL_SIGNING) -parallel-testing-enabled NO test
	python3 scripts/test-keep-awake-watchdog.py
	python3 scripts/test-xiaozhi-bridge.py
	python3 scripts/test-bundled-helpers.py

release:
	xcodebuild -quiet $(XCODE_FLAGS) -configuration Release CODE_SIGNING_ALLOWED=NO $(VERSION_FLAG) build
	/usr/bin/codesign --force --deep --sign "$(RELEASE_SIGN_IDENTITY)" --entitlements config/Pulse.entitlements "$(APP_BUNDLE)"
	/usr/bin/codesign --verify --deep --strict "$(APP_BUNDLE)"

dmg: release
	/bin/sh scripts/create-dmg.sh "$(APP_BUNDLE)" dist
