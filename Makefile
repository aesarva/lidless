export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

.PHONY: test
test:
	cd Packages/WakeUpCore && swift test
	shellcheck Helper/*.sh Helper/tests/*.sh
	bash Helper/tests/watchdog_test.sh
	plutil -lint Helper/app.wakeup.watchdog.plist
