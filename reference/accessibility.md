# What SwiftUI actually publishes to the accessibility API on macOS 26

This is the measurement behind `scripts/check-accessibility.sh` and the
accessibility pass over the fork's windows. It exists because the obvious
diagnosis of the obvious symptom is wrong, and acting on it would have made the
app less accessible, not more.

## The symptom

Driving one of the fork's windows through `System Events` returns nothing
useful:

```
$ osascript -e 'tell application "System Events" to tell process "Crisp" \
    to get name of every UI element of window 1'
missing value, missing value, missing value, …

$ osascript -e 'tell application "System Events" to tell process "Crisp" \
    to get every button of window 1'
Invalid index. (-1719)
```

Read as "the buttons have no labels, so VoiceOver is blind here". That reading
is not supported by what the AX server actually serves.

## The measurement

A minimal SwiftUI app — an `NSWindow` with `styleMask: [.titled, .closable]`
and an `NSHostingView` content view, the same construction all three fork
windows use — was built with three buttons and asked, from inside its own
process, what `AXUIElementCopyAttributeValue` returns for each element:

```swift
Button("A-plain-bordered") {}
Button("B-label") {}.accessibilityLabel("LABEL_B")
Button("C-ignore-label") {}.accessibilityElement(children: .ignore)
                           .accessibilityLabel("LABEL_C")
```

```
AXWindow AXTitle="AXRepro Window" AXRoleDescription="standard window"
  AXGroup AXRoleDescription="group"
    AXButton  AXRoleDescription="button"  AXAttributedDescription="A-plain-bordered"
    AXButton  AXRoleDescription="button"  AXAttributedDescription="LABEL_B"
    AXUnknown                             AXAttributedDescription="LABEL_C"
  AXButton AXRoleDescription="close button"
  …
```

And the full attribute list of one of those buttons, via System Events:

```
AXParent AXRoleDescription AXAutoInteractable AXChildren AXPath
AXAttributedDescription AXEnabled AXTopLevelUIElement AXSubrole AXWindow
AXRole AXActivationPoint AXChildrenInNavigationOrder AXFrame AXSize AXPosition
```

No `AXTitle`. No `AXDescription`. Not empty — **absent from the list**.

A `Slider` in the same window, for contrast, does carry `AXDescription`
(`"Display brightness"`, from `.accessibilityLabel`), along with `AXTraits`,
`AXSortPriority`, `AXValueDescription` and the rest of SwiftUI's own attribute
set. So `.accessibilityLabel` is not being ignored; buttons are simply served by
a different element implementation.

## Three conclusions, and what each one is worth

**1. VoiceOver is fine; scripted automation is not.** SwiftUI publishes a
button's name only as `AXAttributedDescription`. `System Events` reads
`AXTitle`/`AXDescription`, finds neither, and reports `missing value`. The
`missing value` output is a real limitation of AppleScript-driven automation
against SwiftUI, not proof that the app is unusable with a screen reader.

One honest caveat about the strength of that last sentence. Everything else on
this page was measured; this was not. That `Button("Next")` is *announced* rests
on the platform convention that VoiceOver reads `AXAttributedDescription`, not on
a VoiceOver session anyone here sat and listened to. It is very likely right, and
it is the only inferential step in the document — so it is the one to re-check
first if this ever stops adding up.

A later reviewer added a detail that strengthens the argument: querying
`AXAttributedDescription`'s *value* through `System Events` fails with `-10000`
even though the attribute is advertised as supported, because it cannot marshal
an `NSAttributedString`. So "just point the automation at the right attribute"
is not available as a fix, which is why the gate this work added is static.

The same split shows up on sliders: `.accessibilityValue("50%")` lands in
`AXValueDescription` while `AXValue` stays the raw `50.0`. Again VoiceOver reads
the right one.

**2. `every button of window 1` was never going to work.** The buttons are
children of the hosting view's `AXGroup`, not of the window; that AppleScript
asks only for direct children. `-1719` here means "the collection is empty at
this level", which is true and uninteresting. System Events' window addressing
against an `LSUIElement` process is also unreliable in its own right — the same
query against the same live window alternated between working and `-1719`
during this investigation, with no change to the app.

**3. The dangerous fix.** `.accessibilityElement(children: .ignore)` applied to
a `Button` — the reflexive way to force a label on to a control that appears not
to have one — demoted it from `AXButton` to **`AXUnknown`**. It keeps the label
and loses the role: it is no longer a button to VoiceOver or to any automation.
Pasting that modifier on to "fix" the symptom is strictly worse than the
unlabelled button it was meant to repair.

That modifier is correct on *static* content, where it merges decoration into
one fact — `BrightnessRungBadge` uses it to read its coloured dot and its word
as a single sentence. `scripts/check-accessibility.sh` therefore refuses it on
controls and permits it elsewhere.

Even on static content it costs the role, though: `children: .ignore` alone
leaves the element `AXUnknown`. Adding `.accessibilityAddTraits(.isStaticText)`
restores it, and does something better besides — the label then appears in
`AXValue` as well, which is an attribute plain AppleScript automation can
actually read:

```
AXUnknown     AXAttributedDescription="Brightness path: DDC. …"
AXStaticText  AXValue="Brightness path: DDC. …"     # with .isStaticText added
```

`.accessibilityElement(children: .combine)` produces `AXStaticText` on its own,
so the combined rows in the diagnostics and onboarding windows need no trait.

## What the gate checks, given all that

None of the above is observable from CI: it needs a GUI session, a running app,
and a granted Automation prompt. What survives into a static check is the
source-level cause — a control that was never given a name in source has
nothing to publish through `AXTitle`, `AXDescription` or
`AXAttributedDescription`, on any macOS. That, plus the `AXUnknown` trap and the
window identifiers, is what `scripts/check-accessibility.sh` enforces. Its
header states the limits; `--runtime` is the advisory live companion for a
developer machine.

## Reproducing

The probe was a throwaway: a single-file SwiftUI app in a hand-built `.app`
bundle (it must be a bundle — a bare executable's windows are not reliably
visible to the AX server), dumping its own tree through
`AXUIElementCreateApplication(getpid())`. Rebuild it from the snippets above if
a future macOS changes the answer; the answer is worth re-checking, because it
is the kind of thing Apple changes between releases without saying so.
