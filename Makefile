.PHONY: gen build run test kit-test clean

CODE_SIGN_IDENTITY ?= ""
CODE_SIGNING_REQUIRED ?= NO

gen:
	xcodegen generate

build: gen
	xcodebuild -project HerdrM.xcodeproj -scheme HerdrM -configuration Debug -derivedDataPath build build -skipPackagePluginValidation CODE_SIGN_IDENTITY=$(CODE_SIGN_IDENTITY) CODE_SIGNING_REQUIRED=$(CODE_SIGNING_REQUIRED) | tail -5

run: build
	open build/Build/Products/Debug/herdrm.app

kit-test:
	cd Packages/HerdrKit && swift test

test: kit-test

clean:
	rm -rf build build-rel HerdrM.xcodeproj Packages/*/.build
