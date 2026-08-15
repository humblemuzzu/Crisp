# DDC/CI on Apple Silicon — how it works here, and the verification evidence

This is the technical core of the fork: how external-display control works on
modern macOS, why it is safe, and exactly what was verified against the BenQ
MA320U before any of it shipped.

---

## 1. What DDC/CI is

Display Data Channel Command Interface — a VESA standard for controlling a
monitor (brightness, contrast, input source, volume, power, …) over the same
cable that carries the video signal. On DisplayPort it rides the AUX channel;
on HDMI, the DDC (I2C) lines. Features are addressed by **VCP codes**:

| VCP | Feature | Used by this fork |
|---|---|---|
| 0x10 | Brightness | yes |
| 0x12 | Contrast | yes (added) |
| 0x60 | Input source | yes (added) |
| 0x62 | Speaker volume | yes |
| 0xD6 | Power | read-only (crispctl) |
| 0x6C/0x6D/0x6E | Red/Green/Blue gain | read-only (crispctl) |

## 2. The two IOKit routes

On Apple Silicon (this machine: M4 Pro), an external display appears in
IORegistry as a `DCPAVServiceProxy` service with `Location == "External"`,
whose user client exposes raw I2C to the display's DDC/CI controller. On Intel
the older `IOFramebuffer` I2C interfaces are used instead. Both routes are
**pure IOKit** — they talk to the display controller driver, never to
WindowServer. Neither can crash WindowServer; the worst failure is an I2C
error return.

**Route A — IOAVService (arm64, what we use):**

```
IOAVServiceCreateWithService(kCFAllocatorDefault, service)
IOAVServiceWriteI2C(svc, 0x37, 0x51, buf, len)   // chip 0x37 (7-bit), offset 0x51
IOAVServiceReadI2C(svc, 0x37, 0, reply, len)
```

These symbols are exported by IOKit.framework (in its tbd) but not declared in
public headers; `Crisp/Crisp-Bridging-Header.h` declares them. MonitorControl
ships the same functions. This is the only "undocumented" surface in the DDC
path, and it is a user client to the display controller — not WindowServer.

**Route B — public IOI2CRequest (x86_64, kept for parity):**
`IOFBGetI2CInterfaceCount` / `IOFBCopyI2CInterfaceForBus` /
`IOI2CInterfaceOpen` / `IOI2CSendRequest` with `sendAddress 0x6E`,
`replyAddress 0x6F`, `kIOI2CDDCciReplyTransactionType`. Declared in the public
`IOKit/i2c/IOI2CInterface.h`.

## 3. Wire formats (exactly as implemented)

Get-VCP write packet (single-byte send):

```
[0x80|2, 0x01, vcpCode, checksum]
checksum = XOR(0x37 << 1, all preceding bytes)     // 0x6E seed
```

Set-VCP write packet:

```
[0x80|4, 0x03, vcpCode, valueHi, valueLo, checksum]
checksum = XOR(0x6E ^ 0x51, all preceding bytes)   // 0x3F seed
```

Reply (11 bytes), validated before any value is trusted:

```
[0] = 0x6E (source addr)
[1] = 0x88 (0x80|8 length)
[2] = 0x02 (get-VCP reply opcode)
[3] = 0x00 (result code)
[4] = vcpCode (echo — must match what we asked)
[5] = VCP type
[6..7] = max value (big-endian)
[8..9] = current value (big-endian)
[10] = checksum: XOR(0x50, bytes 0..9)
```

`DDCService.arm64Read` additionally rejects `max == 0` and garbage frames
because a wedged DDC controller can stream noise that ack's the I2C read; a
bogus "max" would compress the usable slider range. Reads are quarantined
after 6 consecutive failures for 10 minutes. Writes are coalesced (latest
wins, ≥50 ms apart) so a slider drag can't flood the I2C bus the features
share.

## 4. Empirical verification (this machine, BenQ MA320U)

All of the following were executed live; reads and writes round-tripped.

Initial read state (BetterDisplay had parked hardware brightness at 0):

```
brightness   0/100
contrast    50/100
volume      44/50
input       19/19
gain r/g/b  50/100 each
```

Write round-trips through the exact code path the app uses
(`DDCService.writeAsync` → IOAVService):

```
set contrast 48 -> get -> 48/100  (then restored to 50)
set volume   43 -> get -> 43/50   (then restored to 44)
set brightness 50 -> get -> 50/100 (then restored to 0)
set input 19 (no-op, current value) -> accepted, input unchanged (19/19)
```

Both independent probes agreed (our standalone `probe.c` in the
`benqctl/` scratch project, and Crisp's own `scripts/ddc-probe.swift`):
same channel (vendor 2513 / BNQ, product 32885, serial 16843009), same values,
`headerOK=true checksumOK=true` on every read.

## 5. Why this cannot reproduce the BetterDisplay crash

The crash class is private-framework display mutation (`SkyLight`,
`CoreBrightness`, `CoreDisplay`, `DisplayServices`, `OSD`). The DDC path above
performs none of it: discovery is IORegistry walks, control is I2C writes to
the display controller, and a disconnect shows up as an I2C error or a missing
service — both handled as no-ops. `AGENTS.md` §3 encodes this as a hard
constraint.
