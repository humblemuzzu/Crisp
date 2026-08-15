<div align="center">

<img src="docs/icon.png" width="128" alt="Crisp icon">

# Crisp — DDC fork

**Hardware control of your external monitor, over the cable, with no private APIs.**

A fork of [Crisp](https://github.com/didriksg/Crisp) that adds DDC contrast,
input switching, per-display persistence and a command-line tool.

[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)](#requirements)
[![License](https://img.shields.io/github/license/didriksg/Crisp?color=3fb950)](LICENSE)

</div>

---

Crisp is a menu-bar app for controlling external monitors on macOS. It talks to
the monitor over **DDC/CI** — the control channel built into every DisplayPort
and HDMI cable — so brightness moves the monitor's actual backlight, the way its
own buttons do, rather than drawing a dark filter over the picture.

This fork exists because the alternative broke a machine. The upstream project
is excellent and actively maintained; what it lacked was hardware contrast,
input switching and per-display persistence, and what the closed-source
alternative had was a software-dimming path built on private,
WindowServer-adjacent frameworks that hard-locked macOS 26 seven times in a row.
The whole story, with the binary-level evidence, is in
[`AGENTS.md`](AGENTS.md) and [`reference/`](reference/).

## What it does

- **Brightness** — DDC/CI VCP `0x10`, the monitor's real backlight. The
  brightness keys (F1/F2) can be routed to the monitor under the pointer, to all
  displays, or to a chosen subset.
- **Contrast** — VCP `0x12`, the monitor's own contrast, not a gamma curve.
- **Volume** — VCP `0x62`, for monitors with built-in speakers, with the
  keyboard volume keys mapped to the monitor when it is the audio output.
- **Input source** — VCP `0x60`, switch which machine the monitor shows. Guarded:
  a code that has not been confirmed on real hardware asks first, because writing
  the wrong one blanks the screen and only the monitor's own buttons bring it
  back.
- **Persistence and reconnect** — brightness, contrast and volume are re-applied
  when a display reconnects, keyed on the display's stable UUID rather than the
  `CGDirectDisplayID` macOS reshuffles. Re-applying the *input* is opt-in per
  display and off by default, for the reason above.
- **A monitor quirks database** — real monitors do not follow the MCCS standard.
  What each model actually does lives in JSON, not in Swift; see
  [`Crisp/Resources/quirks/README.md`](Crisp/Resources/quirks/README.md).
- **`crispctl`** — a CLI sharing the app's exact DDC stack, for scripting and for
  finding out what your monitor answers.
- **A first-run guide** — four screens: what the app controls, the one permission
  the brightness keys need (with live status), what it detected on your displays,
  and where the app lives. Skippable, shown once, reopenable from Settings.

Everything upstream ships is still here: HiDPI scaling, presets, display
arrangement, virtual displays, colour profiles, auto-brightness. Those are
documented at [the upstream project](https://github.com/didriksg/Crisp); this
README covers what the fork adds and what it refuses to do.

## What it does not do

Being explicit about this is the point of the fork, not modesty.

- **No private frameworks in the DDC path.** No `CoreBrightness`, `CoreDisplay`,
  `SkyLight`, `DisplayServices`, `OSD`, `BezelServices` or `IOMobileFramebuffer`
  in `DDCService`, `DDCFeatureService`, `VolumeService`, the external branch of
  `BrightnessService`, or `crispctl`. This is not a promise, it is a build gate:
  `make boundaries` fails the build if one appears. The single documented
  exception is the `IOAVService*` family, which is undocumented but exported by
  IOKit and only ever talks to the display controller's I²C bus — the same call
  MonitorControl ships.
- **No shader-based software dimming.** Where Crisp does dim in software (below
  the slider's midpoint, because a monitor's backlight does not reach zero, and
  on displays with no DDC channel at all), it uses `CGSetDisplayTransferByTable`,
  a public CoreGraphics call. It never goes through the private shader path that
  caused the crash that started this fork.
- **No new features on upstream's private-API code.** Upstream's physical
  display disconnect (SkyLight), CGS mode switching, HDR boost and the native OSD
  HUD exist and still work; they are `dlopen`'d and gated, and this fork
  deliberately freezes them rather than building on them.
- **No DDC where the hardware has none.** The Apple Studio Display speaks USB
  HID, not DDC/CI; DisplayLink docks and some MST hubs carry no I²C at all; and
  virtual, AirPlay and Sidecar screens have no backlight to drive. Crisp falls
  back to the colour table (or a dim overlay) on those, and — importantly — says
  so, in the first-run guide and on the slider itself, instead of leaving you
  with a control that moves and does nothing.
- **No hardware claims it cannot back up.** The only monitor this fork has been
  verified against end to end is a **BenQ MA320U** on Apple Silicon / macOS 26.
  DDC is standard enough that other monitors are expected to work, and generic
  enough that some will not. If yours misbehaves, the quirks database is where
  the fix goes.

## Requirements

- macOS 14 (Sonoma) or later. Developed and verified on macOS 26, Apple Silicon.
- An external monitor that implements DDC/CI, connected over DisplayPort, HDMI
  or USB-C. Some monitors ship with DDC/CI switched **off** in their own on-screen
  menu; that is the first thing to check if nothing responds.

## Install

This fork publishes no notarized DMG, so build it from source:

```sh
git clone <this repository>
cd Crisp
./scripts/make-app.sh      # compiles, assembles /Applications/Crisp.app, signs, launches
```

`make-app.sh` needs only the Command Line Tools (no full Xcode). It signs with a
**stable** identity — your Apple Development certificate if you have one,
otherwise a self-signed "Crisp Dev" certificate — and that matters: an ad-hoc
signature changes the code hash on every build, which silently invalidates the
Accessibility grant every time you rebuild. Set `CRISP_SIGN_ID` to choose the
identity explicitly.

The upstream project's `brew install --cask didriksg/tap/crisp` and its signed
DMG install *upstream* Crisp, which does not include this fork's DDC features.

## Accessibility, and the trap that started this

Everything except the brightness keys works with no permissions at all. The keys
are the exception: macOS sends F1 and F2 to the built-in display and nowhere
else, so redirecting them to a monitor means watching for those two keys, and
that needs **System Settings › Privacy & Security › Accessibility**.

The first-run guide asks for it, opens the pane, and shows live whether the tap
actually armed. That last part is the important one:

> **macOS can show Crisp's Accessibility toggle as ON while refusing the
> permission.** TCC records a grant against the bundle id *and* the code
> signature. Rebuild or replace the app with a different signature and the
> toggle stays lit over a dead record — the app looks broken, System Settings
> says it is fine, and the only trace is one line in the unified log. Hours went
> into that.

Crisp detects that state specifically (granted, yet `CGEvent.tapCreate` refused)
and offers a one-click fix that clears the stale record so you can grant it
again. By hand, that is:

```sh
tccutil reset Accessibility com.crisp.app
```

Then switch Crisp back on in the Accessibility pane; the keys arm themselves, no
restart. The panel's Settings section carries the same live status dot.

## crispctl

The CLI links the same DDC stack the app uses, so what it reports is what the
app sees.

```sh
make crispctl                    # builds ./crispctl-bin
./crispctl-bin list              # enumerate displays and their current DDC values
./crispctl-bin get brightness
./crispctl-bin set contrast 48   # writes are acknowledged and read back
./crispctl-bin watch             # poll brightness until interrupted
```

`set input <value>` is the one command to be careful with: it changes which
source the monitor shows, and if nothing is attached to the target input the
screen goes blank until you change it back with the monitor's buttons.

## Building and testing

```sh
make compile          # the app binary (./Crisp-bin); STRICT=1 adds -warnings-as-errors
make crispctl         # the CLI binary (./crispctl-bin)
make boundaries       # the architecture gates below: ~1s, no Xcode, no monitor
make test             # the unit suite (needs full Xcode + `brew install xcodegen`)
make check            # everything CI enforces: lint + boundaries + tests + i18n keys
```

The unit suite is headless by construction — no test host, no bundle loader — so
it needs neither a monitor nor a display server. That is possible because the
decision logic lives in `Crisp/Models/` as pure values: DDC packet framing and
the protocol engine, the brightness fallback ladder, the quirks database parser,
the first-run guide's plan. `make boundaries` enforces the two structural rules
that keep it that way, and explains any violation it finds:

1. no private display frameworks in the DDC path, and
2. no AppKit/Cocoa/SwiftUI imports in `Crisp/Models/`.

For the fast edit-compile-run loop and a distributable DMG, see
[`docs/BUILDING.md`](docs/BUILDING.md). The fork's own feature notes are in
[`docs/fork-ddc-features.md`](docs/fork-ddc-features.md), and the durable
engineering context — why the fork exists, what may not be touched, and how to
verify against real hardware — is in [`AGENTS.md`](AGENTS.md).

## Contributing a monitor

The most useful contribution is not code. Monitors lie about what they support,
and the only way to know is to test on the hardware in front of you.
[`Crisp/Resources/quirks/README.md`](Crisp/Resources/quirks/README.md) explains
the schema and the confidence levels (`verified` means someone watched it work,
and nothing else does). Adding a monitor is a one-file JSON change and needs no
Swift.

Bug reports and pull requests are welcome. Please run `make check` first — it is
what CI runs.

## Localization

Upstream's strings are localized in English and Simplified Chinese. The strings
this fork adds are English-only for now and are tracked in
`scripts/i18n-missing-allowlist.txt`; translations are welcome.

## Credits and license

Upstream [Crisp](https://github.com/didriksg/Crisp) by
[@didriksg](https://github.com/didriksg), which itself began as a fork of
[FreeDisplay](https://github.com/huberdf/FreeDisplay). If you find this fork
useful, the upstream author is the one carrying the project's running costs —
his sponsor links are in the [upstream README](https://github.com/didriksg/Crisp).

[MIT](LICENSE). Portions derived from FreeDisplay remain available under its MIT
terms, reproduced in [ACKNOWLEDGMENTS.md](ACKNOWLEDGMENTS.md).
