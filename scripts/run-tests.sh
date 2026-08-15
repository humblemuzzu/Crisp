#!/bin/bash
set -euo pipefail

# Runs the unit test suite the way CI runs it (this is what `make test` calls).
#
# Route: xcodegen + xcodebuild, not SwiftPM. project.yml is already the single
# source of truth for which files make up the headless CrispTests target; a
# Package.swift would have to restate that list and would drift out of sync
# silently — and a test target that quietly stops covering a file is exactly the
# failure this repo has already paid for once (the suite that was never executed
# anywhere, see .github/workflows/ci.yml).
#
# Prerequisites (both `brew`-installable, both installed by CI):
#   - full Xcode (not just the Command Line Tools) — xcodebuild runs the tests
#   - xcodegen — generates Crisp.xcodeproj from project.yml
#
# The suite is headless by construction: TEST_HOST/BUNDLE_LOADER are empty in
# project.yml, so nothing launches the app, touches /Applications/Crisp.app, or
# needs a real display attached. Anything that needs the monitor lives in
# crispctl and is run by hand.
#
# Usage: ./scripts/run-tests.sh [extra xcodebuild args...]

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Match the Makefile: use Xcode's toolchain even when xcode-select still points
# at the Command Line Tools.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
	export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# Preflight, so a missing prerequisite reads as an instruction instead of as a
# cryptic tool error.
if ! xcodebuild -version >/dev/null 2>&1; then
	echo "error: xcodebuild is unusable. The tests need full Xcode, not just the" >&2
	echo "       Command Line Tools. Install Xcode, then:" >&2
	echo "         sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
	exit 1
fi
if ! command -v xcodegen >/dev/null 2>&1; then
	echo "error: xcodegen not found — it generates Crisp.xcodeproj from project.yml." >&2
	echo "       brew install xcodegen" >&2
	exit 1
fi

LOG="$ROOT/build/test.log"
mkdir -p "$(dirname "$LOG")"

echo "==> Generating Crisp.xcodeproj from project.yml"
xcodegen generate

echo "==> Running CrispTests (full output: build/test.log)"
# Warnings are errors here (the baseline is zero, issue #47): a PR that
# introduces one fails the suite. Plain `make compile` stays permissive for
# mid-iteration builds; `make compile STRICT=1` is the same rule for the
# Command Line Tools path.
set +e
xcodebuild test \
	-project Crisp.xcodeproj -scheme Crisp \
	-destination 'platform=macOS' \
	CODE_SIGNING_ALLOWED=NO \
	SWIFT_VERSION=5 \
	SWIFT_STRICT_CONCURRENCY=minimal \
	SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
	"$@" 2>&1 |
	tee "$LOG" |
	grep --line-buffered -E "^(Test Suite '[A-Za-z]+Tests' (passed|failed)|.*error:|.*warning:|\*\* TEST)"
# xcodebuild's status, not grep's. No `|| true` on the pipeline above: it would
# reset PIPESTATUS and turn every failing run green (verified: it did).
status=${PIPESTATUS[0]}
set -e

# xcodebuild's own summary is one line at the very end of a very long log; surface
# it, so "the suite ran" is a claim with a number attached rather than an exit code.
echo ""
echo "==> Per-suite results"
# xcodebuild prints the suite verdict and its counts on two consecutive lines;
# pair them, and drop the two aggregate rows (the totals are reported below).
awk '
	$1 == "Test" && $2 == "Suite" && ($4 == "passed" || $4 == "failed") {
		suite = $3; gsub(/\x27/, "", suite); result = $4
		pending = (suite ~ /Tests$/)
		next
	}
	pending && /Executed [0-9]+ tests/ {
		sub(/^[ \t]+/, "")
		printf "    %-34s %-7s %s\n", suite, result, $0
		pending = 0
	}
' "$LOG"

TOTALS="$(grep -E '^[[:space:]]+Executed [0-9]+ tests' "$LOG" | tail -1 | sed 's/^[[:space:]]*//' || true)"
echo ""
if [ "$status" -ne 0 ]; then
	echo "TESTS FAILED (${TOTALS:-no summary — the build itself may have failed}). See build/test.log" >&2
	exit "$status"
fi
echo "tests passed: ${TOTALS:-no tests ran?}"
