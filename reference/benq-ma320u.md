# BenQ MA320U — monitor facts and verified values

Everything known about the specific monitor this fork is built for, from
IORegistry EDID/DisplayAttributes and live DDC reads.

## Identity (from EDID / DisplayAttributes)

| Field | Value |
|---|---|
| Manufacturer | BNQ (vendor ID 0x09D1, LegacyManufacturerID 2513) |
| Product | MA320U (product ID 32885, 0x8075) |
| Serial (numeric) | 16843009 |
| Alphanumeric serial | ET94S02041SL0 |
| EDID UUID | 09D17580-0000-0000-1023-0104B5462778 |
| Made | week 16, year 2025 |
| Panel | 3840×2160 (70×39 cm), max 12 bpc |
| Transport | DisplayPort 1.4 (SinkDeviceID `Dp1.4`) |
| HDR | supports HDR static metadata type 1, PQ EOTF |
| Color space | no native sRGB default; custom white point |

Display identity is stable across reconnects; the app persists per-display
state under `displayUUID` (`AEB55F97-FD93-4F8D-AD10-0942959D069C` for this
monitor).

## Verified DDC/CI values (macOS 26, M4 Pro, live reads)

| VCP | Feature | Read | Notes |
|---|---|---|---|
| 0x10 | brightness | 0/100 | parked at 0 by BetterDisplay (software dimming did the visible work) |
| 0x12 | contrast | 50/100 | write-verified: 48 → 48 → 50 |
| 0x60 | input source | 19/19 | current input code 19 — **nonstandard**, see below |
| 0x62 | volume | 44/50 | write-verified: 43 → 43 → 44; monitor has speakers |
| 0xD6 | power | 1/5 | 1 = on |
| 0x6C/0x6D/0x6E | RGB gain | 50/100 | |

## Input-source caveat

The MA320U reports current input `19`. Under the VESA MCCS 0x60 table, `0x13`
(19) is "DVI-10" — clearly not the monitor's meaning (it has USB-C, DP,
HDMI-1, HDMI-2). BenQ uses its own numbering on several models. The app shows
the raw code for unknown values and offers the common VESA codes; the mapping
for this monitor is **not calibrated yet** and should not be guessed in code.
Calibration procedure: with the monitor OSD, note which physical port each
switching attempt lands on; record value → port; then the app can label them.
Until then, input switching is opt-in per display and off by default.

## Behavioral notes

- Hardware DDC brightness persists across unplug/replug (the monitor keeps its
  own OSD value), which is why reconnect reapply uses a deadband and only
  writes when saved differs from live.
- Reads answer reliably over the IOAVService path; the checksum-validated
  reply format is `6e 88 02 00 <vcp> 00 <maxHi> <maxLo> <curHi> <curLo> <cs>`
  (see `ddc-ci.md`).
- `scripts/ddc-probe.swift` and `crispctl list` reproduce all of the above on
  demand; run them before assuming anything changed on a macOS update.
