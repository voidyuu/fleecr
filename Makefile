.PHONY: gen build run test kit-test clean

CODE_SIGN_IDENTITY ?= ""
CODE_SIGNING_REQUIRED ?= NO

gen:
	xcodegen generate

build: gen
	xcodebuild -project fleecr.xcodeproj -scheme fleecr -configuration Debug -derivedDataPath build build -skipPackagePluginValidation CODE_SIGN_IDENTITY=$(CODE_SIGN_IDENTITY) CODE_SIGNING_REQUIRED=$(CODE_SIGNING_REQUIRED) | tail -5

run: build
	open build/Build/Products/Debug/fleecr.app

kit-test:
	cd Packages/HerdrKit && swift test

test: kit-test

clean:
	rm -rf build build-rel *.xcodeproj Packages/*/.build
