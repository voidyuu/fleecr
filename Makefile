.PHONY: gen build run test kit-test app-test clean

CODE_SIGN_IDENTITY ?= ""
CODE_SIGNING_REQUIRED ?= NO

gen:
	xcodegen generate

build: gen
	xcodebuild -quiet -project fleecr.xcodeproj -scheme fleecr -configuration Debug -derivedDataPath build build -skipPackagePluginValidation CODE_SIGN_IDENTITY=$(CODE_SIGN_IDENTITY) CODE_SIGNING_REQUIRED=$(CODE_SIGNING_REQUIRED)

run: build
	open build/Build/Products/Debug/fleecr.app

kit-test:
	cd Packages/HerdrKit && swift test

app-test: gen
	xcodebuild -quiet -project fleecr.xcodeproj -scheme fleecrTests -configuration Debug -derivedDataPath build test -skipPackagePluginValidation CODE_SIGN_IDENTITY=$(CODE_SIGN_IDENTITY) CODE_SIGNING_REQUIRED=$(CODE_SIGNING_REQUIRED)

test: kit-test app-test

clean:
	rm -rf build build-rel *.xcodeproj Packages/*/.build
