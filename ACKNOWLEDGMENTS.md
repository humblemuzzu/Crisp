# Acknowledgments

This file records where the code came from. It separates **what was ported**
(other people's code, under their licence, cited to file and line) from **what
was learned** (an idea we reimplemented) — that distinction is a licensing
matter, not politeness.

## Crisp (upstream)

This repository is a fork of [Crisp](https://github.com/didriksg/Crisp) by
[@didriksg](https://github.com/didriksg), MIT licensed (`LICENSE`, © 2026 Didrik
Galteland). Everything not attributed below is upstream's, including the DDC/CI
IOKit transport this fork builds on and every feature outside the fork's own
additions (DDC contrast, input-source switching, per-display persistence,
`crispctl`, the quirks database, diagnostics, input calibration, onboarding).
Upstream is actively maintained and carries the project's running costs.

## m1ddc — code ported

[waydabber/m1ddc](https://github.com/waydabber/m1ddc), MIT licensed.

The Apple Silicon **MCDP2900 (MCDP29XX) chip-address path** is ported from it —
the fix that makes DDC work on the built-in HDMI port of Macs that emit
DisplayPort internally and convert it, since those displays do not answer DDC/CI
at the standard `0x37` address at all. From m1ddc commit `a561e56`:

| Ported from | Into |
|---|---|
| `headers/ioregistry.h:15-16` — `DDC_CHIP_ADDRESS_DEFAULT` (`0x37`), `DDC_CHIP_ADDRESS_MCDP29XX` (`0xB7`) | `Crisp/Models/DDCPacket.swift` |
| `sources/ioregistry.m:28` — the `EPICProviderClass` value `AppleDCPMCDP29XX` | `Crisp/Models/DDCPacket.swift` |
| `sources/ioregistry.m:14-36` — `isMCDP29XXProxy`, the single-parent registry lookup, applied at the same point in the flow (`sources/ioregistry.m:252`) | `Crisp/Services/IOKitDDCTransport.swift` |
| `headers/i2c.h:25`, applied in `sources/i2c.m:45` — the 50 ms reply wait an MCDP2900 needs, where 10 ms returned empty replies | `Crisp/Services/IOKitDDCTransport.swift` |

Each of those sites carries the citation in a doc comment, so the provenance
survives in the code and not only here.

Because this is ported code rather than a reimplementation, m1ddc's own notice is
reproduced in full, as its licence requires:

```
MIT License

Copyright (c) 2021 waydabber

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## MonitorControl — approach learned, not code copied

[MonitorControl/MonitorControl](https://github.com/MonitorControl/MonitorControl),
MIT licensed. Nothing was copied; these are reimplementations of strategies it
established:

- **Registry-proximity display matching.** On Apple Silicon the DDC channel
  (`DCPAVServiceProxy`) and the display's identity (`DisplayAttributes` →
  `ProductAttributes`) sit in *sibling* subtrees, so walking up the parent chain
  never finds the identity. MonitorControl's answer — a depth-first IOService
  traversal that pairs each channel with the identity seen closest to it — is the
  strategy `IOKitDDCTransport.buildChannelMapByProximity` implements (with
  vendor/product/serial matching and a traversal-order fallback layered on top,
  in `Crisp/Models/DDCServiceMatcher.swift`).
- **The combined hardware + software brightness model.** One user-facing slider
  split across the DDC backlight and a gamma dimmer at a switchover point,
  because a monitor's backlight does not reach zero. The 50 % external-display
  switchover default and the flat 1/16 key step in
  `Crisp/Models/CombinedBrightness.swift` are the values MonitorControl and
  BetterDisplay both use.
- **Dual-path brightness-key capture** (`NX_SYSDEFINED` aux events plus raw
  keycodes 144/145), which is why the keys keep working in clamshell —
  `Crisp/Services/BrightnessKeyService.swift`.
- The `IOAVService*` family itself is undocumented but IOKit-exported; that
  MonitorControl ships it is part of why this fork treats it as the one
  acceptable exception to its no-private-frameworks rule (`AGENTS.md` §3.1).

## ddcutil — idea only, explicitly no code

[rockowitz/ddcutil](https://github.com/rockowitz/ddcutil) is **GPL licensed, and
no code from it has been copied into this repository.** It is cited for one idea:
that per-monitor DDC quirks belong in a maintained database rather than in `if`
statements, and that a monitor's own capabilities string cannot be trusted to
describe its behaviour (ddcutil reads it and then deliberately ignores it when
formulating commands). `Crisp/Resources/quirks/` is an independent design — its
own schema, its own confidence model, its own file format — written from scratch,
and the one entry it ships was measured on the hardware here. Where ddcutil's
public FAQ and issue tracker are the source of a *documented monitor behaviour*
quoted as an example in `Crisp/Resources/quirks/README.md` or `docs/ddc-notes.md`,
that is a factual citation of its conclusions, not a use of its source.

## FreeDisplay

Crisp began as a fork of [FreeDisplay](https://github.com/huberdf/FreeDisplay)
by huberdf. FreeDisplay's README declares it released under the MIT License
(its repository ships no LICENSE file). Portions of Crisp derived from
FreeDisplay remain available under those terms, reproduced here:

```
MIT License

Copyright (c) huberdf and FreeDisplay contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Contributions

- [@caicaiks](https://github.com/caicaiks) ([#4](https://github.com/didriksg/Crisp/pull/4), [#13](https://github.com/didriksg/Crisp/pull/13))
- [@shaw-baobao](https://github.com/shaw-baobao) ([#11](https://github.com/didriksg/Crisp/pull/11), [#24](https://github.com/didriksg/Crisp/pull/24))
- [@YuriNachos](https://github.com/YuriNachos) ([#27](https://github.com/didriksg/Crisp/pull/27), [#35](https://github.com/didriksg/Crisp/pull/35), [#36](https://github.com/didriksg/Crisp/pull/36))

## Translations

Simplified Chinese (简体中文) localization contributed by
[@xiangfeidexiaohuo](https://github.com/xiangfeidexiaohuo).
