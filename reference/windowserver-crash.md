# WindowServer segfault, August 2026 — not caused by this app

Read of the macOS crash report WindowServer left behind after one of the hard
locks described in `AGENTS.md` §2. The raw `.ips` is **not** kept in the repo:
it carries a crash-reporter key, an incident UUID, a boot-session UUID and a
hardware model, none of which add anything to the finding. What follows is the
whole technically meaningful content of that report.

**Why this file exists:** it is the evidence that this particular crash was a
use-after-free inside Apple's own CoreAnimation display code, not something an
external DDC app can cause or prevent.

---

## 1. The report, stripped

| Field | Value |
|---|---|
| Process | `WindowServer` (`/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer`) |
| Process role | Graphics |
| First party | yes (`is_first_party: 1`), Apple-signed `com.apple.WindowServer` |
| OS | macOS 26.6.1, build 25G76 |
| Architecture | ARM-64 |
| Exception | `EXC_BAD_ACCESS` / `SIGSEGV`, `KERN_INVALID_ADDRESS` at `0x222222222222227a` |
| Fault class | ESR: *(Data Abort) byte read Translation fault* |
| Faulting thread | 0 (the main WindowServer thread) |
| Address mapping | `0x22222222227a is not in any region` — unmapped, no region before or after |

Symbolicated registers on the faulting thread:

```
x8, x9  = 0x2222222222222222
x15     = OBJC_CLASS_$_CAWindowServerDisplay
x16     = vtable for CA::WindowServer::AppleExternalDisplay
```

## 2. What that says

`0x22` repeated is not data. It is a **freed-memory poison pattern**: the
allocator fills a block with it on release so that a later use is guaranteed to
fault on an obviously bogus address instead of quietly reading someone else's
object.

The fault address is that pattern plus an offset:

```
0x222222222222227a - 0x2222222222222222 = 0x58   (88 bytes)
```

That is the signature of a **use-after-free**: code loaded a pointer out of a
block that had already been freed and poisoned, then dereferenced a field 0x58
bytes into it. The two symbols sitting in the registers name the object
involved — `CA::WindowServer::AppleExternalDisplay` and
`CAWindowServerDisplay`, CoreAnimation's representation of an *external*
display. The lifetime being mismanaged is a display object's, inside Apple's
code, on the WindowServer main thread.

(The copy that was recovered is truncated part-way through the faulting
thread's register dump, so there is no symbolicated backtrace beyond this.
Nothing in the recovered portion contradicts the reading above.)

## 3. Why it exonerates this app

1. **The app is not in the report.** Its name appears nowhere in the crash log:
   not as the crashing process, not in the coalition, not in the recovered
   frames or register symbols.
2. **The crash is inside WindowServer**, in CoreAnimation's external-display
   object — memory this app has no handle on and no way to reach. Crisp's DDC
   path talks I2C to the monitor's controller through `IOAVService*`; it never
   calls into SkyLight, CoreDisplay, CoreBrightness or any other
   WindowServer-adjacent private framework (AGENTS.md §3, rule #1).
3. **No client API frees that object.** Its lifetime is WindowServer's own
   bookkeeping. An outside process can at most *provoke* the code path that
   mismanages it (by causing a display reconfiguration); it cannot introduce
   the mismanagement.
4. It is consistent with the incident's shape: WindowServer dies, the screen
   freezes, the machine has to be power-cycled. Same class as BetterDisplay
   #5367 (see `betterdisplay-forensics.md`), and the reason the fix was to stop
   driving brightness through those frameworks at all.

## 4. What it does not say

The report does not identify what *triggered* the free. Display
reconfiguration (sleep, hotplug, a mode change) is the usual precondition for
this family of bug, and both software dimming and plain unplugging cause
reconfiguration. So this is evidence of *where* the bug lives, not proof that
any particular app poked it.
