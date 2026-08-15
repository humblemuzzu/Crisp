# DDC hardware controls beyond brightness (fork additions)

This fork adds four things Crisp upstream lacked, all on the same IOKit-only
DDC/CI path (`DDCService`): **hardware contrast**, **input-source switching**,
**per-display DDC persistence + reconnect reapply**, and a **CLI**.

## Why

The original use case: a BenQ MA320U driven by BetterDisplay, which crashed the
Mac repeatedly. BetterDisplay's prefs showed the cause: it pushed the monitor's
*hardware* (DDC) brightness to 0 and did all visible dimming in *software*
(CoreBrightness/CoreDisplay shaders) — private WindowServer-adjacent APIs.
Crisp's brightness path never touches those: it writes the monitor's real
backlight over DDC/CI I2C (IOAVService on Apple Silicon, the same IOKit stack
verified against the MA320U in `scripts/ddc-probe.swift` and via `crispctl`).

## What was added

- **`Crisp/Services/DDCFeatureService.swift`** — contrast (VCP 0x12),
  input-source (VCP 0x60), and per-display persistence (keyed by the stable
  `displayUUID`, never the volatile CGDirectDisplayID) of brightness, contrast,
  volume and input, plus reconnect re-application with a 1% deadband.
  Persistence keys: `crisp.ddcState.<uuid>.<field>`.
- **`DisplayInfo`** — `contrast`/`contrastSupported`, `inputSource`/
  `inputSourceSupported`/`inputSourceMax` published state.
- **`VolumeService`** — persists the level per UUID on change.
- **`SettingsService`** — `reapplyDDCOnReconnect` global toggle (default on;
  input re-apply is a separate per-display toggle, default off, because a
  stale input code blanks the screen).
- **`Crisp/Views/DDCFeatureViews.swift`** — `ContrastSliderView` (mirrors the
  volume slider) and `InputSourceMenuRow` (current input + common VESA codes +
  per-display reapply toggle), wired into `DisplayHeaderBlock`.
- **`DisplayManager`** — probes contrast/input on display add (with the same
  3s delayed re-read brightness/volume already use) and calls
  `DDCFeatureService.reapplyDDCStateIfNeeded` after reconnect settle.
- **`crispctl/`** — CLI sharing the app's exact DDC stack:
  `list`, `get <feature>`, `set <feature> <value>`, `capabilities`, `watch`.
  Features: brightness, contrast, volume, input, power, red, green, blue.
  Build with `make crispctl`; install via `make crispctl` + copy `crispctl-bin`.
- **`Crisp/Models/DDCFeatureRegistry.swift`** — the VCP codes Crisp knows, as
  data: code, value shape, MCCS access, whether writing it is destructive and
  what the hazard is. Adding a feature is an entry in one table rather than a
  constant, a read path, a write path and a view. Seeded with the four that
  shipped plus colour temperature/preset (0x0C/0x14), RGB gain (0x16/0x18/0x1A),
  RGB black level (0x6C/0x6E/0x70), sharpness (0x87), audio mute / screen blank
  (0x8D), OSD lock (0xCA), power mode (0xD6), VCP version (0xDF), restore
  factory defaults (0x04) and display technology type (0xB6).
- **`Crisp/Models/DDCCapabilities.swift`** — a tolerant parser for the DDC/CI
  capabilities string (command `0xF3`, reply `0xE3`), plus the fragment
  reassembly rules. It never throws and never crashes: the outcome is
  `valid | usable | invalid` plus diagnostics plus the raw string. Every
  tolerance rule is pinned by a verbatim capture from a real monitor — the AOC
  C24G2 (no spaces anywhere), the ASUS MG279 (`model LCDPB287`, whose
  unparenthesized value costs ddcutil the rest of the string), the Lenovo Legion
  27U-10 (value lists nested three deep), the Apple Cinema Display A1082 (no
  outer parens), the Samsung S32D850 (a zero-length string).
- **`Crisp/Models/DDCFeatureDiscovery.swift`** — the discovery rule, as a test
  rather than a comment: user override → quirks database → live probe →
  capabilities string → MCCS default, where **the capabilities string may only
  widen what is offered, never narrow it, and never override a live probe**, and
  where anything unproven is read-only and anything destructive needs the user
  to have asked for that write. ddcui greys controls out from this string; that
  is the counter-example, not the model.

## Verified against a BenQ MA320U (macOS 26, Apple Silicon)

- reads: brightness 0/100, contrast 50/100, volume 44/50, input 19/19
- writes: contrast 48 → readback 48 → restore 50; volume 43 → 43 → 44;
  input no-op write accepted (no screen switch)
- capabilities (`./crispctl-bin capabilities`, read-only), verbatim:

  ```
  (prot(monitor)type(LCD)model(MA320U)cmds(01 02 03 07 0C E3 F3)vcp(02 04 10 12 13(00 01) 14(04 05 08 0B) 16 18 19 1A 59 5A 5B 5C 5D 5E 5F(00 02 03) 60(0F 11 12 15) 62 67(00 01) 68(00 01) 69(00 01) 6A(00 01) 72(50 64 77 78 8C A0) 81(00 01 02) 86(01 02 05) 87 8D(01 02) 94(01 02 03 04 05) 9B 9C 9D 9E 9F A0 AA(01 02 03) BE C1 C2 C9 CA(01 02 03) CC(01 02 03 04 05 06 07 09 0A 0B 0D 0E 0F 12 14 1A 1E 1F) DC(0A 0F 12 22 23 27 28 32) DF E5 EE(00 01 02) EF(00 01) F0(00 01 02) F6(00 01) FD(00 03 04))mswhql(1)asset_eep(40)mccs_ver(2.2))
  ```

  50 VCP codes, `mccs_ver(2.2)`, and two vendor fields (`mswhql`, `asset_eep`)
  that the spec says a host should discard. Two things in it are worth keeping:

  - **It advertises 0x60 values `0F 11 12 15`, and the panel is on `19`.** The
    monitor's own capabilities string omits the input it is currently using.
    Anything that filtered the input menu by this list would hide the port the
    user is looking through, which is why capabilities may only widen.
  - It advertises `0x87` (sharpness) and 39 codes Crisp has no name for, which
    is the list of things worth measuring next — not a list of things that work.

## Automation

Shortcuts (App Intents), a `crisp://` URL scheme and user-assigned global
hotkeys, all going through one decision core so they cannot drift into three
policies — including the rule that **no automation surface can perform a
destructive DDC write without a confirmation dialog**, with no bypass parameter
from any of them. There is deliberately no HTTP server. See
[`docs/automation.md`](automation.md).

## Notes

- Input labels use the VESA MCCS 0x60 table; some BenQ models use their own
  numbering (the MA320U reports current input `19`), so the menu shows the raw
  code for unknown values. Calibrate per monitor; the raw value is always
  selectable.
- `reapplyInput` is off by default and deliberately not part of the global
  reapply toggle.
- Crisp's own advanced features that use private frameworks (physical display
  toggle, CGS resolution switching, HDR boost) are untouched and isolated
  behind `dlopen`; the DDC path used here has no WindowServer interaction.
