# Groups, presets and schedules

Three features that share one storage file and one rule about what may be
written. Panel: **Settings › Presets / Display Groups / Schedules**.

Neither BetterDisplay nor BenQ's Display Pilot 2 has real presets or schedules,
so there is no prior art to copy and no compatibility to keep. All of it is
public API — `DisplayStateStore` and `BrightnessService`, no private frameworks
anywhere near it.

---

## Presets

A named snapshot of **brightness, contrast and volume**, per display, keyed by
`DisplayUUID`. Save the current state, apply it later, rename it, delete it.

Applying is a no-op for any display the preset names that is not attached — not
an error. A preset outlives the desk it was captured on, and a laptop is away
from that desk most of the time.

### Presets do not carry an input source, deliberately

The obvious fourth field is input (VCP 0x60). It is absent from the *type*, so
no call site can populate one by accident. The reasoning, in full, is in the
header of `Crisp/Models/DDCPreset.swift`; the short version:

- 0x60 is destructive — switching to a port with nothing attached blanks the
  screen and only the monitor's own buttons undo it. Every destructive write
  needs a `DestructiveWriteConsent`, minted only at a real confirmation site.
- None of the three that exist fits: the panel's alert needs the panel on screen
  (and a three-display preset would need three alerts, of which
  `AutomationService` refuses all but the first); the automation alert needs
  somebody to answer it, which a 22:00 schedule does not have; and
  `RestoredUserChoice` refuses any value but the one already on record, so a
  preset built on it could only re-assert what the monitor is already remembered
  on.
- Declaring a fourth conformer would compile. The reason not to is that a
  preset's value is "one click, no thinking", and input switching is the one
  write where thinking is mandatory. Combining them turns the one dialog that
  matters into something the user learns to dismiss.

`DDCPresetTests.testAPresetCannotCarryADestructiveFeature` asserts this over the
whole registry, so adding a destructive feature to `DDCPresetPlan.features`
fails the suite rather than shipping.

---

## Display groups

A named set of displays whose brightness moves together, keyed by `DisplayUUID`
(never `CGDirectDisplayID` — AGENTS.md rule #3).

| Mode | What it does | When it is right |
|---|---|---|
| **Keep offsets** (relative, default) | every member preserves the difference it had when the group was armed | mixed panels, which is most desks |
| **Same level** (absolute) | every member goes to the same percentage | identical monitors |

Absolute is not the safe default and is not the obvious-but-equivalent choice.
DDC brightness is a percentage of *that panel's* range, and the ranges are not
comparable: this fork's BenQ MA320U sits at roughly 59 nits at DDC 0
(`reference/benq-ma320u.md`), a normal room brightness, while another panel's 0
is nearly dark. "Set both to 40%" therefore does not make two screens look alike.

### Why it cannot oscillate

The failure mode of every sync feature: A moves, B follows, B's change is
observed, A follows B, and the group hunts. Three things prevent it, and only
the first is a design rather than a patch:

1. **An origin token.** `BrightnessSync.targets` plans nothing for a change whose
   origin is already `.groupSync`. A propagation is one level deep by
   construction, whatever the services above it do with notifications. Pure, and
   tested directly (`testASyncedChangeIsNeverPropagatedAgain`).
2. **Followers are computed from the mover, never from each other.** Every target
   is `mover + (baseline_member − baseline_mover)`. No follower's value is ever
   an input, so a member the clamp has pinned at 0 or 100 cannot drag the group
   towards it — and when the mover comes back into range, the pinned member
   rejoins at its own offset rather than at wherever the clamp left it.
3. **A deadband** (0.5%, below one step of any control the app offers) makes a
   second identical propagation a no-op, so a duplicate notification or a
   coalesced slider tick costs no I²C traffic.

Follower writes go out as `isAutoAdjust: true`, which is the existing flag
meaning "not the user's own gesture", so they never post the notification the
sync observer listens to — there is no second event to ignore. `isPropagating`
refuses re-entry anyway.

Offsets are captured when the group is created, when its membership changes,
when the mode is switched to relative, and on **⋯ › Recapture Offsets**.

---

## Schedules

A preset, applied at a time of day, optionally on chosen weekdays. No
sunrise/sunset (that needs location permission) and nothing needing network.

### Surviving sleep

The obvious implementation — "every minute, is it 22:00?" — has two opposite
bugs. Asleep at 22:00 and the schedule **never** fires. Loosen it to "is it past
22:00 and have we not fired today" and it fires on **every tick** until midnight.

Both come from recording the wrong thing. `ScheduleFiring` records the
**occurrence** (the exact 22:00 that was satisfied), never the wall clock at
which the app noticed:

- waking at 07:00 finds the most recent occurrence — yesterday's 22:00 — sees it
  is newer than the one on record, fires **once**, and records it;
- the next tick finds the same occurrence and does nothing;
- tomorrow's 22:00 is a different occurrence and fires again.

Three guards sit around that:

| Guard | Case it exists for |
|---|---|
| `armedAt` | creating a 22:00 schedule at 23:00 must not fire it immediately |
| `catchUpWindow` (12 h) | a Mac off for a week must not apply the Night preset at breakfast; twelve hours still catches up on a morning wake |
| monotonic `lastFired` | a clock dragged backwards must not make an applied occurrence eligible again |

The tick runs once a minute (with 15 s tolerance so macOS may coalesce it), on
`NSWorkspace.didWakeNotification`, and once at launch. Asking more often than
necessary is free: a schedule that has already fired answers `alreadyFired`.

The record is written **before** the preset is applied. A crash in between costs
one application; the reverse order would risk applying it twice, which is the bug
the whole design is shaped around.

---

## Storage — `displays.json` v3

```json
{
  "version": 3,
  "displays":  { "<uuid>": { "brightness": 12, "contrast": 50 } },
  "groups":    [ { "id": "…", "name": "Desk", "members": ["<uuid>"],
                   "syncMode": "relative", "baselines": { "<uuid>": 12 } } ],
  "presets":   [ { "id": "…", "name": "Night",
                   "settings": { "<uuid>": { "brightness": 20, "contrast": 45 } } } ],
  "schedules": [ { "id": "…", "presetID": "…", "enabled": true,
                   "trigger": { "at": "22:00" }, "armedAt": …, "lastFired": … } ]
}
```

The v2 → v3 upgrade (`DisplayStateMigration.upgraded`) is a pure function, run on
every load rather than behind a sentinel because it is idempotent. It has nothing
to *convert* — no earlier version stored anything the new members could be
derived from — so its content is the two guarantees a version bump owes:

- **Nothing is dropped.** `version` is only ever raised, so a document a newer
  build stamped keeps its own number.
- **The invariants hold** whatever a hand edit left behind: identifiers are
  unique, a group lists no display twice, and a preset entry that would apply
  nothing is dropped.

Two forward-compatibility mechanisms shipped with it:

- **Unknown fields are kept.** Any key this build does not model — at the top
  level and per display — is parked verbatim and written back out. Before this,
  opening an older Crisp once silently deleted whatever a newer one had stored.
- **Lists decode element-wise.** One malformed schedule costs that schedule, not
  the document. Failing the whole document would make the store quarantine it,
  losing the user's per-display brightness because they mistyped a time.

Corrupt bytes still degrade to an empty document and quarantine the file
(AGENTS.md rule #4). None of the new members may become a new way for persistence
to take the app down.

---

## CLI

```sh
crispctl preset list                    # id, name, and what each display gets
crispctl preset apply <id|name> [--force]
```

The CLI reads the app's own `displays.json` rather than keeping a second copy,
and never writes it — `lastFired`, group baselines and everything else with an
owner stay the app's. Every write goes through the same `confirmDestructive`
gate `crispctl set` uses, so a preset carrying a destructive code would need
`--force` or an answered prompt. Presets cannot carry one, which makes that a
boundary that holds rather than a check that fires.

Percentages are scaled against the maximum the monitor reports for that register;
a monitor that will not answer a read is skipped rather than written to blind.

---

## Where it lives

| Concern | File |
|---|---|
| Group model + the sync arithmetic | `Crisp/Models/DisplayGroup.swift` |
| What a preset may contain; the apply plan | `Crisp/Models/DDCPreset.swift` |
| Trigger, schedule, and the firing rule | `Crisp/Models/PresetSchedule.swift` |
| The v3 document + `upgraded` | `Crisp/Models/DisplayStateDocument.swift` |
| Unknown-field bag, element-wise list decode | `Crisp/Models/JSONValue.swift` |
| Group CRUD + propagation | `Crisp/Services/DisplayGroupService.swift` |
| Preset CRUD + applying | `Crisp/Services/DDCPresetService.swift` |
| Schedule CRUD + the tick | `Crisp/Services/PresetScheduleService.swift` |
| The three panel sections | `Crisp/Views/GroupsPresetsView.swift` |
| `crisp://preset/<id>`, Apply Preset intent | `Crisp/Models/CrispURL.swift`, `Crisp/Intents/` |
| `crispctl preset` | `crispctl/main.swift` |
