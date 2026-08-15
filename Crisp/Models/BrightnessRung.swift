import Foundation

/// Which mechanism is actually dimming a display right now.
///
/// Crisp has four ways to make a screen darker and they are not interchangeable.
/// DDC moves the real backlight; the gamma table only makes the *image* darker
/// (the panel still emits the same light); the overlay just paints black over
/// everything. A user whose monitor quietly fell back a rung has no way to tell
/// from the slider alone — which is why the rung is a value the rest of the app
/// carries around and renders, rather than an implicit consequence of which
/// branch a write happened to take.
///
/// Highest capability first:
///   1. `.ddcHardware`  — I²C to the monitor's backlight register (or, for the
///                        built-in panel, the equivalent IOKit backlight path).
///   2. `.tvNetwork`    — a paired smart TV's own backlight, over its LAN control
///                        protocol. Still the real backlight, which is why it
///                        outranks gamma; below DDC because it depends on a
///                        network, a pairing and a device that may be switched
///                        off, none of which a cable does.
///   3. `.gammaTable`   — `CGSetDisplayTransferByTable`, a public GPU lookup table.
///   4. `.overlay`      — a black click-through window; works on literally any screen.
///   5. `.unavailable`  — nothing can dim this display. Say so; do not render a
///                        live-looking control that does nothing.
///
/// Every degraded rung carries the reason it was chosen, and every reason has
/// user-presentable prose (`Reason.text`) rather than a debug string, because it
/// is shown to the user on hover.
enum BrightnessRung: Equatable {
    /// The monitor's own backlight, over DDC/CI (external) or IOKit (built-in).
    case ddcHardware
    /// A paired television's own backlight, driven over the LAN rather than over
    /// the cable. Carries a reason because it is a *fallback* — the display had
    /// no DDC channel — even though what it moves is real hardware.
    case tvNetwork(reason: Reason)
    /// The GPU transfer table. Darkens the image, not the backlight.
    case gammaTable(reason: Reason)
    /// A black click-through window over the whole screen.
    case overlay(reason: Reason)
    /// Nothing left to try.
    case unavailable(reason: Reason)

    /// Why a display fell below `.ddcHardware`. Modelled as cases rather than
    /// free strings so the resolution rules stay comparable in tests; the prose
    /// the user reads hangs off `text`.
    enum Reason: Equatable {
        /// DDC writes to this display have failed: MST hub, DisplayLink dock,
        /// Studio Display (USB HID, not DDC/CI), or DDC/CI switched off in the OSD.
        case noDDCChannel
        /// A DisplayHDR monitor in HDR mode acks DDC brightness writes and then
        /// discards them, so the backlight cannot be driven while it is engaged.
        case hdrIgnoresDDC
        /// Virtual, AirPlay and Sidecar screens: no backlight, and their transfer
        /// table is not the thing that ends up on the far end of the link.
        case virtualDisplay
        /// The display refused `CGSetDisplayTransferByTable`.
        case gammaRejected
        /// macOS has no `NSScreen` for this display, so nothing can be drawn over it.
        case notDrawable
        /// The display has gone offline.
        case displayOffline
        /// A television, which has no DDC/CI at all — but a paired one whose LAN
        /// control protocol *does* reach the backlight. The rung above gamma.
        case tvHasNoDDC
        /// A paired TV whose platform has no remote brightness command. Samsung's
        /// Tizen is the whole of this case today; the sentence the user reads
        /// comes from `TVUnsupportedReason` so there is one wording, not two.
        case tvBrightnessNotRemote
        /// A TV that is added but not reachable right now: switched off, on
        /// standby, on another network, or never paired.
        case tvUnreachable

        /// User-presentable explanation, shown as the badge's tooltip and (for
        /// `.unavailable`) inline under the disabled slider.
        var text: String {
            switch self {
            // The `\` continuations only wrap the source line: each literal joins
            // back to exactly one sentence, which is the key in the String Catalog.
            case .noDDCChannel:
                return String(localized: """
                    This display has no DDC channel on this connection, so Crisp dims \
                    the image with the GPU's color table instead of the backlight.
                    """)
            case .hdrIgnoresDDC:
                return String(localized: """
                    This display is in HDR mode and ignores hardware brightness \
                    commands, so Crisp dims the image with the GPU's color table.
                    """)
            case .virtualDisplay:
                return String(localized: """
                    Virtual, AirPlay and Sidecar screens have no backlight and no \
                    color table of their own, so Crisp dims them with an overlay.
                    """)
            case .gammaRejected:
                return String(localized: """
                    This display refused the color-table write Crisp uses for \
                    software dimming, so Crisp dims it with an overlay.
                    """)
            case .notDrawable:
                return String(localized: "macOS is not rendering to this display, so Crisp has no way to dim it.")
            case .displayOffline:
                return String(localized: "This display is offline, so there is nothing to dim.")
            case .tvHasNoDDC:
                return String(localized: """
                    Televisions have no DDC/CI channel, so Crisp moves this TV's own backlight \
                    over the network instead.
                    """)
            case .tvBrightnessNotRemote:
                // One wording for this fact, shared with the TV panel's own
                // disabled control: a user who reads it in two places must not
                // find two different explanations.
                return TVUnsupportedReason.tizenHasNoRemoteBrightness.text
            case .tvUnreachable:
                return String(localized: """
                    Crisp cannot reach this TV right now, so there is nothing to dim. Check it is \
                    switched on and on the same network as this Mac.
                    """)
            }
        }
    }

    /// False only for `.unavailable`: the brightness control must be disabled
    /// rather than moving a slider that writes nowhere.
    var isControllable: Bool {
        if case .unavailable = self { return false }
        return true
    }

    /// Whether this rung moves real light output rather than the rendered image.
    /// True for DDC, the built-in panel and a TV over the network; false for
    /// gamma and the overlay, which only make the *picture* darker.
    var movesBacklight: Bool {
        switch self {
        case .ddcHardware, .tvNetwork: return true
        case .gammaTable, .overlay, .unavailable: return false
        }
    }

    /// The reason, for the rungs that have one. `.ddcHardware` needs no excuse.
    var reason: Reason? {
        switch self {
        case .ddcHardware: return nil
        case .tvNetwork(let r), .gammaTable(let r), .overlay(let r), .unavailable(let r): return r
        }
    }
}

extension BrightnessRung {
    /// Everything the ladder needs to know about one display. Each field is
    /// something the app already tracks; nothing here is a second source of truth.
    ///
    /// Defaults describe a plain, healthy external monitor, so a test (or a call
    /// site) only states the fields it actually cares about.
    struct Capabilities: Equatable {
        /// macOS still lists the display (`CGDisplayIsOnline`).
        var isOnline: Bool
        /// The built-in panel, driven through IOKit rather than DDC/CI. Reported
        /// as hardware: it really is the backlight.
        var isBuiltin: Bool
        /// A virtual / AirPlay / Sidecar screen (`VirtualDisplayService.isVirtualDisplay`).
        var isVirtual: Bool
        /// `BrightnessService.ddcAvailable`: nil = unproven, true = a DDC read or
        /// write has succeeded, false = writes have failed often enough to give up.
        var ddcAvailable: Bool?
        /// The monitor is in HDR mode, where it acks and then ignores DDC brightness.
        var hdrSoftwareDimmed: Bool
        /// No `CGSetDisplayTransferByTable` write for this display has been rejected.
        var gammaWritable: Bool
        /// AppKit has an `NSScreen` for this display, so an overlay window can cover it.
        var hasScreen: Bool
        /// A paired smart TV is bound to this display *and* Crisp can currently
        /// move its backlight over the network (`TVDeviceService`).
        ///
        /// `nil` — the normal case — means no TV is bound to this display at all,
        /// which is deliberately distinct from `false`. `false` is "a TV is bound
        /// and its backlight is out of reach right now": a Samsung, which has no
        /// remote brightness command at all, or an LG that is switched off. Both
        /// of those fall through to the software rungs exactly as before, because
        /// a TV that is also one of the Mac's screens really can still be dimmed
        /// with the GPU's colour table — the honest answer there is gamma, not
        /// "nothing works".
        var tvBacklightReachable: Bool?

        init(
            isOnline: Bool = true,
            isBuiltin: Bool = false,
            isVirtual: Bool = false,
            ddcAvailable: Bool? = nil,
            hdrSoftwareDimmed: Bool = false,
            gammaWritable: Bool = true,
            hasScreen: Bool = true,
            tvBacklightReachable: Bool? = nil
        ) {
            self.isOnline = isOnline
            self.isBuiltin = isBuiltin
            self.isVirtual = isVirtual
            self.ddcAvailable = ddcAvailable
            self.hdrSoftwareDimmed = hdrSoftwareDimmed
            self.gammaWritable = gammaWritable
            self.hasScreen = hasScreen
            self.tvBacklightReachable = tvBacklightReachable
        }
    }

    /// Picks the one rung a display sits on. Pure: no IOKit, no AppKit, no clock.
    ///
    /// Order matters and is the whole content of this function:
    ///   offline first (nothing else can be true of a display that is gone),
    ///   then the built-in panel (its IOKit backlight is unrelated to DDC),
    ///   then virtual screens (they can look DDC-capable for a moment but their
    ///   transfer table dims nothing the viewer sees),
    ///   then DDC, which is also where an *unproven* display sits: `nil` means the
    ///   write path still aims at DDC, and it flips to gamma the moment three
    ///   consecutive writes fail. Reporting it as hardware is what is true now.
    static func resolve(_ capabilities: Capabilities) -> BrightnessRung {
        guard capabilities.isOnline else { return .unavailable(reason: .displayOffline) }

        if capabilities.isBuiltin { return .ddcHardware }

        if capabilities.isVirtual {
            return softwareRung(reason: .virtualDisplay, capabilities: capabilities, allowGamma: false)
        }

        if capabilities.ddcAvailable != false && !capabilities.hdrSoftwareDimmed {
            return .ddcHardware
        }

        // The TV rung, between DDC and gamma. It sits here rather than above DDC
        // because a display that answers DDC should keep using it: the cable is
        // there, it needs no pairing, and it works when the network does not.
        // It sits above gamma because it moves the actual backlight, which is the
        // property the whole ladder is ordered by.
        if capabilities.tvBacklightReachable == true {
            return .tvNetwork(reason: .tvHasNoDDC)
        }

        // A display with no DDC channel at all is the more fundamental fact than
        // "this one is in HDR mode", so it wins the explanation when both hold.
        let reason: Reason = capabilities.ddcAvailable == false ? .noDDCChannel : .hdrIgnoresDDC
        return softwareRung(reason: reason, capabilities: capabilities, allowGamma: true)
    }

    /// The rung a paired television sits on, considered as a *device* rather than
    /// as one of the Mac's screens.
    ///
    /// A TV on the LAN is usually not a display at all — no `NSScreen`, no gamma
    /// table, no overlay to draw. So the ladder's software rungs do not apply and
    /// the answer is either "its own backlight, over the network" or an honest
    /// `.unavailable` with the reason next to the disabled control. That is
    /// exactly what a Samsung gets, permanently: Tizen has no remote brightness
    /// command, and a slider that silently does nothing would be worse than no
    /// slider (see `TVUnsupportedReason.tizenHasNoRemoteBrightness`).
    ///
    /// - Parameter isReachable: whether the control channel is up right now. A TV
    ///   that is off is not a TV whose brightness is unsupported, and the two
    ///   report differently because only one of them is fixed by pressing a
    ///   button on a remote.
    static func resolve(tv platform: TVPlatform, isReachable: Bool) -> BrightnessRung {
        switch TVFeatureRegistry.support(.brightness, on: platform) {
        case .unsupported:
            return .unavailable(reason: .tvBrightnessNotRemote)
        case .readWrite, .writeOnly:
            return isReachable ? .tvNetwork(reason: .tvHasNoDDC) : .unavailable(reason: .tvUnreachable)
        }
    }

    /// The bottom two rungs: gamma when it is both allowed and accepted, then the
    /// overlay, then honesty. `allowGamma` is false for screens where a transfer
    /// table is written successfully but dims nothing anyone can see.
    private static func softwareRung(
        reason: Reason,
        capabilities: Capabilities,
        allowGamma: Bool
    ) -> BrightnessRung {
        if allowGamma && capabilities.gammaWritable { return .gammaTable(reason: reason) }
        let overlayReason: Reason = allowGamma ? .gammaRejected : reason
        guard capabilities.hasScreen else { return .unavailable(reason: .notDrawable) }
        return .overlay(reason: overlayReason)
    }
}

/// The overlay rung's dim maths. Pure and separate from the AppKit window so the
/// safety cap is a tested rule rather than a magic number inside a view.
enum BrightnessOverlay {
    /// The overlay is never fully opaque. A user who drags to 0 on a display that
    /// has no other dimmer must still be able to see the slider they need to drag
    /// back; a black screen with a working-but-invisible control is not recoverable.
    static let maxAlpha: Double = 0.85

    /// Black-window alpha for a 0–100 brightness percentage.
    static func alpha(forBrightnessPercent percent: Double) -> Double {
        let clamped = min(100.0, max(0.0, percent))
        return min(maxAlpha, 1.0 - clamped / 100.0)
    }
}
