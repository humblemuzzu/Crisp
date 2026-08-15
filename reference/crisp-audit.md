# Crisp v1.4.1 — full-repo audit (upstream)

Two independent read-only agents read **every** Swift file in upstream Crisp
(~17k lines: App/, Models/, Services/, Utilities/, Views/, tests, project.yml,
Makefile, dev.sh, docs/) before this fork touched anything. This file
condenses their findings. The upstream repo was audited at commit `89c119c`
(v1.4.1, 2026-08-14).

## 1. Private API inventory (what to never build on)

All loaded at runtime via `dlopen`/`dlsym`/`NSClassFromString` (never
hard-linked), except two weak-linked SkyLight symbols:

| Private API | Where | Used for |
|---|---|---|
| SkyLight `SLSConfigureDisplayEnabled`, `SLSGetDisplayList` | `Crisp-Bridging-Header.h`, `PhysicalDisplayToggleService.swift` | physical display disconnect/reconnect |
| SkyLight `SLSSetAppearanceTheme*` (dlopen) | `CoreBrightnessService.swift` | dark mode |
| CGS `CGSConfigureDisplayMode`, `CGSGetDisplayModeDescriptionOfLength` (+ reverse-engineered 212-byte struct) | `DisplayMode.swift`, `ResolutionService.swift` | GPU-scaled HiDPI mode switching. The bridging header documents a **segfault in checkCapacity() on macOS 26** if misused |
| `CGVirtualDisplay*` | `VirtualDisplayService.swift` | virtual displays |
| MonitorPanel `MPDisplayMgr` (KVC) | `BrightnessBoostService.swift`, `DisplayPresetService.swift` | XDR presets, HDR mode preference |
| DisplayServices `DisplayServices*Brightness`, ambient compensation | `BrightnessService.swift`, `AutoBrightnessService.swift`, `SystemAutoBrightnessView.swift` | built-in panel brightness, auto-brightness |
| CoreBrightness `CBBlueLightClient`, `CBTrueToneClient` + hardcoded struct offsets | `CoreBrightnessService.swift` | Night Shift, True Tone |
| OSDUIHelper XPC (`com.apple.OSDUIHelper`) | `BrightnessHUDService.swift` | the brightness HUD overlay |
| IOAVService* (undocumented, but **IOKit**) | `Crisp-Bridging-Header.h`, `DDCService.swift` | DDC/CI I2C — the only non-public surface in the DDC path |

**Verdict:** the DDC/brightness external-display path is pure IOKit — zero
WindowServer IPC. The private-API features are isolated, gated, and never fire
for the features this fork uses.

## 2. Feature map (abridged)

| Feature | API class | Status in fork |
|---|---|---|
| DDC brightness (hardware backlight) | IOKit | **used** |
| Software dimming fallback (gamma tables, public `CGSetDisplayTransferByTable`) | public | used only as fallback / boost |
| DDC volume (VCP 0x62) + mute | IOKit | **used** |
| Brightness/volume keys (CGEventTap, Accessibility-gated, fail-safe on no external) | public | **used** |
| Contrast slider | **software gamma only** | replaced by real DDC contrast (this fork) |
| Input source switching | absent | added (this fork) |
| Reconnect reapply (DDC values) | reads hardware, adopts | extended (this fork: writes saved values back) |
| Resolution / refresh rate | CGS private | untouched, off by default |
| HDR toggle / Extra Brightness / XDR presets | MonitorPanel private | untouched |
| Physical display disconnect | SkyLight private | untouched |
| Virtual displays | private | untouched |
| Presets, arrangement, gamma adjust, color profile | public | untouched |
| CLI | absent | added (this fork: `crispctl`) |

## 3. Quality findings that matter to us

- Display IDs are volatile across reconnects; upstream fixed this twice
  (gamma persistence issue #32, soft-brightness) by keying on the stable
  displayUUID. **Our persistence follows the same rule.**
- `DDCService` is defensive to the point of paranoia: reply signature +
  checksum validation, read quarantine (6 strikes, 10 min), coalescing writer
  (≥50 ms spacing), full channel-map flush on every reconfiguration. This is
  the code we bet the fork on.
- Known upstream ponytails we inherited: mute = volume 0 + remembered level
  (not VCP 0x8D); input-source batch reader existed but was dead code (we
  wired 0x60 up); `SettingsService.brightness/contrast` were displayID-keyed
  dead seeds (we added UUID-keyed persistence instead).
- The `BrightnessKeyService` event tap has a documented macOS 26 hazard class
  (untrusted session tap stalls WindowServer input) handled via a 0.5s trust
  watchdog that tears the tap down on revoke. This fork additionally fixed the
  arm-on-grant gap (see `AGENTS.md` §5) and added stable signing so the grant
  survives rebuilds.

## 4. What we changed vs. upstream

`docs/fork-ddc-features.md` has the feature list; `AGENTS.md` has the
constraints. Files touched: `DDCService` (none — used as-is),
`DDCFeatureService.swift` (new), `DisplayInfo.swift`, `DisplayManager.swift`,
`SettingsService.swift`, `VolumeService.swift`, `BrightnessKeyService.swift`,
`AppDelegate.swift`, `BrightnessSliderView.swift`, `VolumeSliderView.swift`,
`PanelBlocks.swift`, `MenuBarView.swift`, `DDCFeatureViews.swift` (new),
`crispctl/` (new), `scripts/make-app.sh` (new), `Makefile`, `project.yml`.
