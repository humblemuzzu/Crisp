# BetterDisplay v4.3.6 — binary forensics

Read of the installed `/Applications/BetterDisplay.app` (bundle version 4.3.6,
`CURRENT_PROJECT_VERSION` 50119, built with Xcode 26.1 / macOS 26 SDK, built
2026-08-11). Everything here came from the app bundle itself — Info.plist,
code signature, `otool -L`, `nm -u`, and `strings` on the 36 MB executable —
never from running the app.

**Why this file exists:** this is the evidence that established the root cause
of the crash incident (see `AGENTS.md` §2) and the constraint list the fork is
built around.

---

## 1. Linked frameworks

`otool -L` on `Contents/MacOS/BetterDisplay` — the private frameworks are the
smoking gun:

| Framework | Status | What it's used for (per imports + strings) |
|---|---|---|
| SkyLight | **private** | WindowServer display state, appearance theme |
| CoreBrightness | **private** | Night Shift, True Tone, backlight |
| DisplayServices | **private** | `DisplayServicesSetBrightness`, ambient light |
| OSD | **private** | `OSDManager` — the on-screen volume/brightness HUD |
| BezelServices | **private** | display/backlight control |
| IOMobileFramebuffer | **private** | framebuffer access |
| CoreDisplay | **private** | display modes, user brightness |
| IOKit | public | DDC/CI I2C (the safe path) |
| AppKit, SwiftUI, CoreGraphics, ColorSync, … | public | UI + graphics |

Direct private-symbol imports (from `nm -u`), e.g.:

```
_DisplayServicesAmbientLightCompensationEnabled
_DisplayServicesCanChangeBrightness
_DisplayServicesEnableAmbientLightCompensation
_DisplayServicesGetBrightness
_DisplayServicesRegisterForBrightnessChangeNotifications
_DisplayServicesSetBrightness
_OBJC_CLASS_$_OSDManager
```

## 2. Entitlements (code signature)

```
com.apple.security.cs.allow-jit  = true
com.apple.security.network.client = true
```

No sandbox. JIT allowed — consistent with a JIT-ish dynamic bridge for the
private APIs.

## 3. Feature inventory

The binary's own settings keys (from `strings`, `_`-prefixed). Grouped by the
architecture class names the binary also contains (`DDCController`,
`PowerManagement`, `BlueLightController`, `RefreshRateReporter`, `AppOSD`,
`GlassOSD`, `MediaKeys`):

**DDC / hardware (safe path — what we replicate):**
`_allowDDC`, `_ddcCapabilitiesDetected`, `_ddcControlsAvailable`,
`_ddcHardwareInputSourceAvailable`, `_ddcCustomInputSources`,
`_ddcCustomRangedControlSliders`, `_ddcCustomCommandControls`,
`_ddcBacklight`, `_ddcBacklightCoolOffMilliseconds`, `_ddcFactoryReset`,
`_currentInput`, `_volume`, `_volumeSliderId`, `_volumeMax`, `_volumeMin`,
`_volumeUp/_volumeDown/_volumeAvailable`, `_hardwareBrightnessSlider`,
`_hardwareContrastSlider`, `_power`-related keys, per-feature `_Slider` keys.

**Software / private-API (the crash path — we deliberately do NOT replicate):**
`_softwareBrightness-ColorController` equivalents,
`_allowAppleHardwareBrightness`, `_allowCombinedBrightness`,
`_brightnessUpscaling`, `_directBrightnessUpscaling`,
`_allowForcedHDR`, `_flexibleHDR`, `_currentScalingSupportsHDR`,
`_displayInRegularHDRMode`, `_filterBrightness/_filterContrast/_filterGamma`,
`_gammaSlider`, `_rGammaSlider/_gGammaSlider/_bGammaSlider`,
`_blueLight`, `_turnOffBlueLightOnHDR`,
`_autoBrightness`, `_hasAutoBrightness`,
`_mediaKeyBrightnessEngaged`, `_mediaKeyVolumeEngaged`, `_mediaKeyMuteEngaged`,
`_videoMediaKeyAssumeControlMode`, `_audioMediaKeyAssumeControlMode`,
`_dimBrightnessOnLock`, `_dimBrightnessOnLockTo`,
`_dimBrightnessOnIntelDisconnect`,
`_colorTableCapable`, `_allowRestoreDarkApple`, `_allowRestoreFullDimming`.

**Display/virtual (private-API heavy):** virtual displays, XDR upscaling,
forced HDR, HiDPI, `_defaultIsHiDPI`, `_defaultRefreshRate`, refresh-rate
reporter, `_showNitsOSD`, `_showPercentageOSD`, `_showVolumeOSD`,
`_showOSDSoftwareBrightnessIndicator`.

**Lifecycle:** `_connectAllOnStartup`, `_autoReconnect`,
`_showSettingsOnNextStartup`, `_showRelaunchAlert`,
`_reapplySettings`-family, `_sleepAllowed`, `_wakeAllowed`,
`_writeSleepTimeMilliseconds`, `_ddcBacklightOffWhenCombinedDimmedToZero`,
`_ddcBacklightOffWhenLockNonMain`.

## 4. The user's actual config (the smoking gun)

From `~/Library/Preferences/pro.betterdisplay.BetterDisplay.plist`
(display 4 = the BenQ MA320U):

```
value@hardwareBrightness-DDCController@Display:4 => 0      <- hardware backlight at 0
value@softwareBrightness-ColorController@Display:4 => 1    <- all dimming in software
value@combinedBrightness-CombinedController@Display:4 => 0.5
value@volume-DDCController@Display:4 => 0.5
hasHDR@Display:4 => true
supportsHDR@Display:4 => true
```

Meaning: the user's *visible* brightness was produced entirely by the software
(Shader/gamma) path — the private-API path — because the hardware DDC
brightness was parked at 0. The monitor itself confirmed this: a direct DDC
read returns `brightness 0/100` (see `ddc-ci.md`).

## 5. Crash correlation

- BetterDisplay is the only installed app talking to the exact private display
  APIs (`SkyLight`/`CoreDisplay`/`DisplayServices`/`CoreBrightness`) that
  mutate WindowServer state.
- Its records show the built-in screen took over at 00:42:29 — the user
  unplugging the BenQ to work from the sofa — matching the incident timeline.
- Public issue BetterDisplay #5367 on macOS 26.4.1: WindowServer crash, Mac
  hard-lock, forced reboot — the user's exact symptoms.

## 6. What we replicate vs. what we refuse

| BetterDisplay feature | Our stance |
|---|---|
| Hardware DDC brightness/contrast/volume/input | Replicate (safe IOKit path) |
| Keyboard brightness/volume keys | Replicate (public CGEventTap) |
| Reconnect reapply, per-display persistence | Replicate (UUID-keyed) |
| Software dimming (shaders/gamma via private APIs) | **Never** |
| Virtual displays, XDR upscaling, forced HDR, HiDPI tricks | **Never** (private APIs, unused by the user anyway) |
| OSD HUD via OSDUIHelper XPC | Only what Crisp already ships, untouched |
