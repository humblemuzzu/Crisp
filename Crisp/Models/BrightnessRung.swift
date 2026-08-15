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
///   2. `.gammaTable`   — `CGSetDisplayTransferByTable`, a public GPU lookup table.
///   3. `.overlay`      — a black click-through window; works on literally any screen.
///   4. `.unavailable`  — nothing can dim this display. Say so; do not render a
///                        live-looking control that does nothing.
///
/// Every degraded rung carries the reason it was chosen, and every reason has
/// user-presentable prose (`Reason.text`) rather than a debug string, because it
/// is shown to the user on hover.
enum BrightnessRung: Equatable {
    /// The monitor's own backlight, over DDC/CI (external) or IOKit (built-in).
    case ddcHardware
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

        /// User-presentable explanation, shown as the badge's tooltip and (for
        /// `.unavailable`) inline under the disabled slider.
        var text: String {
            switch self {
            case .noDDCChannel:
                return String(localized: "This display has no DDC channel on this connection, so Crisp dims the image with the GPU's color table instead of the backlight.")
            case .hdrIgnoresDDC:
                return String(localized: "This display is in HDR mode and ignores hardware brightness commands, so Crisp dims the image with the GPU's color table.")
            case .virtualDisplay:
                return String(localized: "Virtual, AirPlay and Sidecar screens have no backlight and no color table of their own, so Crisp dims them with an overlay.")
            case .gammaRejected:
                return String(localized: "This display refused the color-table write Crisp uses for software dimming, so Crisp dims it with an overlay.")
            case .notDrawable:
                return String(localized: "macOS is not rendering to this display, so Crisp has no way to dim it.")
            case .displayOffline:
                return String(localized: "This display is offline, so there is nothing to dim.")
            }
        }
    }

    /// False only for `.unavailable`: the brightness control must be disabled
    /// rather than moving a slider that writes nowhere.
    var isControllable: Bool {
        if case .unavailable = self { return false }
        return true
    }

    /// The reason, for the rungs that have one. `.ddcHardware` needs no excuse.
    var reason: Reason? {
        switch self {
        case .ddcHardware: return nil
        case .gammaTable(let r), .overlay(let r), .unavailable(let r): return r
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

        init(
            isOnline: Bool = true,
            isBuiltin: Bool = false,
            isVirtual: Bool = false,
            ddcAvailable: Bool? = nil,
            hdrSoftwareDimmed: Bool = false,
            gammaWritable: Bool = true,
            hasScreen: Bool = true
        ) {
            self.isOnline = isOnline
            self.isBuiltin = isBuiltin
            self.isVirtual = isVirtual
            self.ddcAvailable = ddcAvailable
            self.hdrSoftwareDimmed = hdrSoftwareDimmed
            self.gammaWritable = gammaWritable
            self.hasScreen = hasScreen
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

        // A display with no DDC channel at all is the more fundamental fact than
        // "this one is in HDR mode", so it wins the explanation when both hold.
        let reason: Reason = capabilities.ddcAvailable == false ? .noDDCChannel : .hdrIgnoresDDC
        return softwareRung(reason: reason, capabilities: capabilities, allowGamma: true)
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
