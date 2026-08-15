# AGENTS.md — working notes for this repo

This file is the durable context for anyone (human or agent) working in this
repo. It explains **why this fork exists**, the **root cause of the incident
that started it**, the engineering constraints that follow, and how to build,
test and verify. Read it before changing anything.

---

## 1. What this repo is

A fork of [Crisp](https://github.com/didriksg/Crisp) (v1.4.1) — a free,
open-source macOS menu-bar app for controlling external monitors — extended
with the DDC features the original lacked and hardened against the failure
mode that made us build it. The upstream is actively maintained; this fork
tracks it and adds:

- **DDC hardware contrast** (VCP 0x12) — upstream only had software gamma
  "contrast".
- **DDC input-source switching** (VCP 0x60) — upstream had none.
- **Per-display DDC persistence + reconnect reapply** — brightness, contrast,
  volume re-applied when a display reconnects (input opt-in per display).
- **`crispctl`** — a CLI sharing the app's exact DDC stack
  (`list` / `get` / `set` / `watch`).
- **Simplified sliders** — one control per feature (no +/− step buttons),
  instant response, `%` readout.

Everything added lives on the `benq-ddc` branch. See
`docs/fork-ddc-features.md` for the feature-level documentation.

---

## 2. The incident that started this — root cause

### 2.1 What happened

The user's Mac (Apple M4 Pro, macOS 26.4.1, BenQ MA320U 4K over DisplayPort)
hard-locked and force-rebooted **seven times**. Symptoms: WindowServer
crashing, screen freeze, forced reboot. The only app doing anything unusual
with the display was BetterDisplay v4.3.6, running with a specific
configuration (see 2.3).

### 2.2 How it happened — mechanism

BetterDisplay controls brightness through **two independent paths**:

1. **Hardware DDC/CI** — writing the monitor's real backlight register over
   I2C. Safe, public-ish IOKit.
2. **Software dimming** — scaling the rendered image with GPU shaders and
   gamma tables driven by **private frameworks**: `CoreBrightness`,
   `CoreDisplay`, `SkyLight`, `DisplayServices`, `OSD`, `BezelServices`,
   `IOMobileFramebuffer`. These are the WindowServer-adjacent APIs.

The user's BetterDisplay config (read from its own prefs,
`~/Library/Preferences/pro.betterdisplay.BetterDisplay.plist`) pushed the
**hardware brightness to 0** and did **all visible dimming in software**:

```
value@hardwareBrightness-DDCController@Display:4 => 0
value@softwareBrightness-ColorController@Display:4 => 1
value@combinedBrightness-CombinedController@Display:4 => 0.5
value@volume-DDCController@Display:4 => 0.5
hasHDR@Display:4 => true
```

That software path is exactly the class of private API that breaks on
macOS 26: BetterDisplay #5367 describes the same symptoms (WindowServer crash,
hard lock, forced reboot) on macOS 26.4.1. The app links the private
frameworks directly (see `reference/betterdisplay-forensics.md` for the
binary-level evidence: `otool -L`, `nm -u`, entitlements).

**Root cause, in one sentence:** the user's brightness was controlled through
private CoreBrightness/CoreDisplay/SkyLight shader APIs (because BetterDisplay
had set hardware brightness to 0), and those APIs crash WindowServer on
macOS 26.

### 2.3 Why we built our own instead of patching

- BetterDisplay is closed source — the crash path cannot be removed, only
  configured around.
- The user's actual need is small: **hardware brightness (and contrast,
  volume, input) for the BenQ via DDC**, working with the MacBook lid closed,
  single external display, keyboard keys (F1/F2) working, and **no crash when
  the display is unplugged**.
- A DDC-only app cannot hit the crash class by construction: it never touches
  WindowServer.

### 2.4 Why Crisp, not from scratch

Crisp's DDC layer is **pure IOKit** (same DDC/CI path, checksum-validated,
read-quarantined, coalesced writer, identity-matched, tested) and was verified
working against this exact BenQ before we committed to it. Its own
private-API features (physical display toggle, CGS resolution tricks, HDR
boost, night-shift) are isolated behind `dlopen`/weak linking and are simply
never exercised by the features we use. The two full-repo audits are in
`reference/crisp-audit.md`.

---

## 3. Engineering constraints (hard rules)

These are not style preferences; they are the reason this repo exists.

1. **The DDC path never touches private frameworks.** No `SkyLight`,
   `CoreBrightness`, `CoreDisplay`, `DisplayServices`, `OSD`, `BezelServices`,
   `IOMobileFramebuffer` calls in `DDCService`, `DDCFeatureService`,
   `BrightnessService` (external branch), `VolumeService`, or `crispctl`.
   The one allowed exception is the `IOAVService*` family — undocumented but
   exported by IOKit, and it only talks to the display controller's I2C bus,
   not WindowServer (same as MonitorControl ships). If a future macOS drops
   those symbols, the failure mode must be "feature silently absent", never a
   WindowServer crash.
2. **Never extend upstream's private-API features.** They exist (physical
   display toggle via `SLSConfigureDisplayEnabled`, CGS mode switching with a
   documented macOS 26 `checkCapacity()` segfault hazard, MonitorPanel HDR,
   OSDUIHelper HUD). They are gated and dlopen'd; leave them that way. Do not
   build new features on them.
3. **Persistence keys on `displayUUID`, never `CGDirectDisplayID`.** macOS
   reassigns display IDs across reconnects (issue #32 in upstream); UUID-keyed
   state is the only safe persistence.
4. **A display disconnect must be a no-op.** Unplugging the BenQ while the
   app runs must never crash, freeze input, or wedge DDC. The DDC services
   quarantine wedged reads and drop channels on reconfiguration; keep that
   discipline.
5. **Zero-warning builds.** CI runs `SWIFT_TREAT_WARNINGS_AS_ERRORS`; keep
   `make compile` output clean.

---

## 4. Architecture map (what to touch for what)

| Concern | Files |
|---|---|
| DDC/CI I2C (read/write/retry/quarantine) | `Crisp/Services/DDCService.swift` |
| Contrast, input, persistence, reconnect reapply | `Crisp/Services/DDCFeatureService.swift` |
| Display discovery / reconnect flow | `Crisp/Services/DisplayManager.swift` |
| Brightness write path + coalescing | `Crisp/Services/BrightnessService.swift` |
| Volume write path | `Crisp/Services/VolumeService.swift` |
| Keyboard keys (F1/F2) | `Crisp/Services/BrightnessKeyService.swift` + `Crisp/App/AppDelegate.swift` (trust poll) |
| Persistence settings | `Crisp/Services/SettingsService.swift` |
| Sliders / input menu | `Crisp/Views/BrightnessSliderView.swift`, `Crisp/Views/VolumeSliderView.swift`, `Crisp/Views/DDCFeatureViews.swift`, `Crisp/Views/PanelBlocks.swift` |
| CLI | `crispctl/main.swift` (shares DDCService + DDCServiceMatcher) |
| Packaging | `scripts/make-app.sh` |

---

## 5. Build, run, verify

```sh
make compile          # app binary only (./Crisp-bin), zero-warning check
make crispctl         # CLI binary (./crispctl-bin)
./scripts/make-app.sh # full rebuild -> /Applications/Crisp.app, stable-sign, relaunch
make test             # xcodegen + xcodebuild unit tests (needs Xcode + xcodegen)
```

**Signing is important.** The app must be signed with a *stable* identity
(your Apple Development certificate, or a self-signed "Crisp Dev" cert) so the
Accessibility TCC grant survives rebuilds. Ad-hoc signing invalidates the
grant on every build — the exact silent failure this fork fixed. `make-app.sh`
and `dev.sh` handle this; do not bypass with plain ad-hoc signing.

**Live verification (monitor connected):**

```sh
./crispctl-bin list                      # enumerate displays + DDC values
./crispctl-bin get brightness            # read
./crispctl-bin set contrast 48           # write (use small deltas; restore after)
```

DDC writes are safe to test: the monitor ack's and reads back. Avoid
`set input <different-value>` unless you expect the screen to switch inputs.

**Brightness keys debugging:** the app logs to the unified log
(`subsystem "com.crisp.app"`, category `BrightnessKeyService`):

```sh
log stream --info --predicate 'process == "Crisp" AND subsystem == "com.crisp.app"'
```

Expect `tapCreate failed …` when Accessibility is missing, `brightness-key
event tap armed` once granted, and `brightness key: adjusting external display
<id>` on each F1/F2 press. The panel's Settings section shows a green/ orange
"Keys active" dot as live feedback.

---

## 6. Status / known limits

- **Verified live on the BenQ MA320U** (macOS 26, Apple Silicon):
  brightness/contrast/volume reads and writes, input-source no-op write,
  reconnect reapply logic, contrast/volume/key persistence.
- **Input labels are uncalibrated for this monitor.** The MA320U reports
  current input `19`, which is not a standard VESA code — the menu shows raw
  codes for unknown values. Calibrating the mapping for a monitor = note the
  value that corresponds to each physical port (switch via OSD or by
  selecting, observe which input becomes active). Do not guess.
- **Reconnect reapply of input is opt-in per display and off by default.**
- The user runs BetterDisplay-free now; if it ever returns, this fork must not
  fight it (both write the same DDC registers; last writer wins).

## 7. Reference material

`reference/` contains the full research trail:

- `betterdisplay-forensics.md` — binary-level read of BetterDisplay v4.3.6
- `ddc-ci.md` — how DDC/CI works here, wire formats, verification evidence
- `crisp-audit.md` — the two full-repo audits of upstream Crisp
- `benq-ma320u.md` — monitor facts and verified values
