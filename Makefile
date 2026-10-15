export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

.PHONY: test
test:
	cd Packages/LidlessCore && swift test
	shellcheck Helper/*.sh Helper/tests/*.sh
	bash Helper/tests/watchdog_test.sh
	plutil -lint Helper/app.lidless.watchdog.plist

.PHONY: generate build run
generate:
	xcodegen generate

build: generate
	xcodebuild -project Lidless.xcodeproj -scheme Lidless -configuration Debug -derivedDataPath build build

run: build
	open build/Build/Products/Debug/Lidless.app

.PHONY: release
release: generate
	xcodebuild -project Lidless.xcodeproj -scheme Lidless -configuration Release -derivedDataPath build build
	codesign --force --deep -s - build/Build/Products/Release/Lidless.app
	ditto -c -k --keepParent build/Build/Products/Release/Lidless.app build/Lidless.zip
