# Build helpers for MyMacAgent (Swift 6.2 + CLT-only environment)
#
# Problem: system Swift 5.8 + SPM has a PlatformPath bug with CLT-only installs.
# Solution: use Homebrew Swift 6.2 (swift build/test) + an ld wrapper that
#           strips -no_warn_duplicate_libraries (unsupported by CLT ld64-857).
#
# Usage:  make build  /  make test  /  make clean

SWIFT     := /opt/homebrew/opt/swift/bin/swift
BUILD_BIN := $(shell pwd)/.build-tools
PATH_FIX  := $(BUILD_BIN):/opt/homebrew/opt/swift/bin

.PHONY: build test clean

build:
	PATH="$(PATH_FIX):$$PATH" $(SWIFT) build

test:
	PATH="$(PATH_FIX):$$PATH" $(SWIFT) test

clean:
	rm -rf .build

install: build
	cp .build/arm64-apple-macosx/debug/MyMacAgent build/MyMacAgent.app/Contents/MacOS/MyMacAgent
	codesign --force --sign - build/MyMacAgent.app

run: install
	open build/MyMacAgent.app

kill:
	pkill -f "MyMacAgent" 2>/dev/null || true
