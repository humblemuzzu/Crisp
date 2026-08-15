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
  `list`, `get <feature>`, `set <feature> <value>`, `watch`.
  Features: brightness, contrast, volume, input, power, red, green, blue.
  Build with `make crispctl`; install via `make crispctl` + copy `crispctl-bin`.

## Verified against a BenQ MA320U (macOS 26, Apple Silicon)

- reads: brightness 0/100, contrast 50/100, volume 44/50, input 19/19
- writes: contrast 48 → readback 48 → restore 50; volume 43 → 43 → 44;
  input no-op write accepted (no screen switch)

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
