# Monitor quirks database

Real monitors do not follow the VESA MCCS standard. They advertise input codes
they do not use, revert writes a second after accepting them, refuse the bottom
half of their own brightness range, and answer "supported" to every feature
query. The monitor's own capabilities string (DDC/CI command `0xF3`) does not
rescue you: `ddcutil` reads it and then deliberately ignores it when formulating
commands, because "the only way to know for sure is by testing using `getvcp`
and `setvcp`".

This directory is where that knowledge is written down. One JSON file per
vendor, merged at launch. **Adding your monitor is a one-file change and needs
no Swift.**

- `benq.json` — BenQ
- add `<vendor>.json` for a vendor that has no file yet

---

## The schema

```json
{
  "schemaVersion": 1,
  "vendor": "0x09D1",
  "vendorName": "BenQ",
  "models": [
    {
      "product": "0x8075",
      "name": "MA320U",
      "confidence": "verified",
      "notes": "How and where this was measured.",
      "features": {
        "brightness": { "range": [0, 100], "confidence": "verified" },
        "contrast":   { "range": [0, 100], "confidence": "verified" },
        "volume":     { "range": [0, 50],  "confidence": "verified" },
        "input": {
          "confidence": "reported",
          "values": [
            {
              "code": 19,
              "label": "USB-C",
              "confidence": "reported",
              "notes": "Why this is not confirmed yet."
            }
          ]
        }
      },
      "workarounds": {
        "writeDelayMs": null,
        "saveAfterWrite": false,
        "revertsAfterWrite": false,
        "reportsUnsupportedAsSupported": false
      }
    }
  ]
}
```

### File level

| Key | Meaning |
|---|---|
| `schemaVersion` | Optional, defaults to `1`. Bumped only for a breaking layout change; a newer file is still read on this build's terms. |
| `vendor` | The EDID manufacturer id. Hex (`"0x09D1"`, `"09D1"`) or decimal (`"2513"`) — both parse. |
| `vendorName` | Display name, e.g. `"BenQ"`. |
| `models` | The models. **One broken entry is dropped and logged; the rest of the file still loads.** |

### Model level

| Key | Meaning |
|---|---|
| `product` | The EDID product id, same formats as `vendor`. |
| `name` | Marketing model name, e.g. `"MA320U"`. |
| `confidence` | `"verified"` or `"reported"` — the default for everything below it. |
| `notes` | Free text. This is where a JSON file gets to have comments; say what you measured and on what. |

Unknown keys are ignored everywhere, so a `"notes"` string can be added at any
level as a comment. Only the model-level and input-value-level ones are read by
the code, and only the input-value one is ever shown to the user.
| `features` | Keyed by feature name. Unknown names are ignored, so a file written for a later build still loads. |
| `workarounds` | Behaviours that need code, not a different number. |

There is deliberately **no per-feature `vcp` field.** The feature name *is* the
VCP code; MCCS fixes them, and `Crisp/Models/DDCFeatureRegistry.swift` is where
the name becomes a number. Letting a contributed JSON file aim a write at an
arbitrary register on the monitor's I2C bus is not a capability this database
should have.

### The feature names

Every feature in the registry can be described here, not only the four Crisp
has controls for. Recording what you measured for a feature the app cannot drive
yet is useful — that is how it gets driven later.

| Name | VCP | Shape | Writing it |
|---|---|---|---|
| `brightness` | 0x10 | dial | ordinary |
| `contrast` | 0x12 | dial | ordinary |
| `volume` | 0x62 | dial | ordinary |
| `input` | 0x60 | codes | **destructive** |
| `sharpness` | 0x87 | dial | ordinary |
| `videoGainRed` / `videoGainGreen` / `videoGainBlue` | 0x16 / 0x18 / 0x1A | dial | ordinary |
| `blackLevelRed` / `blackLevelGreen` / `blackLevelBlue` | 0x6C / 0x6E / 0x70 | dial | ordinary |
| `colorTemperature` | 0x0C | dial | **destructive** |
| `colorPreset` | 0x14 | codes | **destructive** |
| `audioMute` | 0x8D | codes | **destructive** (values 3/4 blank the panel) |
| `osdControl` | 0xCA | codes | **destructive** (see below) |
| `powerMode` | 0xD6 | codes | **destructive** (value 5 powers the panel off) |
| `restoreFactoryDefaults` | 0x04 | write-only | **destructive**, no undo |
| `vcpVersion` | 0xDF | read-only | — |
| `displayTechnologyType` | 0xB6 | read-only | — |

**Why "destructive" is a schema-level fact and not advice.** ddcutil issue #153
documents a monitor whose on-screen menu and physical buttons were disabled
*permanently* by DDC commands — the panel kept working, its own controls never
did again. So anything Crisp has not proved is read-only, and anything marked
destructive is written only when the user asked for that specific write.

A feature that is neither in the quirks database nor answers a live read is
**not offered**, and one that is only advertised by the monitor's own
capabilities string (DDC/CI `0xF3`) is offered **read-only**: a well-formed
capabilities string is not evidence of support. The LG 27MD5KL advertises dozens
of features and three of them respond. The reverse never happens — a
capabilities string can only *add* a feature, never take one away — because the
HP LP2480zx omits `0x10` and drives brightness perfectly well, and because the
BenQ MA320U's own string advertises input codes `0F 11 12 15` while the panel is
sitting on `19`.

### Feature level

| Key | Meaning |
|---|---|
| `range` | `[min, max]`, the **raw DDC** values the monitor really honours. Not always `[0, 100]`: the Dell 2407wfp ignores everything below 30, so its dial is really `[30, 50]`. Omit if you have not measured it. |
| `confidence` | Overrides the model default for this feature. This is how the BenQ MA320U is `verified` for contrast and `reported` for input at the same time. |
| `values` | Input codes, for the `input` feature. In physical port order — that is the order the menu shows. |
| `complete` | `true` only when `values` covers **every** physical port on the model. Then the app stops offering the generic VESA codes for it. Defaults to `false`, so a half-mapped monitor keeps them and the user can still reach a port nobody has written down yet. |

### Input value level

| Key | Meaning |
|---|---|
| `code` | The raw VCP 0x60 value, as a **number** (`19`, not `"0x13"`). |
| `label` | What is physically wired to it: `"USB-C"`, `"HDMI-1"`, `"DisplayPort-1"`. |
| `confidence` | Overrides the feature default for this one code. |
| `notes` | Why it is or is not confirmed. Shown to the user in the confirmation dialog. |

`values` is an array of objects rather than a `{"19": "USB-C"}` map precisely so
each individual code can carry its own `confidence` and `notes`. A JSON object
key cannot say "this one is a guess".

### Workarounds

| Key | Status |
|---|---|
| `writeDelayMs` | **Acted on.** Spacing between consecutive DDC writes, overriding the MCCS ~50 ms default. Must be between 1 and 2000 ms — MCCS recommends ~50 and the slowest monitor anyone has documented needs a few hundred, so anything outside that band is a typo or a ms/ns mix-up. Out-of-band values are ignored and the default used. |
| `saveAfterWrite` | Recorded, not yet acted on. Monitor needs a "save current settings" command (VCP 0xB0) after every write or the value reverts (Iiyama PL2492H). |
| `revertsAfterWrite` | Recorded, not yet acted on. Monitor accepts a write and undoes it ~1 s later (LG 27MU67), so a read-back proves nothing. |
| `reportsUnsupportedAsSupported` | Recorded, not yet acted on. Monitor never sets the "unsupported feature" reply bit, so probing cannot tell what it really has. |

Record what you measured even where the app does not use it yet. The data is the
point; the code catches up.

---

## `confidence` — the load-bearing field

| Value | Means | The app will |
|---|---|---|
| `verified` | A human changed it on the physical panel and watched it take effect. | Trust it. Show the label as fact; switch inputs to it without asking. |
| `reported` | One person said so. Plausible, unproven. | Show the label with a trailing `?`, and **ask before writing it** to VCP 0x60. |

`reported` is not a lesser kind of `verified`; it is a different claim, and the
code treats it differently. The BenQ MA320U entry in `benq.json` is `verified`
for its ranges and `reported` for its one input code, which is exactly the
honest description of what is known.

### Destructive features never inherit confidence

Confidence otherwise flows model → feature → value. **Every feature marked
destructive in the table above is the exception, and it is enforced in code, not
by review.** Mark the model `verified` after confirming brightness, contrast and
volume, forget to re-declare `reported` on `input`, and the naive rule would
promote your guessed input codes straight past the confirmation dialog — the one
mistake in this file that costs somebody their screen. The same argument applies
unchanged to `powerMode`, `osdControl` and `restoreFactoryDefaults`, so the rule
is keyed on the flag rather than on the one feature that needed it first.

So the decoder caps what `input` inherits at `reported`, and **an input code only
reaches `verified` by saying so on that code**:

```json
"input": {
  "values": [
    { "code": 19, "label": "USB-C" },
    { "code": 33, "label": "HDMI-1", "confidence": "verified" }
  ]
}
```

Code 19 is `reported` no matter what the model or the feature declares. Code 33
is `verified` because that code says so itself.

That is one line per port you have actually switched to and back from — which is
the evidence `verified` is claiming you have.

Anything the app writes to VCP 0x60 without asking must be provable:

- the user picked that code themselves before, and their screen came back; or
- the monitor is on that input right now; or
- a `verified` database entry says so.

Nothing else. Do not promote an entry to `verified` to make the dialog go away.

---

## Working out the values on your own hardware

Build the CLI once:

```sh
make crispctl
```

### 1. Identify the monitor

```sh
./crispctl-bin list
```

```
[1] displayID=3 vendor=0x09D1 product=0x8075 serial=16843009
    brightness: 0/100
    contrast: 50/100
    input-source: 19/19
    volume: 44/50
```

`vendor` and `product` are your `vendor` / `product` fields. **Never put the
serial in the database** — quirks describe a model, not your individual unit.

To see what the monitor claims about itself:

```sh
./crispctl-bin capabilities
```

That reads DDC/CI command `0xF3`, which is a question and changes nothing. It
prints the raw string first — paste that verbatim into a pull request, because
every tolerance rule in the parser came from a raw string somebody posted — then
the codes it advertises. Treat the result as a list of things **worth
measuring**, never as a list of things that work: the same monitor that
advertises fifty codes will answer a read on a dozen of them.

### 2. Ranges

`current/max` from `list` gives you the maximum the monitor claims. Confirm the
useful ends by hand, one at a time, restoring as you go:

```sh
./crispctl-bin get contrast
./crispctl-bin set contrast 40
./crispctl-bin get contrast      # did it land? did it stay?
./crispctl-bin set contrast 50   # restore
```

- If the value comes back different from what you wrote, the monitor is clamping:
  walk down until it stops moving and you have found the real `min`.
- If it lands and then reverts a second later, that is `revertsAfterWrite`.
- If it never sticks at all but does with a "save settings" step, that is
  `saveAfterWrite`.

Change one thing per run. Two changes at once and you have measured neither.

Contrast, brightness, volume and the gain/black-level codes write straight away
like that. The codes the registry marks **destructive** do not:

```sh
./crispctl-bin set power 5
0xD6 Power mode is a destructive write.
Value 5 turns the panel off at the power stage. Many monitors cannot be woken
from it over DDC at all, because the DDC controller goes down with the panel.
about to write: power = 5
continue? [y/N]
```

Answer `y`, or pass `--force` to skip the prompt. In a script — anywhere stdin is
not a terminal — there is no prompt and no write: `crispctl` prints the hazard and
exits non-zero unless `--force` is on the command line. The gated codes are the
ones `Crisp/Models/DDCFeatureRegistry.swift` marks `destructive: true`: `0x60`
input source, `0xD6` power, `0x04` factory reset, `0x0C`/`0x14` colour, `0x8D`
blank, `0xCA` OSD lock. `get`, `list`, `capabilities` and `watch` are reads and
never ask.

### 3. Input codes — read this before you touch VCP 0x60

**A wrong input code costs you your display.** The panel switches to a port with
nothing attached, the Mac cannot switch it back (the monitor has stopped
listening to that cable), and the only way out is the monitor's own physical
buttons. On a wall-mounted or awkwardly placed monitor that is a genuinely bad
afternoon.

So: **never guess an input code.** Never copy one from another model in the same
family — the Samsung U32H750 advertises `0x11`/`0x12`/`0x0F` and actually uses
`0x05`/`0x06`/`0x0F`, and blindly writing the advertised value is exactly how you
lose the screen.

There are two safe ways round. Both end with `verified` data; neither involves
guessing.

#### The wizard (Input Source ▸ Calibrate…)

The app can do this for you, and it is the only path in Crisp that produces
`verified` input data — because it is the only one where a human physically
confirms the result. Per code you choose to try, it:

1. records the code the monitor is on **now**, and writes that to disk before
   anything else;
2. switches to the candidate;
3. starts a 15-second countdown and asks "can you see this?" in a window **on the
   display being calibrated**;
4. switches back on its own if you do not answer.

Not answering is therefore the safe outcome, which matters because the likely
failure is that you cannot see the question. The countdown runs on a dispatch
timer that no window, menu or modal can starve, and the record from step 1 means
that even a crash or a force-quit mid-switch is repaired: the next time Crisp can
reach that monitor — next launch, next reconnect — it puts the original input
back. Unplugging the monitor mid-test is handled the same way.

When you confirm, it asks what is plugged into that port and writes the mapping
down as `verified` for **your unit**. "Copy Quirks Entry" then turns the session
into an entry for this directory, which is the part that helps everybody else.

#### By hand, without ever writing 0x60

The other way is to let the *monitor* tell you, using its own buttons:

1. `./crispctl-bin get input` and write the number down.
2. Switch input **using the monitor's OSD / physical buttons**, to a port you
   know has something attached.
3. `./crispctl-bin get input` again. The new number is that port's code.
4. Repeat for each physical port. You now have the map, and you never wrote
   `0x60` at all.

That gives you `verified` data. If you have only inferred a code — "the Mac is on
USB-C and the monitor reports 19, so 19 is probably USB-C" — that is `reported`.
Write it down as `reported` with a `notes` line saying what you inferred it from.
Someone with the same monitor will finish the job later.

Both routes answer the same question and neither guesses. Use the wizard if the
monitor's buttons are awkward to reach; use the buttons if you would rather no
software wrote `0x60` at all.

---

## Contributing

1. Add or edit `<vendor>.json` in this directory.
2. Run `make compile` (the JSON is not compiled, but a broken file should not be
   the reason a build looks fine and the app is silent).
3. Confirm it loaded: the app logs
   `loaded N monitor models from M quirks file(s)` to the unified log —

   ```sh
   log stream --info --predicate 'subsystem == "com.crisp.app" AND category == "MonitorQuirks"'
   ```

   A file that fails to parse logs `quirks file malformed, skipped: <name>` and a
   single bad model logs `quirks entry skipped: <reason>`. Neither stops the app
   or the other files: an unknown or unreadable database simply means the app
   behaves as it did before the database existed.
4. Say in the PR what you measured, on what machine and macOS version, and which
   fields are `verified` versus `reported`.
