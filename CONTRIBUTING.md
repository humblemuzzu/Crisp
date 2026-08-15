# Contributing

This is a fork of [Crisp](https://github.com/didriksg/Crisp) that controls
external monitors over DDC/CI. It exists because the alternative it replaced
drove brightness through private, WindowServer-adjacent frameworks and hard-locked
a Mac seven times; the constraints below follow from that, and they are enforced
by the build rather than by review habit. Read [§ The rules](#the-rules) before
writing Swift here — "just use CoreDisplay for this" is not an option in this
repository, and the reason is worth two minutes of your time.

---

## The most useful contribution is not code

Monitors do not follow the MCCS standard. They advertise input codes they never
use, clamp the bottom half of their own brightness range, and answer "supported"
to every feature query. The only way to know what a given model does is for
somebody with that model to measure it — and then write it down.

That is the quirks database: **one JSON file per vendor, no Swift, one file
changed per contribution.**

1. Build the CLI: `make crispctl`
2. `./crispctl-bin list` — this prints the vendor id, product id and the current
   values your monitor reports.
3. Read [`Crisp/Resources/quirks/README.md`](Crisp/Resources/quirks/README.md).
   It is the schema, the measurement procedure, and the meaning of the
   `confidence` field, and it is the authority — this file deliberately does not
   restate it.
4. Add or edit `Crisp/Resources/quirks/<vendor>.json`, and say in the pull
   request what you measured, on which machine and macOS version, and which
   fields are `verified` rather than `reported`.

A shortcut for step 1–3: the app's **Diagnostics** window (menu-bar panel →
Diagnostics) has a **Copy Monitor Report** button per display. It probes the
monitor and gives you a ready-made JSON entry plus the prose to paste into an
issue or PR. You still have to do the measuring; it does the transcription.

### `confidence` is load-bearing, not a formality

`verified` means a human changed the setting on the physical panel and watched
it take effect. `reported` means one person said so. The app treats them
differently: a `reported` input label is shown with a trailing `?` and switching
to it asks for confirmation first. Do not promote an entry to `verified` to make
a dialog go away.

### ⚠️ Never guess an input-source code (VCP `0x60`)

**A wrong `0x60` write costs you your screen.** The monitor switches to a port
with nothing attached, the Mac can no longer reach it over that cable, and the
only recovery is the monitor's own physical buttons. On a wall-mounted monitor
that is a genuinely bad afternoon.

Do not copy a code from another model in the same family. The Samsung U32H750
advertises `0x11`/`0x12`/`0x0F` and actually uses `0x05`/`0x06`/`0x0F`.

Two safe routes, both documented in the quirks README:

- **The in-app wizard** — Input Source ▸ **Calibrate…**. It records the current
  input first, switches with a countdown that undoes itself if you do not
  confirm, and repairs itself after a crash or a disconnect. It is the only path
  in the app that produces `verified` input data.
- **The monitor's own buttons** — `./crispctl-bin get input`, switch ports using
  the monitor's OSD, `get input` again. You get the same answer and never write
  `0x60` at all.

`crispctl set input <value>` exists, and it is the one command in this repository
that can leave you unable to see the machine. Use the wizard.

---

## Building from source

The app compiles with the **Command Line Tools** alone; only the test suite needs
full Xcode.

```sh
make compile          # ./Crisp-bin, a quick build check (STRICT=1 = warnings as errors)
make crispctl         # ./crispctl-bin, the DDC CLI
make boundaries       # the architecture gates — ~1s, no Xcode, no monitor
./scripts/make-app.sh # assemble and launch /Applications/Crisp.app
make test             # the unit suite (needs full Xcode + `brew install xcodegen`)
make check            # everything CI enforces
```

`make-app.sh` signs with a **stable** identity (your Apple Development
certificate, else a self-signed "Crisp Dev" one). That matters more than it
sounds: an ad-hoc signature changes the code hash on every build, and macOS
records the Accessibility grant against the signature, so ad-hoc signing silently
revokes the permission the brightness keys need on every rebuild. Set
`CRISP_SIGN_ID` to choose the identity.

For the fast edit-compile-run loop, see [`docs/BUILDING.md`](docs/BUILDING.md).
For cutting a release, [`docs/RELEASING.md`](docs/RELEASING.md).

## Before you push

```sh
make check
```

That is lint + boundaries + zero-warning builds + tests + localization keys — the
same set CI runs, so failures surface on your machine instead of on the pull
request. To have it run automatically:

```sh
git config core.hooksPath .githooks     # opt in once
git push --no-verify                    # bypass for one push
```

### What the gates enforce, and why

| Gate | Command | Fails when |
|---|---|---|
| Architecture boundaries | `make boundaries` | a private display framework appears in the DDC path, or `Crisp/Models/` imports AppKit/Cocoa/SwiftUI |
| Lint | `make lint` | SwiftLint reports anything at all (`--strict`) |
| Zero warnings | `make compile STRICT=1`, `make crispctl STRICT=1` | any compiler warning, in either binary |
| Tests | `make test` | the headless suite is not green |
| Localization keys | `make loc-check` | the code looks up a string key the String Catalog does not contain |

`scripts/check-boundaries.sh` is worth reading if it ever fails you: its header
lists every policed file, every exception, and the reason each one is an
exception. It also self-tests (`--self-test`), because a detector nobody has
proved still detects is not a gate.

Two things CI checks that `make check` does not: translation completeness
(blocking on `main`, advisory on pull requests — adding an English string never
blocks a contributor) and the `MARKETING_VERSION` guard. **Do not change
`MARKETING_VERSION` in `project.yml`**; the maintainer bumps it at release time
and CI fails a pull request that touches it.

---

## The rules

These are the reason the repository exists. [`AGENTS.md`](AGENTS.md) §2 has the
incident in full — the short version is that a closed-source competitor dimmed
the screen with GPU shaders driven by `CoreBrightness` / `CoreDisplay` /
`SkyLight`, and on macOS 26 that path takes WindowServer down with it. A DDC-only
app cannot hit that failure class *by construction* — but only for as long as
nobody wires a private framework into the DDC path.

1. **No private frameworks in the DDC path.** No `SkyLight`, `CoreBrightness`,
   `CoreDisplay`, `DisplayServices`, `OSD`, `BezelServices` or
   `IOMobileFramebuffer` in `DDCService`, `DDCFeatureService`, `VolumeService`,
   the external-display branch of `BrightnessService`, or `crispctl`. The one
   exception is the `IOAVService*` family: undocumented, but exported by IOKit,
   and it only talks to the display controller's I²C bus — never to WindowServer.
   If a future macOS drops those symbols the feature must go quietly absent, not
   crash. *Machine-enforced.*
2. **Do not extend upstream's private-API features.** The physical display
   toggle, CGS mode switching, HDR boost and the native OSD HUD exist, are
   `dlopen`'d and gated, and are deliberately frozen. Do not build anything new
   on them.
3. **Persist against `displayUUID`, never `CGDirectDisplayID`.** macOS reassigns
   display IDs across reconnects; UUID-keyed state is the only safe kind.
4. **A display disconnect must be a no-op.** Unplugging a monitor while the app
   runs must never crash, freeze input or wedge DDC. The DDC services quarantine
   wedged reads and drop channels on reconfiguration — keep that discipline.
5. **Zero-warning builds.** *Machine-enforced.*
6. **`Crisp/Models/` stays headless.** No AppKit, Cocoa or SwiftUI imports there.
   CoreGraphics and IOKit are fine (`CGDirectDisplayID` is hardware identity, not
   UI). That purity is what lets DDC framing, the brightness ladder, the quirks
   parser and the calibration state machine be tested with no monitor and no
   display server. *Machine-enforced.*

Rules 1, 5 and 6 fail the build. Rules 2, 3 and 4 are behavioural and are checked
in review — say in your pull request how you satisfied them if your change goes
near them.

---

## Tests

The suite is **headless by construction**: `TEST_HOST` and `BUNDLE_LOADER` are
empty in `project.yml`, so nothing launches, and no test needs a monitor
attached. That is only possible because the decisions live in `Crisp/Models/` as
pure values, with the I/O injected — see how `InputCalibrationDriver` takes the
`0x60` write, the tick source and the display list as closures, which is what
lets a whole calibration session be exercised without ever issuing that write.

Two house conventions, both visible in
[`CrispTests/DDCServiceMatcherTests.swift`](CrispTests/DDCServiceMatcherTests.swift):

- **No `@testable import Crisp`.** The file under test is added to the
  `CrispTests` target's source list in `project.yml` instead. Importing the app
  target would drag in IOKit and the private bridging header and defeat the point.
- **Each test names the mutation it kills**, in a trailing comment:

  ```swift
  /// Serial-0 service; display 5 shares vendor+product, display 2 does not. Correct
  /// byModel matching claims display 5. If byModel were dropped (M1), the service
  /// falls through to Strategy 2 and claims leftovers[0] = display 2, a mis-pair.
  /// Kills mutation M1: "remove the byModel fallback, keep only exact match".
  ```

  A test that passes both before and after a plausible bug is not a test. Say
  which change to the code your test would catch; if you cannot name one, the
  assertion is probably tautological.

Adding a new pure model? Add its path to the `CrispTests` sources in
`project.yml` with a comment saying what decision it holds — that list is the
project's record of what is covered, and a file that quietly stops being covered
is a failure this repo has already paid for once.

Anything that needs real hardware is a `crispctl` command run by hand against a
monitor (AGENTS.md §5). Note in the pull request what you ran and what it printed.

---

## Commits and pull requests

- **Conventional commits**, lowercase, with a scope where it helps:
  `feat(fork): DDC contrast, input source, per-display persistence, crispctl`,
  `fix(gamma): scale the display's own transfer table instead of replacing it`,
  `ci: machine-enforce the architecture rules`, `docs:`, `refactor:`, `chore:`.
  Say what changed and why; the body is where the "why" goes.
- **One concern per pull request.** The template
  ([`.github/PULL_REQUEST_TEMPLATE.md`](.github/PULL_REQUEST_TEMPLATE.md)) asks
  for what/why, how you tested it, and a screenshot for UI changes.
- **New user-facing strings** go in `Crisp/Resources/Localizable.xcstrings`.
  English-only additions are fine — they are tracked in
  `scripts/i18n-missing-allowlist.txt` — and translations are welcome separately.
- **Do not touch `MARKETING_VERSION`** (see above).
- Upstream-relevant fixes are worth sending to
  [didriksg/Crisp](https://github.com/didriksg/Crisp) as well; that project
  carries the running costs and the wider user base.

## Reporting a bug

Open an issue and paste the output of **Diagnostics → Copy Bug Report** (menu-bar
panel → Diagnostics). It captures the app and macOS versions, the Mac model, the
DDC transport, and per display: what the DDC channel is doing, which brightness
path is in use, the read-quarantine state, the matched quirks entry, and each
feature's raw probe. Per-unit identifiers (EDID serial, display UUID) are
**redacted unless you tick the box**, so the default report identifies your
monitor model and nothing about you.

That is exactly the information needed to answer "why is this control missing on
my machine", which is otherwise the hardest question to answer remotely.
