#!/bin/bash
set -euo pipefail

# Every interactive control in the SwiftUI views must carry a name that
# assistive technology can read.
#
#   ./scripts/check-accessibility.sh              # the static gate (also: make accessibility)
#   ./scripts/check-accessibility.sh --self-test  # prove the detector still detects
#   ./scripts/check-accessibility.sh --runtime    # optional live AX probe, needs a GUI session
#
# ---------------------------------------------------------------------------
# WHY THIS GATE EXISTS — and what it is really defending against
# ---------------------------------------------------------------------------
# Driving this app's windows from `System Events` returns `missing value` for
# the name of every element. That looks like "the buttons have no labels", and
# the first instinct is to paste `.accessibilityLabel` over everything. It is
# worth writing down what actually happens, because the instinct is half wrong
# and the other half is dangerous.
#
# Measured on macOS 26 (see reference/accessibility.md for the full transcript):
# SwiftUI publishes a `Button`'s name ONLY as `AXAttributedDescription`. It sets
# neither `AXTitle` nor `AXDescription` — those attributes are not merely empty,
# they are absent from the element's attribute list. VoiceOver reads
# `AXAttributedDescription`, so a plain `Button("Next")` IS announced; System
# Events reads `AXTitle`/`AXDescription`, so the same button is anonymous to
# scripted automation. Same story for `Slider`: `.accessibilityValue("50%")`
# lands in `AXValueDescription` while `AXValue` stays the raw `50.0`.
#
# So the real, checkable rule is not "AX exposes a name" (a runtime property no
# CI machine can observe) but its source-level cause: **every control must be
# given a name in the source**, either as a literal text label or as an explicit
# `.accessibilityLabel`. A control with neither has nothing to publish through
# any attribute, on any macOS.
#
# The measurement also produced a trap this gate deliberately does NOT reward:
# `.accessibilityElement(children: .ignore)` applied to a `Button` demotes it
# from `AXButton` to `AXUnknown` — it stops being a button to VoiceOver and to
# automation alike. Pasting that modifier on to "fix" a label is strictly worse
# than the unlabelled button. It is refused below on interactive controls.
#
# ---------------------------------------------------------------------------
# WHAT A STATIC CHECK CAN AND CANNOT PROVE — read this before trusting it
# ---------------------------------------------------------------------------
# CAN prove:
#   - every control constructor in the policed files is given a name in source;
#   - no interactive control is collapsed with `.accessibilityElement(children:)`;
#   - every window this app opens sets an accessibility identifier, so UI
#     automation has a stable handle on it.
#
# CANNOT prove:
#   - that the name is *good*. "Button" passes; so does a label that lies.
#   - that the runtime AX tree is well formed. SwiftUI decides which attribute
#     a label lands in, and that has changed between macOS releases.
#   - reading order, focus order, or that a hidden decoration was the right
#     thing to hide. Those need a human with VoiceOver on.
#   - anything about AppKit views, menus, or the status item.
# A green run here means "nothing shipped nameless", not "this app is
# accessible". `--runtime` narrows the second gap on a developer machine; CI has
# no GUI session and no menu-bar app to drive, so the static gate is the one
# that runs there.
#
# ---------------------------------------------------------------------------
# POLICED
# ---------------------------------------------------------------------------
# Crisp/Views/*.swift, minus the explicit opt-outs in unpoliced_views(). Same
# inversion as check-boundaries.sh: a new view is policed the day it lands, and
# opting one out is a visible line here that a reviewer has to agree with.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# shellcheck source=lib/swift-code.sh
. "$ROOT/scripts/lib/swift-code.sh"

# --- shared reporting -------------------------------------------------------

VIOLATIONS=0

report() { # file line message
	VIOLATIONS=$((VIOLATIONS + 1))
	[ -n "${GITHUB_ACTIONS:-}" ] && echo "::error file=$1,line=$2::$3"
	echo "  $1:$2: $3" >&2
}

# --- what counts as a control, and as a name --------------------------------

# The SwiftUI controls a user can operate. `Menu` is included because its label
# is frequently a bare chevron `Image`, which is exactly the case that ends up
# nameless. `Link`/`NavigationLink` are absent: this app has none.
CONTROLS='Button|Slider|Toggle|TextField|SecureField|Picker|Stepper|ColorPicker|DatePicker|Menu'

# Views that predate this fork and are frozen rather than fixed (AGENTS.md §3.2
# freezes the private-API features; their panels came with them). The gate's job
# is to stop the fork's own windows from joining them, not to rewrite upstream.
# Every line is a deliberate opt-out — deleting one and fixing the file is
# always the better move.
unpoliced_views() {
	cat <<-'EOF'
		Crisp/Views/ImageAdjustmentView.swift
		Crisp/Views/PresetListView.swift
		Crisp/Views/SavePresetView.swift
		Crisp/Views/ScreenEffectsView.swift
		Crisp/Views/SystemColorView.swift
		Crisp/Views/VirtualDisplayView.swift
	EOF
}

policed_views() {
	local file excluded
	excluded=" $(unpoliced_views | tr '\n' ' ')"
	find Crisp/Views -name '*.swift' | sort | while IFS= read -r file; do
		case "$excluded" in
		*" $file "*) continue ;;
		esac
		echo "$file"
	done
}

# Emits "line:kind:detail" for each finding in one file.
#
# A control is named when the constructor carries a literal label
# (`Button("Next")`, `Toggle("Reapply", isOn:)`), or builds one from a `Text` or
# `Label` in its label closure (`Text(display.name)` names a checkbox just as
# well as a literal does), or is given `.accessibilityLabel(...)` in its own
# modifier chain. `.accessibilityHidden(true)` also satisfies it: a control
# deliberately removed from the AX tree needs no name, and saying so is a
# decision, not an omission.
#
# What this misses, and does so on purpose: a `Button` whose label closure holds
# only an `Image`. That is the shape that ends up nameless in practice, and it
# is the one the gate is really hunting.
#
# "Its own modifier chain" is approximated by the lines from the constructor up
# to (but not including) the next constructor at the same or shallower indent,
# capped at MAX_CHAIN lines. That is a heuristic: it can credit a control with a
# label that belongs to something nested inside it. The bias is deliberate — a
# gate that cries wolf gets switched off, and the case this defends against
# (nobody wrote a name anywhere) survives the approximation.
MAX_CHAIN=60

scan_controls() { # file
	code_only "$1" | awk -v controls="$CONTROLS" -v maxchain="$MAX_CHAIN" '
	function indent(s,   i) {
		for (i = 1; i <= length(s) && substr(s, i, 1) ~ /[ \t]/; i++) { }
		return i - 1
	}
	{ line[NR] = $0 }
	END {
		declRe = "(^|[^A-Za-z0-9_.\"])(" controls ")[ \t]*[({]"
		for (n = 1; n <= NR; n++) {
			if (line[n] !~ declRe) continue
			match(line[n], declRe)
			text = substr(line[n], RSTART, RLENGTH)
			gsub(/^[^A-Za-z]+|[ \t]*[({]$/, "", text)
			kind = text
			base = indent(line[n])

			# A literal first argument names the control outright.
			named = (line[n] ~ "(" controls ")[ \t]*\\([ \t]*\"")
			collapsed = 0

			for (m = n; m <= NR && m < n + maxchain; m++) {
				if (m > n) {
					# Stop at the next control that is not nested inside this one.
					if (line[m] ~ declRe && indent(line[m]) <= base) break
					# Stop when the expression is over: a statement at or above
					# this indent that is neither a modifier nor a closer.
					if (line[m] ~ /[^ \t]/ && indent(line[m]) <= base &&
					    line[m] !~ /^[ \t]*[.})\]]/) break
				}
				if (line[m] ~ /\.accessibilityLabel[ \t]*\(/) named = 1
				if (line[m] ~ /\.accessibilityHidden[ \t]*\([ \t]*true/) named = 1
				# A Text/Label in the label closure names the control \u2014 but the
				# same Text inside .accessibilityValue()/.accessibilityHint() is
				# what the control *reads*, not what it is called, and crediting
				# it would let a valued-but-nameless slider through.
				if (line[m] ~ /(Text|Label)[ \t]*\(/ &&
				    line[m] !~ /\.accessibility(Value|Hint)[ \t]*\(/) named = 1
				if (line[m] ~ /\.accessibilityElement[ \t]*\([ \t]*children:/) collapsed = 1
			}
			if (!named) print n ":unnamed:" kind
			if (collapsed) print n ":collapsed:" kind
		}
	}'
}

# --- gate 1: no nameless control --------------------------------------------

gate_named_controls() {
	local file files=() excluded=() total=0 hit line kind
	echo "==> Gate: every interactive control is named in source"

	while IFS= read -r file; do files+=("$file"); done < <(policed_views)
	while IFS= read -r file; do excluded+=("$file"); done < <(unpoliced_views)

	# A listed opt-out that no longer exists silently protects nothing, and worse,
	# keeps excluding a name a future file could reuse.
	for file in "${excluded[@]}"; do
		[ -f "$file" ] && continue
		report "$(basename "$0")" 1 \
			"'$file' is opted out in $(basename "$0") but no longer exists — drop the line from unpoliced_views()"
	done

	for file in "${files[@]}"; do
		while IFS= read -r hit; do
			line="${hit%%:*}"
			hit="${hit#*:}"
			kind="${hit#*:}"
			case "${hit%%:*}" in
			unnamed)
				report "$file" "$line" \
					"$kind has no name: give it a literal label ($kind(\"…\")) or an explicit .accessibilityLabel(…). Without one there is nothing for AXTitle/AXDescription/AXAttributedDescription to carry."
				;;
			collapsed)
				report "$file" "$line" \
					".accessibilityElement(children:) on a $kind demotes it to AXUnknown — it stops being a control for VoiceOver and automation. Label the $kind directly instead."
				;;
			esac
		done < <(scan_controls "$file")
		total=$((total + $(scan_controls "$file" | wc -l | tr -d ' ')))
	done

	echo "    ${#files[@]} view file(s) checked, ${#excluded[@]} opted out"
}

# --- gate 2: every window is findable ---------------------------------------

# An LSUIElement app has no menu bar and no Dock icon, so a window it opens is
# reachable only by whatever handle it publishes. `setAccessibilityIdentifier`
# is the one attribute measured to survive SwiftUI's hosting view intact, which
# makes it the only reliable way for a UI test or a support script to say "the
# Diagnostics window" and mean it.
#
# Only `.titled` windows are policed. The app's other four `NSWindow`s (the
# brightness, EDR and notch overlays, and the arrangement highlight) are
# `.borderless` with `ignoresMouseEvents = true`: decorations that are correctly
# absent from the interaction model, and naming them would put four unusable
# entries in front of anyone navigating by window.
gate_window_identifiers() {
	local file files=() titled ids line
	echo "==> Gate: every titled window sets an accessibility identifier"

	while IFS= read -r file; do files+=("$file"); done < <(grep -rl 'NSWindow(' Crisp --include='*.swift' | sort)

	for file in "${files[@]}"; do
		titled=$(scan_titled_windows "$file" | wc -l | tr -d ' ')
		[ "$titled" -eq 0 ] && continue
		ids=$(code_only "$file" | grep -c 'setAccessibilityIdentifier(' || true)
		[ "$ids" -ge "$titled" ] && continue
		while IFS= read -r line; do
			report "$file" "$line" \
				"titled NSWindow with no setAccessibilityIdentifier(…) — an LSUIElement app's window has no other stable handle, and AXIdentifier is the one attribute SwiftUI's hosting view passes through unchanged"
		done < <(scan_titled_windows "$file")
	done

	echo "    ${#files[@]} window-owning file(s) checked"
}

# Line numbers of `NSWindow(` constructions whose styleMask includes `.titled`.
# The style mask is usually on a later line than the constructor, so this looks
# ahead over the argument list rather than at the single line.
scan_titled_windows() { # file
	code_only "$1" | awk '
	{ line[NR] = $0 }
	END {
		for (n = 1; n <= NR; n++) {
			if (line[n] !~ /NSWindow[ \t]*\(/) continue
			for (m = n; m <= NR && m < n + 10; m++) {
				if (line[m] ~ /styleMask:/) {
					if (line[m] ~ /\.titled/) print n
					break
				}
			}
		}
	}'
}

# --- optional runtime probe -------------------------------------------------

# The honest companion to the static gate: it asks the real AX server what the
# running app publishes. It needs a GUI session, an installed and running Crisp,
# and an Automation grant for the calling terminal, so it can only ever be
# advisory — it SKIPs rather than fails when any of those is missing, and it is
# never part of `make check`.
runtime_probe() {
	echo "==> Runtime probe (advisory)"
	if [ -z "${TERM_SESSION_ID:-}" ] && [ -z "${SSH_TTY:-}" ] && ! pgrep -qx Crisp 2>/dev/null; then
		echo "    SKIP: no GUI session"
		return 0
	fi
	if ! pgrep -qx Crisp 2>/dev/null; then
		echo "    SKIP: Crisp is not running (open it, then re-run)"
		return 0
	fi

	local out
	out="$(osascript -e 'tell application "System Events" to tell process "Crisp" to get count of windows' 2>&1)" || {
		echo "    SKIP: System Events refused (grant this terminal Automation access) — $out"
		return 0
	}
	case "$out" in
	0 | '')
		echo "    SKIP: Crisp has no window open (open Diagnostics or the Setup Guide, then re-run)"
		return 0
		;;
	esac

	echo "    $out window(s) visible to the AX server"
	# Reported, never asserted \u2014 in either direction. System Events reads
	# AXTitle/AXDescription, which SwiftUI does not populate for buttons on
	# macOS 26 (see the header), so a failure here would say more about System
	# Events than about this app; and the installed build may predate the
	# identifiers in the working tree. Informational only, hence the `|| true`.
	local ids
	ids="$(osascript -e 'tell application "System Events" to tell process "Crisp" to get value of attribute "AXIdentifier" of every window' 2>/dev/null || true)"
	echo "    window identifiers: ${ids:-(none published — old build, or a window type that sets none)}"
	return 0
}

# --- self-test --------------------------------------------------------------

# A gate that has silently stopped detecting anything looks exactly like a clean
# tree. Every detector runs against known-bad fixtures on every CI run.
SELF_TEST_STATUS=0

expect_findings() { # expected actual label
	[ "$2" -eq "$1" ] || {
		echo "  self-test FAILED: $3 — expected $1 finding(s), got $2" >&2
		SELF_TEST_STATUS=1
	}
}

self_test() {
	local tmp count
	tmp="$(mktemp -d)"
	trap 'rm -rf "$tmp"' RETURN
	echo "==> Self-test: the detectors still detect"
	SELF_TEST_STATUS=0

	cat >"$tmp/Named.swift" <<-'EOF'
		import SwiftUI
		struct V: View {
		    @State private var on = false
		    var body: some View {
		        VStack {
		            Button("Next") { }
		            Toggle("Reapply on reconnect", isOn: $on)
		            Slider(value: .constant(0.5))
		                .accessibilityLabel("Display brightness")
		            Button(action: { }) {
		                Image(systemName: "gear")
		            }
		            .accessibilityLabel("Settings")
		        }
		    }
		}
	EOF

	cat >"$tmp/Unnamed.swift" <<-'EOF'
		import SwiftUI
		struct V: View {
		    var body: some View {
		        VStack {
		            Button(action: { }) {
		                Image(systemName: "gear")
		            }
		            Slider(value: .constant(0.5))
		        }
		    }
		}
	EOF

	# The near miss that got past an earlier version of the detector: a slider
	# that says what it reads but never what it is. The Text belongs to the
	# value, not to a label, and must not be credited as a name.
	cat >"$tmp/ValuedNotNamed.swift" <<-'EOF'
		import SwiftUI
		struct V: View {
		    var body: some View {
		        Slider(value: .constant(0.5))
		            .accessibilityValue(Text(verbatim: "2560x1440"))
		    }
		}
	EOF

	cat >"$tmp/Collapsed.swift" <<-'EOF'
		import SwiftUI
		struct V: View {
		    var body: some View {
		        Button("Next") { }
		            .accessibilityElement(children: .ignore)
		            .accessibilityLabel("Next")
		    }
		}
	EOF

	cat >"$tmp/Prose.swift" <<-'EOF'
		import SwiftUI
		// A Button(action:) with a bare Image would be unnamed, but this is prose.
		/* Slider(value: $x) in a block comment is prose too. */
		struct V: View {
		    var body: some View { Text("nothing to operate") }
		}
	EOF

	count=$(scan_controls "$tmp/Named.swift" | wc -l | tr -d ' ')
	expect_findings 0 "$count" "the detector fired on controls that are properly named"

	count=$(scan_controls "$tmp/Unnamed.swift" | grep -c ':unnamed:' || true)
	expect_findings 2 "$count" "the detector missed a nameless Button and Slider"

	count=$(scan_controls "$tmp/ValuedNotNamed.swift" | grep -c ':unnamed:' || true)
	expect_findings 1 "$count" "a Text inside .accessibilityValue() was credited as the control's name"

	count=$(scan_controls "$tmp/Collapsed.swift" | grep -c ':collapsed:' || true)
	expect_findings 1 "$count" "the detector missed .accessibilityElement(children:) on a Button"

	count=$(scan_controls "$tmp/Prose.swift" | wc -l | tr -d ' ')
	expect_findings 0 "$count" "the comment stripper stopped ignoring controls named only in prose"

	[ "$SELF_TEST_STATUS" -eq 0 ] &&
		echo "    detectors OK (named, nameless, valued-but-nameless, collapsed control, prose)"
	return "$SELF_TEST_STATUS"
}

# --- entry point ------------------------------------------------------------

case "${1:-all}" in
named-controls) gate_named_controls ;;
window-identifiers) gate_window_identifiers ;;
--self-test)
	self_test
	exit $?
	;;
--runtime)
	runtime_probe
	exit 0
	;;
all)
	self_test
	gate_named_controls
	gate_window_identifiers
	;;
*)
	echo "usage: $0 [all|named-controls|window-identifiers|--self-test|--runtime]" >&2
	exit 2
	;;
esac

if [ "$VIOLATIONS" -ne 0 ]; then
	echo "" >&2
	echo "check-accessibility: $VIOLATIONS violation(s). A control nobody named is a control nobody who cannot see it can use." >&2
	exit 1
fi
echo "check-accessibility: clean"
