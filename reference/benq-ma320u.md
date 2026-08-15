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

## Capabilities string (VCP 0xF3, read-only)

Read live with `./crispctl-bin capabilities` on macOS 26 / M4 Pro, verbatim:

```
(prot(monitor)type(LCD)model(MA320U)cmds(01 02 03 07 0C E3 F3)vcp(02 04 10 12 13(00 01) 14(04 05 08 0B) 16 18 19 1A 59 5A 5B 5C 5D 5E 5F(00 02 03) 60(0F 11 12 15) 62 67(00 01) 68(00 01) 69(00 01) 6A(00 01) 72(50 64 77 78 8C A0) 81(00 01 02) 86(01 02 05) 87 8D(01 02) 94(01 02 03 04 05) 9B 9C 9D 9E 9F A0 AA(01 02 03) BE C1 C2 C9 CA(01 02 03) CC(01 02 03 04 05 06 07 09 0A 0B 0D 0E 0F 12 14 1A 1E 1F) DC(0A 0F 12 22 23 27 28 32) DF E5 EE(00 01 02) EF(00 01) F0(00 01 02) F6(00 01) FD(00 03 04))mswhql(1)asset_eep(40)mccs_ver(2.2))
```

50 VCP codes; `mccs_ver(2.2)`; two vendor fields (`mswhql`, `asset_eep`) that
the spec tells hosts to discard. Notable:

- **The advertised 0x60 values are `0F 11 12 15`, and the panel is on `19`.**
  The monitor omits the input it is currently using from its own capabilities
  string. This is the concrete case behind the rule that a capabilities string
  may only widen what Crisp offers — filtering the input menu by this list would
  hide the port the Mac is attached through.
- `0x87` (sharpness), `0x8D` (audio mute), `0xCA` (OSD control) and `0xD6`
  (power) are advertised; Crisp has no control for any of them and reads them
  only where a human asks.
- 39 of the 50 codes are vendor-private or outside the registry (`0x59`–`0x5F`,
  `0x67`–`0x6A`, `0x9B`–`0xA0`, `0xCC`, `0xDC`, `0xE5`, `0xEE`–`0xFD`). Nothing
  is known about them and nothing should be written to them.

The string is a list of things **worth measuring**, never a list of things that
work: the only proof is a `getvcp`/`setvcp` round trip on the hardware.

## Input-source caveat

The MA320U reports current input `19`. Under the VESA MCCS 0x60 table, `0x13`
(19) is "DVI-10" — clearly not the monitor's meaning (it has USB-C, DP,
HDMI-1, HDMI-2). BenQ uses its own numbering on several models, and its own
capabilities string does not list `19` at all (see above), so the string is no
help in decoding it either. The app shows the raw code for unknown values and
offers the common VESA codes; the mapping for this monitor is **not calibrated
yet** and should not be guessed in code.
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
