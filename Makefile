export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

.PHONY: test
test:
	cd Packages/LidlessCore && swift test
	shellcheck scripts/*.sh
	plutil -lint LidlessHelper/io.github.aesarva.Lidless.helper.plist

.PHONY: generate build run
generate:
	xcodegen generate

build: generate
	xcodebuild -project Lidless.xcodeproj -scheme Lidless -configuration Debug -derivedDataPath build build

run: build
	open build/Build/Products/Debug/Lidless.app

.PHONY: app dmg
# Release universal build → build/Lidless.app (ad-hoc unless SIGN_IDENTITY is set).
app:
	scripts/build-app.sh

# DMG without Developer ID: make dmg VERSION=0.1.0 → dist/Lidless-0.1.0.dmg.
# Signed + notarized release: scripts/release.sh <version>.
VERSION ?= 0.2.0
dmg:
	scripts/release.sh $(VERSION) --unsigned
