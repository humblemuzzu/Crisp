# Crisp — convenience wrappers around the existing build scripts.
#
# Fast dev loop (Command Line Tools only, no Xcode):
#   make dev        compile, swap the binary into /Applications/Crisp.app, relaunch
#   make compile    compile the binary only (./Crisp-bin), no swap — quick build check
#                   (STRICT=1 adds -warnings-as-errors, which is what CI builds with)
#   make test       generate the Xcode project and run unit tests
#   make boundaries architecture gates: AGENTS.md §3 as a build failure (no Xcode needed)
#   make accessibility  every interactive control is named in source (no Xcode needed)
#   make check      lint + boundaries + tests + localization keys, everything CI enforces:
#                   run before pushing
#                   (auto-run on every push after: git config core.hooksPath .githooks)
#
# Distributable DMG (docs/RELEASING.md):
#   make preflight  can this machine produce a notarized release? (checks only)
#   make build      signed universal (arm64 + x86_64) DMG via scripts/release.sh (dry run)
#   make dmg        DMG via Xcode (scripts/build-dmg.sh; needs full Xcode + xcodegen)
#   make release ARGS="vX.Y.Z notes.md --publish"   full release (see scripts/release.sh)
#
#   make clean      remove build artifacts
#   make help       list targets (default)
#
# The dev target honours dev.sh's CRISP_APP override, e.g.:
#   make dev CRISP_APP=/path/to/Crisp.app

# Single source of truth for the version: project.yml (used to tag the dry-run DMG).
VERSION := $(shell grep -E '^[[:space:]]*MARKETING_VERSION:' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')

# Use Xcode.app's toolchain when installed, even if xcode-select still points at
# the Command Line Tools: xcodebuild (test) and SwiftLint's SourceKit need it.
ifneq (,$(wildcard /Applications/Xcode.app))
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
endif

# swiftc invocation kept in sync with dev.sh's compile step.
SWIFT_SOURCES := Crisp/App/*.swift Crisp/Intents/*.swift Crisp/Models/*.swift \
                 Crisp/Services/*.swift Crisp/Views/*.swift Crisp/Utilities/*.swift
SWIFTC_FLAGS := -O -swift-version 5 -strict-concurrency=minimal -parse-as-library \
                -import-objc-header Crisp/Crisp-Bridging-Header.h \
                -framework AppKit -framework SwiftUI -framework IOKit -framework CoreAudio \
                -framework Security -framework CryptoKit -framework Network \
                -Xlinker -undefined -Xlinker dynamic_lookup

# The zero-warning baseline (AGENTS.md §3.5) is only real if something enforces
# it. CI builds with STRICT=1; local builds stay permissive so a mid-iteration
# warning doesn't block the edit-compile-run loop.
ifeq ($(STRICT),1)
SWIFTC_STRICT_FLAGS := -warnings-as-errors
endif

# crispctl shares the app's whole DDC stack (same IOKit DDC path, no private
# frameworks): DDCService on top of the DDCTransport seam (DDCPacket framing,
# DDCProtocolEngine retry/quarantine, IOKitDDCTransport I2C, DDCServiceMatcher
# channel pairing). Command Line Tools only.
#
# It also shares the smart-TV stack, for the same reason and on the same terms:
# `TVConversation` over the `TVTransport` seam, and the same Keychain items, so a
# TV paired in the panel behaves identically from the command line. Kept in sync
# with project.yml's crispctl target, which explains what the CLI deliberately
# does not link (the app's destructive-write gate) and why.
CRISPCTL_SOURCES := crispctl/*.swift \
                    Crisp/Services/DDCService.swift Crisp/Services/IOKitDDCTransport.swift \
                    Crisp/Models/DDCPacket.swift Crisp/Models/DDCTransport.swift \
                    Crisp/Models/DDCProtocolEngine.swift Crisp/Models/DDCServiceMatcher.swift \
                    Crisp/Models/DDCCapabilities.swift Crisp/Models/DDCFeatureRegistry.swift \
                    Crisp/Models/DisplayUUID.swift Crisp/Models/DisplayStateDocument.swift \
                    Crisp/Models/JSONValue.swift Crisp/Models/DisplayGroup.swift \
                    Crisp/Models/DDCPreset.swift Crisp/Models/PresetSchedule.swift \
                    Crisp/Models/TVDevice.swift Crisp/Models/TVTransport.swift \
                    Crisp/Models/TVTrust.swift Crisp/Models/WebOSProtocol.swift \
                    Crisp/Models/TizenProtocol.swift Crisp/Services/TVConversation.swift \
                    Crisp/Services/TVWebSocketTransport.swift Crisp/Services/TVCredentialStore.swift
CRISPCTL_FLAGS := -O -swift-version 5 -strict-concurrency=minimal -parse-as-library \
                  -import-objc-header Crisp/Crisp-Bridging-Header.h \
                  -framework IOKit -framework CoreGraphics \
                  -framework Security -framework CryptoKit

.DEFAULT_GOAL := help
.PHONY: help dev compile crispctl strict-build test boundaries accessibility lint loc-check check preflight build dmg release clean

help:
	@echo "Crisp — make targets:"
	@echo "  make dev        compile + swap into /Applications/Crisp.app + relaunch (dev.sh)"
	@echo "  make compile    compile ./Crisp-bin only, no swap (quick build check)"
	@echo "  make crispctl   compile ./crispctl-bin, the DDC CLI"
	@echo "  make test       generate the Xcode project and run unit tests"
	@echo "  make boundaries architecture gates (AGENTS.md §3), no Xcode needed"
	@echo "  make accessibility  every interactive control is named in source, no Xcode needed"
	@echo "  make check      lint + boundaries + tests + localization keys, everything CI enforces"
	@echo "  make preflight  can this machine produce a notarized release? (docs/RELEASING.md)"
	@echo "  make build      signed universal DMG, no Xcode (scripts/release.sh v$(VERSION))"
	@echo "  make dmg        DMG via Xcode (scripts/build-dmg.sh)"
	@echo "  make release ARGS=\"vX.Y.Z notes.md --publish\"   full release (scripts/release.sh)"
	@echo "  make clean      remove build artifacts (Crisp-bin, build/, Crisp.dmg)"

dev:
	./dev.sh

compile:
	@echo "==> Compiling Crisp $(VERSION) -> ./Crisp-bin"
	swiftc $(SWIFTC_FLAGS) $(SWIFTC_STRICT_FLAGS) $(SWIFT_SOURCES) -o Crisp-bin
	@echo "Done. ./Crisp-bin built (not swapped into the app; use 'make dev' for that)."

crispctl:
	@echo "==> Compiling crispctl -> ./crispctl-bin"
	swiftc $(CRISPCTL_FLAGS) $(SWIFTC_STRICT_FLAGS) $(CRISPCTL_SOURCES) -o crispctl-bin
	@echo "Done. ./crispctl-bin built. Try: ./crispctl-bin list"

# Preflight (Xcode + xcodegen), xcodegen generate, xcodebuild test, and a
# per-suite pass/fail table — a green run now says how many tests ran.
test:
	./scripts/run-tests.sh

# AGENTS.md §3's hard rules, machine-checked: no private frameworks in the DDC
# path, no AppKit/SwiftUI in Crisp/Models. Pure text analysis, so it needs
# neither Xcode nor a display and runs in under a second.
boundaries:
	./scripts/check-boundaries.sh

# Every Button/Slider/Toggle in the policed views is given a name in source, and
# every titled window an accessibility identifier. Static: a runtime AX query
# needs a GUI session and a running menu-bar app, which no CI runner has. The
# script's header is explicit about what that can and cannot prove;
# `./scripts/check-accessibility.sh --runtime` is the optional live companion.
accessibility:
	./scripts/check-accessibility.sh

# The zero-warning baseline exactly as CI builds it: both binaries, warnings as
# errors. Separate from `compile` so the plain target stays permissive.
strict-build:
	$(MAKE) compile STRICT=1
	$(MAKE) crispctl STRICT=1

lint:
	@command -v swiftlint >/dev/null || { echo "SwiftLint not installed: brew install swiftlint"; exit 1; }
	swiftlint lint --strict --quiet

# Same check as CI's "Check localization keys" step: every key the code uses
# must exist in the String Catalog (missing keys silently fall back to English).
loc-check:
	xcodegen generate
	xcodebuild -quiet -exportLocalizations -project Crisp.xcodeproj \
		-localizationPath build/loc CODE_SIGNING_ALLOWED=NO \
		SWIFT_EMIT_LOC_STRINGS=YES SWIFT_VERSION=5 SWIFT_STRICT_CONCURRENCY=minimal
	python3 scripts/check-localization-keys.py build/loc/en.xcloc \
		Crisp/Resources/Localizable.xcstrings scripts/i18n-missing-allowlist.txt

# Everything CI enforces (lint + boundaries + build + tests + localization keys),
# locally. Boundaries run first: they are the cheapest and the most likely to be
# what an unfamiliar contributor trips over.
check: lint boundaries accessibility strict-build test loc-check
	@echo "check passed: lint clean, boundaries held, controls named, zero warnings, tests green, localization keys complete"

# Release credentials only: a Developer ID Application certificate and stored
# notarization credentials. Builds nothing, so it is the cheapest way to find out
# that a release cannot be signed *before* spending two minutes compiling one.
preflight:
	./scripts/release.sh --preflight

build:
	./scripts/release.sh v$(VERSION)

dmg:
	./scripts/build-dmg.sh

release:
	./scripts/release.sh $(ARGS)

clean:
	rm -f Crisp-bin Crisp.dmg
	rm -rf build
	@echo "Cleaned: Crisp-bin, Crisp.dmg, build/"
