#!/bin/bash
set -euo pipefail

# Machine-enforced version of AGENTS.md §3 "Engineering constraints". Until now
# those rules lived only in a doc and in review habit, which does not survive
# outside contributors. This script turns the two that are mechanically checkable
# into a build failure.
#
#   ./scripts/check-boundaries.sh                   # run every gate (also: make check-boundaries)
#   ./scripts/check-boundaries.sh private-frameworks
#   ./scripts/check-boundaries.sh model-purity
#   ./scripts/check-boundaries.sh --self-test       # prove the detectors still detect
#
# ---------------------------------------------------------------------------
# GATE 1 — private frameworks out of the DDC path (AGENTS.md §3.1)
# ---------------------------------------------------------------------------
# Why: this fork exists because BetterDisplay drove brightness through
# CoreBrightness/CoreDisplay/SkyLight shader APIs and took WindowServer down with
# it seven times. A DDC-only path cannot hit that crash class *by construction* —
# but only for as long as nobody wires a private framework into it. That is the
# invariant this gate defends.
#
# POLICED (zero tolerance — see ddc_core_files() below):
#   Crisp/Services/*.swift                   every service, MINUS the explicit
#                                            exclusions in unpoliced_services()
#   Crisp/Models/DDC*.swift                  the DDC decision cores (glob: new ones auto-policed)
#   Crisp/Models/BrightnessRung.swift        the brightness fallback ladder's decision core
#   crispctl/*.swift                         the CLI, which links the same stack
#
# The service list is a glob-minus-exclusions rather than an opt-in list on
# purpose: a hand-maintained "policed files" list means a brand-new DDC-adjacent
# service is unwatched from the day it lands, and *forgetting to add it* leaves
# no trace in any diff. Inverted, the default is "policed", and opting a file out
# is one visible line in this file that a reviewer has to agree with.
#
# SCOPED (allowlisted — see the brightness bridge check):
#   Crisp/Services/BrightnessService.swift   holds BOTH branches. The external
#   branch is DDC and must stay clean; the built-in-panel branch legitimately
#   uses DisplayServices via dlopen (IODisplayConnect is gone on Apple Silicon).
#   So: only DisplayServices, only as the dlopen/dlsym shim, and the shim may
#   only be *called* from the four built-in-panel functions.
#
# DELIBERATELY NOT POLICED, and why (the list itself lives in
# unpoliced_services(); this is the rationale):
#   Crisp/Services/{CoreBrightness,AutoBrightness,BrightnessBoost,BrightnessHUD,
#   PhysicalDisplayToggle,VirtualDisplay,DisplayPreset,Resolution}Service.swift,
#   Crisp/Models/{DisplayMode,VariableRefreshRange}.swift and the SystemColor /
#   ScreenEffects / PhysicalDisplayToggle views — these ARE upstream Crisp's
#   private-API features (SkyLight display toggle, CGS mode switching,
#   MonitorPanel HDR, OSDUIHelper HUD). AGENTS.md §3.2 says leave them gated and
#   dlopen'd, do not extend them. Policing them would fail on legitimate existing
#   code; the gate's job is to stop the DDC path from *joining* them.
#   Crisp/Services/BrightnessKeyService.swift is excluded for the same reason: it
#   deliberately shows the native OSDUIHelper HUD on each key press.
#
# THE ONE ALLOWED EXCEPTION inside the policed set is the `IOAVService*` family:
# undocumented but exported by IOKit, and it only talks to the display
# controller's I2C bus, never to WindowServer (same call MonitorControl ships).
# It matches none of the patterns below, so it needs no carve-out — this note
# exists so nobody adds one "for symmetry" and widens the pattern.
#
# ---------------------------------------------------------------------------
# GATE 2 — Crisp/Models/ stays headless (purity)
# ---------------------------------------------------------------------------
# Why: everything in Crisp/Models/ is pure decision logic that compiles into the
# headless CrispTests target (project.yml). That is what lets a contributor test
# DDC framing, the brightness ladder and quirks parsing without owning the
# monitor in question. An AppKit or SwiftUI import drags in the UI layer and the
# file silently stops being testable that way.
#
# The rule was derived from the tree, not assumed: CoreGraphics and IOKit are
# ALLOWED (several models carry CGDirectDisplayID / IOKit types, which is
# hardware identity, not UI). Only AppKit / Cocoa / SwiftUI are refused.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# --- shared reporting -------------------------------------------------------

VIOLATIONS=0

# GitHub Actions renders file/line annotations inline on the PR diff; locally the
# same information goes to stderr in grep's file:line: format.
report() { # file line message
	VIOLATIONS=$((VIOLATIONS + 1))
	[ -n "${GITHUB_ACTIONS:-}" ] && echo "::error file=$1,line=$2::$3"
	echo "  $1:$2: $3" >&2
}

# Swift comments are stripped before scanning: this codebase discusses the
# private frameworks it avoids ("not CoreDisplay", "the monitor's OSD menu"), and
# a gate that fails on prose teaches contributors to delete the prose.
#
# This walks the line character by character instead of running `sed 's|//.*||'`,
# because sed has no notion of a string literal: `let u = "https://x"` would have
# had everything after the `//` deleted, and any real violation later on that
# line deleted with it. That is not an evasion worry, it is an accident worry —
# a URL in a string is ordinary code. String *contents* are kept (the shim's
# "/System/Library/PrivateFrameworks/..." path is exactly what we scan for);
# only comment text is blanked. Line count is preserved so grep -n still points
# at the real line.
#
# Handled: // line comments, /* */ block comments (across lines), "" strings with
# \" escapes and \(...) interpolation, """ multi-line strings (across lines),
# and #"raw"# strings.
code_only() {
	awk '
	BEGIN { inBlock = 0; inMulti = 0 }
	{
		n = length($0); out = ""; i = 1
		inStr = 0; inRaw = 0; sp = 0
		while (i <= n) {
			c = substr($0, i, 1)
			two = substr($0, i, 2)
			three = substr($0, i, 3)
			if (inBlock) {
				if (two == "*/") { inBlock = 0; out = out "  "; i += 2 }
				else { out = out " "; i++ }
				continue
			}
			if (inMulti) {
				if (three == "\"\"\"") { inMulti = 0; out = out three; i += 3 }
				else { out = out c; i++ }
				continue
			}
			if (inRaw) {
				if (two == "\"#") { inRaw = 0; out = out two; i += 2 }
				else { out = out c; i++ }
				continue
			}
			if (inStr) {
				if (c == "\\") {
					# \" stays inside the string; \( opens an interpolation,
					# which is code again until its parens balance.
					if (substr($0, i + 1, 1) == "(") { sp++; depth[sp] = 1; inStr = 0 }
					out = out two; i += 2
					continue
				}
				if (c == "\"") { inStr = 0 }
				out = out c; i++
				continue
			}
			# code
			if (two == "//") break
			if (two == "/*") { inBlock = 1; out = out "  "; i += 2; continue }
			if (three == "\"\"\"") { inMulti = 1; out = out three; i += 3; continue }
			if (two == "#\"") { inRaw = 1; out = out two; i += 2; continue }
			if (c == "\"") { inStr = 1; out = out c; i++; continue }
			if (sp > 0) {
				if (c == "(") { depth[sp]++ }
				else if (c == ")") { depth[sp]--; if (depth[sp] == 0) { sp--; inStr = 1 } }
			}
			out = out c; i++
		}
		print out
	}' "$1"
}

# --- gate 1: private frameworks ---------------------------------------------

# Framework names alone are not enough: SLSConfigureDisplayEnabled never spells
# "SkyLight", and CBBlueLightClient never spells "CoreBrightness". Match the
# symbol prefixes each private framework actually appears as.
#
# "OSD" on its own is deliberately NOT matched: in this codebase it usually means
# the monitor's own on-screen menu (a DDC concept, e.g. "DDC/CI switched off in
# the OSD"). The private OSD/BezelServices surface is OSDUIHelper / OSDImage.
FORBIDDEN='SkyLight|SLS[A-Z][A-Za-z0-9_]*|CoreBrightness|CB(BlueLight|TrueTone)Client|CoreDisplay|DisplayServices|OSDUIHelper|OSDImage|BezelServices|IOMobileFramebuffer|MonitorPanel|MPDisplay[A-Za-z0-9_]*|/System/Library/PrivateFrameworks/'

# The §3.2 private-API services, which predate this fork and are frozen rather
# than fixed (SkyLight display toggle, CGS mode switching, MonitorPanel HDR,
# OSDUIHelper HUD). Policing them would fail on legitimate existing code; the
# gate's job is to stop the DDC path from *joining* them. Every one of these
# lines is a deliberate, reviewable opt-out — adding one should need an argument.
unpoliced_services() {
	cat <<-'EOF'
		Crisp/Services/AutoBrightnessService.swift
		Crisp/Services/BrightnessBoostService.swift
		Crisp/Services/BrightnessHUDService.swift
		Crisp/Services/BrightnessKeyService.swift
		Crisp/Services/CoreBrightnessService.swift
		Crisp/Services/DisplayPresetService.swift
		Crisp/Services/PhysicalDisplayToggleService.swift
		Crisp/Services/ResolutionService.swift
		Crisp/Services/VirtualDisplayService.swift
	EOF
}

ddc_core_files() {
	local file excluded
	# Every service is policed unless it is explicitly opted out above, so a new
	# DDC-adjacent service is watched the day it lands. BrightnessService is not
	# "unpoliced" — it has its own scoped rule (scan_brightness_bridge).
	excluded=" $(unpoliced_services | tr '\n' ' ')$BRIGHTNESS_FILE "
	find Crisp/Services -name '*.swift' | sort | while IFS= read -r file; do
		case "$excluded" in
		*" $file "*) continue ;;
		esac
		echo "$file"
	done
	# Explicit file: a rename must break the gate loudly (checked below) rather
	# than silently stop policing anything.
	echo 'Crisp/Models/BrightnessRung.swift'
	# Globs: a new DDC model or CLI file is policed the day it lands.
	find Crisp/Models -name 'DDC*.swift' | sort
	find crispctl -name '*.swift' | sort
}

# A file named here but absent from disk means the name moved. For a policed file
# that silently ends the policing; for an exclusion it silently starts policing
# something (or, worse, keeps excluding a name a future file could reuse). Both
# are reported, because both make the list and the tree disagree.
scan_missing_files() { # hint file...
	local hint="$1" file
	shift
	for file in "$@"; do
		[ -f "$file" ] && continue
		report "$(basename "$0")" 1 \
			"'$file' is listed in $(basename "$0") but no longer exists — it was renamed or removed. $hint"
	done
}

scan_forbidden() { # file...
	local file line text
	for file in "$@"; do
		# A missing file is reported by the caller as its own violation; skipping
		# it here keeps that message from being buried under scanner noise.
		[ -f "$file" ] || continue
		while IFS= read -r hit; do
			line="${hit%%:*}"
			text="${hit#*:}"
			report "$file" "$line" \
				"private framework symbol in the DDC path: $(echo "$text" | grep -oE "$FORBIDDEN" | head -1) — AGENTS.md §3.1 forbids it here (only IOAVService* is allowed)"
		done < <(code_only "$file" | grep -nE "$FORBIDDEN" || true)
	done
}

# BrightnessService.swift carries both branches, so it gets a scoped rule instead
# of a ban. Two things are checked:
#   (a) only DisplayServices may appear, and only as the built-in-panel shim;
#   (b) the resulting _DS* / _crispBuiltin* bridge symbols may only be referenced
#       from the built-in-panel functions, never from the external DDC branch.
BRIGHTNESS_FILE='Crisp/Services/BrightnessService.swift'
BRIGHTNESS_SHIM='dlopen\("/System/Library/PrivateFrameworks/DisplayServices\.framework/DisplayServices", RTLD_LAZY\)|dlsym\(h, "DisplayServices[A-Za-z]+"\)'
# 4 dlopen + 4 dlsym: get/set brightness and register/unregister for change
# notifications. Pinned so that growing the private surface is a conscious edit
# to this number, visible in review, rather than a silent addition.
BRIGHTNESS_SHIM_LINES=8
# The built-in panel's own functions. Anything else touching the bridge is the
# external branch reaching for the crash class.
BRIGHTNESS_BUILTIN_FUNCS='_crispBuiltinBrightnessChanged|startObservingBuiltinBrightness|getInternalBrightness|setInternalBrightness'

scan_brightness_bridge() { # file expected_shim_lines
	local file="$1" expected="$2" shim_count line text fn

	while IFS= read -r hit; do
		line="${hit%%:*}"
		text="${hit#*:}"
		# The allowed shim form is exempt; everything else is a finding.
		echo "$text" | grep -qE "$BRIGHTNESS_SHIM" && continue
		report "$file" "$line" \
			"private framework symbol outside the built-in-panel shim: $(echo "$text" | grep -oE "$FORBIDDEN" | head -1) — the external branch is DDC-only (AGENTS.md §3.1)"
	done < <(code_only "$file" | grep -nE "$FORBIDDEN" || true)

	shim_count=$(code_only "$file" | grep -cE "$BRIGHTNESS_SHIM" || true)
	if [ "$shim_count" -ne "$expected" ]; then
		report "$file" 1 \
			"built-in-panel DisplayServices shim count changed ($shim_count, pinned at $expected). If the change really is built-in-panel only, update BRIGHTNESS_SHIM_LINES in $(basename "$0") and say why in the commit."
	fi

	# Attribute each bridge reference to the nearest preceding `func` declaration.
	# Declarations of the shims themselves sit at top level and are exempt (their
	# form is already checked above).
	while IFS= read -r hit; do
		line="${hit%%:*}"
		hit="${hit#*:}"
		fn="${hit%%:*}"
		text="${hit#*:}"
		echo "$text" | grep -qE '^[[:space:]]*private (let|typealias) _?DS' && continue
		echo "$fn" | grep -qE "^($BRIGHTNESS_BUILTIN_FUNCS)$" && continue
		report "$file" "$line" \
			"built-in-panel private bridge used from '$fn' — only the built-in-panel functions ($BRIGHTNESS_BUILTIN_FUNCS) may call it (AGENTS.md §3.1)"
	done < <(code_only "$file" | awk '
		/(^|[^A-Za-z0-9_])func [A-Za-z_]/ {
			match($0, /func [A-Za-z_][A-Za-z0-9_]*/)
			fn = substr($0, RSTART + 5, RLENGTH - 5)
		}
		/_DS[A-Za-z]|_crispBuiltin[A-Za-z]/ {
			print NR ":" (fn == "" ? "<top-level>" : fn) ":" $0
		}')
}

gate_private_frameworks() {
	local file files=() excluded=()
	echo "==> Gate: private frameworks out of the DDC path (AGENTS.md §3.1)"

	while IFS= read -r file; do files+=("$file"); done < <(ddc_core_files)
	while IFS= read -r file; do excluded+=("$file"); done < <(unpoliced_services)

	scan_missing_files "The gate stopped watching it; update ddc_core_files()." \
		"${files[@]}" "$BRIGHTNESS_FILE"
	# Guarded because `set -u` treats "${empty[@]}" as unbound on bash 3.2, and an
	# empty exclusion list is a legitimate future state (every opt-out paid off).
	if [ "${#excluded[@]}" -gt 0 ]; then
		scan_missing_files "Its exclusion now protects nothing; update unpoliced_services()." \
			"${excluded[@]}"
	fi

	scan_forbidden "${files[@]}"
	[ -f "$BRIGHTNESS_FILE" ] && scan_brightness_bridge "$BRIGHTNESS_FILE" "$BRIGHTNESS_SHIM_LINES"

	echo "    ${#files[@]} DDC-path files + $BRIGHTNESS_FILE (scoped) checked, ${#excluded[@]} service(s) explicitly excluded"
}

# --- gate 2: model purity ---------------------------------------------------

FORBIDDEN_MODEL_IMPORTS='^[[:space:]]*(@[A-Za-z_]+ )*import (AppKit|Cocoa|SwiftUI)\b'

# The one deliberate exception, and the reason it is allowed to stay one:
# DisplayInfo is the display-identity value type, and it resolves the display's
# human-readable name through NSScreen.localizedName — there is no non-AppKit
# source for that string. It is correspondingly NOT a member of the headless test
# target (asserted below), so the exception cannot quietly spread into the code
# contributors run tests against.
MODEL_IMPORT_EXCEPTIONS='Crisp/Models/DisplayInfo.swift'

scan_model_imports() { # file...
	local file line text
	for file in "$@"; do
		case " $MODEL_IMPORT_EXCEPTIONS " in
		*" $file "*) continue ;;
		esac
		while IFS= read -r hit; do
			line="${hit%%:*}"
			text="${hit#*:}"
			report "$file" "$line" \
				"$(echo "$text" | sed 's/^[[:space:]]*//') — Crisp/Models must stay headless so it compiles into the CrispTests target. Move the UI half into Crisp/Views or Crisp/Services."
		done < <(grep -nE "$FORBIDDEN_MODEL_IMPORTS" "$file" || true)
	done
}

gate_model_purity() {
	local file files=()
	echo "==> Gate: Crisp/Models/ stays headless (no AppKit/Cocoa/SwiftUI)"

	while IFS= read -r file; do files+=("$file"); done < <(find Crisp/Models -name '*.swift' | sort)
	scan_model_imports "${files[@]}"

	# An exception is only tolerable while it stays out of the headless test
	# target; if someone adds it to project.yml's CrispTests sources, the target
	# stops being headless and the exception has to be paid off instead.
	for file in $MODEL_IMPORT_EXCEPTIONS; do
		grep -q "path: $file" project.yml && report project.yml 1 \
			"$file is an AppKit exception in $(basename "$0") but is now a source of a target in project.yml — either drop the AppKit import or drop the exception"
	done

	echo "    ${#files[@]} model files checked (${MODEL_IMPORT_EXCEPTIONS// /, } allowlisted)"
}

# --- self-test --------------------------------------------------------------

# A gate that has silently stopped detecting anything looks exactly like a clean
# tree. This repo has been burned by that once already (a unit test suite that
# was never executed anywhere), so every detector is run against known-bad
# fixtures on every CI run — including scan_brightness_bridge, whose awk pass
# attributes calls to the nearest preceding `func` and would quietly stop
# attributing anything if someone wrapped a long declaration across two lines.
SELF_TEST_STATUS=0

# Compares the violations the last fixture produced against what it should have
# produced, then resets the counter so fixtures can run back to back.
expect_violations() { # expected label
	[ "$VIOLATIONS" -eq "$1" ] || {
		echo "  self-test FAILED: $2 — expected $1 violation(s), got $VIOLATIONS" >&2
		SELF_TEST_STATUS=1
	}
	VIOLATIONS=0
}

self_test() {
	local tmp
	tmp="$(mktemp -d)"
	trap 'rm -rf "$tmp"' RETURN
	echo "==> Self-test: the detectors still detect"

	printf 'import Foundation\n// a comment mentioning CoreDisplay must NOT trip the gate\nlet h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)\n' >"$tmp/Bad.swift"
	printf 'import Foundation\nimport CoreGraphics\nimport IOKit\n// IOAVServiceReadI2C is the allowed exception, and the OSD menu is a DDC thing\n' >"$tmp/Good.swift"
	printf 'import Foundation\nimport SwiftUI\n' >"$tmp/BadModel.swift"

	# Comment stripping: prose and block comments are ignored, but a `//` inside
	# a string literal is not a comment and must not swallow the rest of the line.
	cat >"$tmp/Comments.swift" <<-'EOF'
		import Foundation
		// prose about CoreDisplay and SkyLight must NOT trip the gate
		/* nor may a block comment naming DisplayServices,
		   even when it spans several lines */
		let docs = "https://example.com/ddc"  // trailing note about CoreBrightness
	EOF
	cat >"$tmp/StringLiteral.swift" <<-'EOF'
		import Foundation
		func hidden() -> Bool { return ("http://example.com" as NSString).length > 0 && CoreDisplay_Fake_Call() }
	EOF

	# Brightness bridge: the shim form itself is exempt, the pinned shim count is
	# enforced, and only the built-in-panel functions may call the bridge.
	cat >"$tmp/BridgeGood.swift" <<-'EOF'
		import Foundation
		private let _DSHandle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
		private let _DSGet = dlsym(h, "DisplayServicesGetBrightness")
		func getInternalBrightness() -> Float {
		    return _DSGet()
		}
	EOF
	cat >"$tmp/BridgeCall.swift" <<-'EOF'
		import Foundation
		private let _DSHandle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
		private let _DSGet = dlsym(h, "DisplayServicesGetBrightness")
		func setExternalBrightness() {
		    _ = _DSGet()
		}
	EOF
	cat >"$tmp/BridgeCount.swift" <<-'EOF'
		import Foundation
		private let _DSHandle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
		private let _DSGet = dlsym(h, "DisplayServicesGetBrightness")
		private let _DSSet = dlsym(h, "DisplayServicesSetBrightness")
		func getInternalBrightness() -> Float {
		    return _DSGet()
		}
	EOF

	SELF_TEST_STATUS=0
	VIOLATIONS=0

	scan_forbidden "$tmp/Bad.swift" 2>/dev/null
	expect_violations 1 "private-framework detector missed a SkyLight dlopen"

	scan_forbidden "$tmp/Good.swift" 2>/dev/null
	expect_violations 0 "private-framework detector fired on IOAVService/comment-only text"

	scan_forbidden "$tmp/Comments.swift" 2>/dev/null
	expect_violations 0 "comment stripper stopped ignoring line/block comments"

	scan_forbidden "$tmp/StringLiteral.swift" 2>/dev/null
	expect_violations 1 "a '//' inside a string literal hid the rest of the line from the scanner"

	scan_brightness_bridge "$tmp/BridgeGood.swift" 2 2>/dev/null
	expect_violations 0 "brightness-bridge detector fired on the allowed shim + built-in-panel caller"

	scan_brightness_bridge "$tmp/BridgeCall.swift" 2 2>/dev/null
	expect_violations 1 "brightness-bridge detector missed a bridge call from outside the built-in-panel functions"

	scan_brightness_bridge "$tmp/BridgeCount.swift" 2 2>/dev/null
	expect_violations 1 "brightness-bridge detector missed an added DisplayServices shim line"

	scan_missing_files "self-test" "$tmp/Renamed.swift" 2>/dev/null
	expect_violations 1 "missing-file detector missed a listed file that is not on disk"

	scan_missing_files "self-test" "$tmp/Good.swift" 2>/dev/null
	expect_violations 0 "missing-file detector fired on a file that exists"

	scan_model_imports "$tmp/BadModel.swift" 2>/dev/null
	expect_violations 1 "model-purity detector missed 'import SwiftUI'"

	[ "$SELF_TEST_STATUS" -eq 0 ] && echo "    detectors OK (private frameworks, string-literal comments, brightness bridge, missing files, model imports)"
	return "$SELF_TEST_STATUS"
}

# --- entry point ------------------------------------------------------------

case "${1:-all}" in
private-frameworks) gate_private_frameworks ;;
model-purity) gate_model_purity ;;
--self-test) self_test; exit $? ;;
all)
	self_test
	gate_private_frameworks
	gate_model_purity
	;;
*)
	echo "usage: $0 [all|private-frameworks|model-purity|--self-test]" >&2
	exit 2
	;;
esac

if [ "$VIOLATIONS" -ne 0 ]; then
	echo "" >&2
	echo "check-boundaries: $VIOLATIONS violation(s) of AGENTS.md §3. These rules are why this fork exists — read §2 before arguing with them." >&2
	exit 1
fi
echo "check-boundaries: clean"
