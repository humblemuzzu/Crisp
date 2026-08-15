# shellcheck shell=bash
#
# Shared by scripts/check-boundaries.sh and scripts/check-accessibility.sh.
#
# Swift comments are stripped before scanning: this codebase discusses the
# private frameworks it avoids ("not CoreDisplay", "the monitor's OSD menu") and
# shows example UI in prose, and a gate that fails on prose teaches contributors
# to delete the prose.
#
# This walks the line character by character instead of running `sed 's|//.*||'`,
# because sed has no notion of a string literal: `let u = "https://x"` would have
# had everything after the `//` deleted, and any real violation later on that
# line deleted with it. That is not an evasion worry, it is an accident worry —
# a URL in a string is ordinary code. String *contents* are kept (the brightness
# shim's "/System/Library/PrivateFrameworks/..." path is exactly what the
# boundaries gate scans for); only comment text is blanked. Line count is
# preserved so grep -n still points at the real line.
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
