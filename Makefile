export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

.PHONY: test
test:
	cd Packages/WakeUpCore && swift test
	shellcheck Helper/*.sh Helper/tests/*.sh
	bash Helper/tests/watchdog_test.sh
	plutil -lint Helper/app.wakeup.watchdog.plist

.PHONY: generate build run
generate:
	xcodegen generate

build: generate
	xcodebuild -project WakeUp.xcodeproj -scheme WakeUp -configuration Debug -derivedDataPath build build

run: build
	open build/Build/Products/Debug/WakeUp.app

.PHONY: release
release: generate
	xcodebuild -project WakeUp.xcodeproj -scheme WakeUp -configuration Release -derivedDataPath build build
	codesign --force --deep -s - build/Build/Products/Release/WakeUp.app
	ditto -c -k --keepParent build/Build/Products/Release/WakeUp.app build/WakeUp.zip
