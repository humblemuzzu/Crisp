# Automating Crisp

Three ways to drive Crisp without clicking: **Shortcuts** (App Intents), a
**`crisp://` URL scheme**, and **user-assigned global hotkeys**. All three go
through the same decision core, so they cannot drift into three policies.

There is deliberately **no HTTP server** — see [Why no local socket](#why-no-local-socket).

---

## Naming a display

Every automation surface names a display by its **UUID**, never by a
`CGDirectDisplayID`. macOS reassigns display ids across reconnects (upstream
issue #32), so an id baked into a shortcut or a link would, a week later, mean a
different physical panel. `crispctl list` prints the UUID of each attached
display:

```
$ ./crispctl-bin list
[1] displayID=3 vendor=0x09D1 product=0x8075 serial=16843009
    uuid: AEB55F97-FD93-4F8D-AD10-0942959D069C
    brightness: 12/100
    …
```

Both the app and the CLI derive that string with the same two functions
(`DisplayUUID.systemString` / `.fallbackString`), so what is printed always
matches what the app looks up.

---

## Shortcuts (App Intents)

| Intent | Parameters | Notes |
|---|---|---|
| Set Brightness | display, 0–100 | DDC backlight where the monitor answers |
| Set Contrast | display, 0–100 | VCP 0x12, monitors that answer a contrast read |
| Set Volume | display, 0–100 | VCP 0x62 |
| Switch Input Source | display, raw code | **always asks first** (see below) |
| Get Display Info | display | returns the display with its last-read values |
| Refresh Displays | — | re-enumerate and re-probe; reads only |

The Shortcuts picker offers the displays attached right now, by name
(`DisplayEntityQuery`), and a saved shortcut stores the UUID.

`Get Display Info` returns a *Display* entity with `Name`, `Brightness`,
`Contrast`, `Volume`, `Input source code` and `Input source`, so the following
actions can pull individual values out of it. The values are what Crisp last read
from the monitor, not a fresh I2C transaction — use *Refresh Displays* first if
that matters.

Input source is the monitor's **raw VCP 0x60 code**, not a port name. Codes are
not portable between models (this fork's BenQ MA320U reports `19`, which no VESA
table defines), so offering "HDMI 1" in a shortcut would be a guess presented as
a fact. The panel's *Calibrate…* wizard is the safe way to learn a monitor's
codes.

---

## The `crisp://` URL scheme

```
crisp://display/<display-uuid>/<feature>?value=<v>
crisp://displays/refresh
```

`<feature>` is the registry's own name for the VCP code — `brightness`,
`contrast`, `volume`, `input` — the same spelling the quirks database uses.
Percent-shaped features take a number (clamped to 0–100); `input` takes a raw
code, decimal or `0x`-prefixed.

```sh
open 'crisp://display/AEB55F97-FD93-4F8D-AD10-0942959D069C/brightness?value=50'
open 'crisp://displays/refresh'
```

### The security model

A registered URL scheme is not a private channel: **any web page can navigate to
`crisp://…`**, and macOS hands it to the app with no gesture from the user beyond
following a link. The rules follow from that.

1. **A destructive write always asks.** `DDCFeatureRegistry` marks a feature
   destructive when getting it wrong costs something the Mac cannot undo — VCP
   0x60 switches the panel to a port that may have nothing attached, and only the
   monitor's own buttons can bring it back. `AutomationRequest.plan` has three
   outcomes and a destructive feature can only ever produce `needsConfirmation`.
   There is **no bypass parameter, no trusted flag and no preference** that
   changes this, from any surface.
2. **The consent is a value, not a convention.** Only
   `AutomationService.confirm(…)` can produce a `UserConsent`, whose initialiser
   is `fileprivate`; every destructive apply demands one as an argument. Skipping
   the dialog is not a discipline someone has to remember, it is a value a caller
   cannot obtain. The same value goes all the way down: the DDC write gate's
   `Authorization.userConfirmed` carries a `UserConfirmation` that
   `DDCFeatureDiscovery` will only mint from a `DestructiveWriteConsent`, of which
   `UserConsent` is one — so the dialog that ran is what authorises the frame that
   reaches the monitor, rather than each layer asserting to the next that someone
   asked. (`DDCFeatureDiscovery.ApprovedWrite` is the same shape again, for the
   value that finally goes on the wire.)
3. **Anything outside the grammar is refused whole**, including unknown query
   items — so a `?confirmed=true` cannot even be silently ignored: the URL
   becomes a no-op.
4. **A malformed URL is a quiet no-op.** No crash, no partial write, no value
   coerced into something writable. A URL naming a display that is not attached
   does nothing at all, and does not raise a dialog about a monitor that is not
   there.
5. **There is no `main` or `all` alias.** Requiring a UUID a link author has to
   know first is not a security boundary, but it is the difference between a
   drive-by and a targeted click.

`CrispURLTests` and `AutomationRequestTests` pin all of it, including the
exhaustive property: *no automation origin can apply any destructive VCP code in
the registry, with any value shape.*

---

## Global keyboard shortcuts

Settings › **Keyboard Shortcuts**: click a field, press a combination. Brightness
up/down and volume up/down/mute. Nothing is assigned by default.

These are Carbon `RegisterEventHotKey` hot keys, and that matters here
specifically. The F1/F2 media keys are captured with a `CGEventTap`, which needs
an **Accessibility** grant — a grant bound to the app's code signature, so a
rebuild, an upgrade or a replaced bundle can leave the System Settings toggle
switched on over a TCC record that no longer matches, and the keys silently stop
working. (There is a whole diagnostic state, a status row and a reset button for
that failure; it is the one that looks exactly like success.)
`RegisterEventHotKey` needs **no Accessibility grant at all**: the app asks for
one specific combination and is handed that key. So these shortcuts keep working
in precisely the state that kills the media-key path.

Rules, all enforced in `HotkeyBinding` (pure, tested):

- **A combination needs ⌘, ⌥ or ⌃.** A global hotkey on a bare letter would take
  that letter from every app in the session. ⇧ alone does not count.
- **A combination another action owns is refused, not moved** — the recorder
  names the owner. Silently reassigning is how a shortcut disappears with nothing
  to explain it.
- **If macOS refuses the registration** (another app already owns the
  combination), the row says so rather than showing a shortcut that never fires.
- **A hand-edited settings file cannot install what the UI would refuse**: the
  decoder drops modifier-less combinations, duplicates and unknown action names.

Which displays a brightness shortcut affects follows the existing *Brightness
Keys* preference (pointer / all / selected), so the two key surfaces cannot
disagree. Volume follows the default audio output, as the volume keys do.

`HotkeyAction` names only changes the panel's own sliders already make, and
nothing destructive will be added to it: a hotkey is one keypress with no dialog
in front of it.

---

## Why no local socket

BetterDisplay binds `localhost:55777`. This fork does not, and the argument is
not "sockets are scary":

- **Everything a socket would carry is already carried.** `crispctl` covers the
  scripted case over the same DDC stack, the URL scheme covers the "fire and
  forget" case, and App Intents cover the composable case — with a typed
  parameter picker no HTTP API gets for free.
- **A listening socket is reachable by every process on the machine**, including
  a page's `fetch('http://localhost:55777/…')` from a browser that will happily
  make the request. That is a strictly larger surface than a URL scheme, which at
  least funnels through LaunchServices and cannot read a response.
- **It would need its own copy of every rule in here** — the destructive gate,
  the clamping, the UUID lookup — or it would become the one entry point that
  quietly did not have them.
- **The failure modes are ours to own**: a port already in use, a half-open
  connection, a request arriving during a display reconnect. None of that risk is
  bought back by a capability the three existing surfaces lack.

If a socket is ever warranted, the bar is a concrete use case that `crispctl` and
App Intents genuinely cannot serve — and it would have to route through
`AutomationRequest.plan` like everything else.

---

## Where it lives

| Concern | File |
|---|---|
| What automation may ask for; the destructive rule | `Crisp/Models/AutomationRequest.swift` |
| The `crisp://` grammar | `Crisp/Models/CrispURL.swift` |
| Shortcut combinations, conflicts, persistence shape | `Crisp/Models/HotkeyBinding.swift` |
| Executing a request; the one confirmation dialog | `Crisp/Services/AutomationService.swift` |
| Carbon hot-key registration and dispatch | `Crisp/Services/HotkeyService.swift` |
| Shortcuts entity + query | `Crisp/Intents/DisplayEntity.swift` |
| The six intents | `Crisp/Intents/CrispIntents.swift` |
| The recorder UI | `Crisp/Views/HotkeyRecorderView.swift` |
| URL delivery, hotkey start-up | `Crisp/App/AppDelegate.swift` |
| Scheme registration | `scripts/make-app.sh`, `scripts/release.sh`, `scripts/build-dmg.sh` |
