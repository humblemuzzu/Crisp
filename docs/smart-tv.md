# Smart-TV control (LG webOS and Samsung Tizen)

A television has no DDC/CI. Plug one into a Mac and every control this app owns
disappears: there is no I²C channel, so the brightness ladder falls to the GPU's
colour table and contrast, volume and input have nothing to write to.

Both LG and Samsung publish a LAN control protocol instead. This phase implements
those two, and it is the one real capability gap in this app that can be closed
**without going anywhere near the private WindowServer frameworks that
AGENTS.md §2 exists because of** — it is a WebSocket and some JSON.

---

## 1. What is deliberately not here: HDMI-CEC

CEC is the obvious idea and it is a dead end. Written down so it is not
re-proposed every six months:

- macOS publishes no CEC API. The only working path is Apple's private,
  undocumented one, which rule #1 forbids.
- The DPCD tunnelling registers a DisplayPort→HDMI adapter would need are not
  reachable from user space.
- Decisively: **the CEC command set contains no brightness command at all.** Even
  a successful implementation would not answer the question this feature exists
  for.

There is no stub, no placeholder enum case and no `// TODO: CEC`. An empty case
labelled `cec` is an invitation.

---

## 2. Architecture

The same shape as the DDC stack, one protocol family over:

| DDC | Smart TV |
|---|---|
| `DDCTransport` (bytes in, bytes out) | `TVTransport` (frames in, frames out) |
| `IOKitDDCTransport` | `LGWebOSTransport`, `SamsungTizenTransport` |
| `DDCPacket`, `DDCProtocolEngine` (pure) | `WebOSSSAP`, `TizenRemote`, `TVTrust` (pure) |
| `FakeDDCTransport` | `FakeTVTransport` |
| `DDCFeatureRegistry` | `TVFeatureRegistry` |
| `DDCFeatureDiscovery` write gate | `TVWriteGate` (same `Authorization` type) |
| `DDCService` | `TVConversation` + `TVDeviceService` |

Everything that decides anything is pure and compiles into the headless
`CrispTests` target. That is not tidiness: **there is no television on the
network this was developed on**, so the tests against `FakeTVTransport` plus code
review are the entire verification. Nothing below has been run against real
hardware, and the report that accompanied this work says so.

---

## 3. LG webOS (SSAP over WebSocket)

- Ports `ws://<ip>:3000` (plaintext, older firmware) then `wss://<ip>:3001`
  (TLS, webOS 5+/2020+ often refuse 3000).
- **No `Origin` header.** The TV rejects browser-origin connections;
  `URLSessionWebSocketTask` sends none, which is why nothing sets one.
- Pairing sends a `register` message with LG's well-known test-app manifest and
  signature; the TV shows an on-screen accept prompt and answers `registered`
  with a 32-character `client-key`. A **stale key simply re-triggers the prompt**
  and yields a new key, which is adopted — there is no "key rejected" reply, and
  correspondingly no such branch in `WebOSSSAP.Pairing`.
- Envelope `{"id":…,"type":…,"uri":…,"payload":…}`. **The TV echoes the id**, so
  correlation is by id alone (`WebOSSSAP.Correlator`) — replies arrive in
  whatever order the services behind them finish.
- Success is `payload.returnValue` **or** `payload.subscribed`. Checking only the
  first reads every successful subscribe as a failure.
- `system/turnOff` is fire and forget: the socket goes down with the TV. Power
  **on** is not possible over this socket at all — it needs Wake-on-LAN — and the
  UI does not pretend otherwise.

### Brightness, which is the interesting part

Reading is ordinary: `settings/getSystemSettings` with `category: picture`
returns `backlight`, `brightness`, `contrast`, `pictureMode`. Note that
`backlight` is the light output and `brightness` is the black level; conflating
them is why some remote apps appear to do nothing.

Writing is not ordinary. The direct `setSystemSettings` answers "404 no such
service or method" on current firmware. The working path is a
`createAlert`/`closeAlert` round trip whose handlers embed
`luna://com.webos.settingsservice/setSystemSettings`. It is **write-only** — no
value comes back — and it may be closed off by a future firmware, so a failure is
treated as ordinary and reported honestly rather than swallowed.

### Sound output

`setVolume` is silently ignored when audio is routed to ARC/optical/a soundbar:
the call succeeds, `returnValue` is true, and nothing changes.
`WebOSSSAP.absoluteVolumeIsIgnored` checks `soundOutput` and the panel says so
instead of leaving a slider that reports success and does nothing.

---

## 4. Samsung Tizen (WebSocket)

- **Detect first:** `GET http://<ip>:8001/api/v2/`. Every boolean-ish field is a
  *string* (`"TokenAuthSupport":"true"`), and that field decides port 8002 +
  token versus plain 8001. A parser expecting real booleans picks the wrong port
  on every TV.
- `id`/`udn` from that document is the stable key — never the address.
- The connect event carries the token at `data.token` on current firmware and at
  `data.clients[0].attributes.token` on older models. **Both are read**, because
  a client that reads only the first pairs fine on a new TV and silently never
  pairs on an old one.
- Everything is a remote key: `KEY_VOLUP`, `KEY_MUTE`, `KEY_POWER`, `KEY_SOURCE`,
  `KEY_HDMI1`…`KEY_HDMI4`. Fire and forget, **rate-limited to one per second** —
  faster drops the *connection*, not the key.
- Absolute volume is a different protocol entirely: UPnP SOAP `RenderingControl`.
  The control URL is discovered from the device description, never hardcoded
  (real TVs use 9197 *and* 7676 with varying paths).

### Two things Tizen cannot do, stated rather than faked

- **Brightness is not reachable at all.** Tizen's brightness API is for apps
  running *on* the TV; the UPnP brightness variables only existed on pre-2016
  models. The panel shows a **disabled slider with the reason next to it**, the
  automation surfaces refuse with that same sentence, and
  `BrightnessRung.resolve(tv: .tizen, isReachable:)` answers
  `.unavailable(reason: .tvBrightnessNotRemote)`. Walking the OSD with arrow keys
  is not control; it is guessing at a menu the app cannot see.
- **The current input is not readable locally** (it needs Samsung's cloud), so it
  is reported as unknown. Input switching still works — `KEY_HDMI1`…`KEY_HDMI4`
  where the model supports it, `KEY_SOURCE` as the portable fallback.

---

## 5. The brightness ladder gains a rung

```
1. .ddcHardware   the monitor's own backlight over DDC/CI (or IOKit, built-in)
2. .tvNetwork     a paired TV's own backlight, over the LAN          ← new
3. .gammaTable    the GPU transfer table: the image, not the backlight
4. .overlay       a black click-through window
5. .unavailable   nothing can dim this display; say so
```

`.tvNetwork` sits below DDC because the cable needs no pairing and works when the
network does not, and above gamma because it moves the actual backlight — which
is the property the whole ladder is ordered by.

A display with no TV bound to it carries `tvBacklightReachable: nil` and resolves
through exactly the branches it always did. **There is no behaviour change for a
DDC monitor**, and `BrightnessRungTests` asserts it first.

---

## 6. Security

### Credentials

The webOS client key and the Tizen token are bearer credentials: anything holding
one can turn that television off from anywhere on the network. They live in the
**Keychain** (`TVCredentialStore`), `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`,
and never in `UserDefaults` or `displays.json`. `TVDevice` has no field that could
hold one, and `TVPersistenceTests` searches the whole encoded document for the
words a credential would be spelled with.

### TLS: trust on first use

Both TLS ports present a self-signed certificate that chains to nothing, so
ordinary validation cannot succeed on any TV, ever. Every other client deals with
this by turning validation off entirely, which makes the TLS obfuscation.

Crisp pins instead: the SHA-256 of the certificate presented at pairing time is
stored next to the credential, compared on every later connection, and a mismatch
**refuses the connection and says so** — it is never silently re-pinned, because a
silent re-pin is exactly equivalent to not checking. The comparison happens in
the TLS challenge, before the handshake completes, so a substituted device never
receives anything.

What this buys, stated plainly: it authenticates *the same device as the one you
paired with*. It does not authenticate "an LG television" and it does not protect
the very first connection — that is the "first use" in trust-on-first-use, and no
code here changes it. What it defends is the case that matters: paired on a
trusted network, impersonated later.

### Networking is opt-in

No LAN scan at launch, no background discovery, no periodic poll. A packet leaves
the Mac when the user adds a TV, opens the TV section, moves a control, or fires
an automation they wrote. `com.apple.security.network.client` was added in this
phase and no earlier one, so the diff that granted network access is the diff that
needed it — and `scripts/check-boundaries.sh` now pins the entitlement set, so
the next one has to be argued for in that file.

There is deliberately **no** `com.apple.security.network.server`: Crisp binds no
port and listens for nothing (see `docs/automation.md`).

---

## 7. Destructive actions

TV power-off and input switching are destructive by the same reasoning as VCP
0xD6 and 0x60: a wrong input leaves a black screen, and a TV switched off cannot
be switched back on over this protocol at all.

They go through the **existing** gate, not a parallel one:

- `TVActionRequest.plan` is total and its answer for a destructive feature can
  only be `needsConfirmation`. There is no origin, parameter or flag that
  produces `.ready`.
- `TVWriteGate.approve` takes a `DDCFeatureDiscovery.Authorization` — the same
  type, carrying the same `UserConfirmation`, mintable only from the same
  `DestructiveWriteConsent` protocol.
- **No new `DestructiveWriteConsent` conformer was added.** The panel reuses
  `PanelConfirmation` by going through the app's one
  `destructiveDDCWriteConfirmation` alert; automation reuses
  `AutomationService.UserConsent` by going through the same `NSAlert` a
  destructive `crisp://` DDC write does. AGENTS.md calls a fourth conformer the
  remaining escape hatch in the design; smart-TV support did not need it.
- `TVWriteGate.ApprovedTVAction` has a `fileprivate` initialiser, so a write path
  takes its feature and value **from the token** rather than from the request it
  thought it was performing. Skipping the gate does not produce an unguarded
  write; it produces nothing to hand the transport.

`crispctl` deliberately does not link the app's gate, for the reason it already
documents for destructive VCP codes: the two things that mint a consent are a
SwiftUI alert and an `NSAlert`, and declaring a third conformer for a command
line is precisely the escape hatch. It reproduces the part that protects the user
instead — the hazard printed, and `--force` or an answered `y/N` prompt, with an
outright refusal when stdin is not a terminal.

---

## 8. Surfaces

| Surface | Entry point |
|---|---|
| Panel | `Crisp/Views/TVDevicesView.swift` — collapsed row, `TVs — None added` until opened |
| URL | `crisp://tv/<device-id>/<feature>?value=<v>` (`CrispURL`) |
| Shortcuts | `Crisp/Intents/TVIntents.swift` — five intents over a `TVDeviceEntity` |
| CLI | `crispctl tv list`, `crispctl tv <feature> <tv-id> <value> [--force]` |

All four go through `TVActionRequest.plan`, so none can do something the others
cannot.

---

## 9. What could not be verified

There was no television on the network. Everything above is verified by unit
tests against `FakeTVTransport` and by code review. Specifically **not** verified:

- that any real TV accepts these frames;
- that the webOS `createAlert` backlight write still works on current firmware;
- that a real certificate fingerprint is stable across a TV reboot;
- the SSDP discovery path end to end (multicast behaviour depends on the router);
- the UPnP description paths, which vary by model — hence a candidate list rather
  than one address, and the control URL always read out of the document.
