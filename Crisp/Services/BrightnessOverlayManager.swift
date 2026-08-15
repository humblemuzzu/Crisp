import AppKit
import CoreGraphics

/// The bottom working rung of the brightness ladder (`BrightnessRung.overlay`):
/// a black, click-through window per display whose opacity is the dim level.
///
/// This is the dimmer of last resort, for screens where neither DDC nor the GPU
/// transfer table does anything a viewer can see — virtual, AirPlay and Sidecar
/// screens, and displays that reject `CGSetDisplayTransferByTable`. It is plain
/// AppKit: `CGShieldingWindowLevel` is public, and nothing here talks to
/// WindowServer's private surface (AGENTS.md rule #1).
///
/// Lifecycle mirrors NotchOverlayManager/EDROverlayManager: one window per
/// `CGDirectDisplayID`, re-framed when the screen geometry changes and closed
/// when the screen goes away, so an unplug is a no-op and a reconnect can never
/// inherit a stale window covering it (rule #4).
@MainActor
final class BrightnessOverlayManager {
    static let shared = BrightnessOverlayManager()

    private var windows: [CGDirectDisplayID: NSWindow] = [:]

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    /// Dim `displayID` to `percent` (0–100) by covering it with black.
    ///
    /// The window is created on the first dim and then kept: a drag crosses the
    /// full-brightness point constantly, and closing/reopening a shielding-level
    /// window on every crossing flickers. At 100% it simply sits at alpha 0.
    func setBrightness(_ percent: Double, for displayID: CGDirectDisplayID) {
        let alpha = BrightnessOverlay.alpha(forBrightnessPercent: percent)
        guard let window = windows[displayID] ?? makeWindow(for: displayID) else { return }
        window.contentView?.alphaValue = CGFloat(alpha)
    }

    func removeOverlay(for displayID: CGDirectDisplayID) {
        guard let window = windows.removeValue(forKey: displayID) else { return }
        window.close()
    }

    func removeAll() {
        for displayID in Array(windows.keys) { removeOverlay(for: displayID) }
    }

    private func makeWindow(for displayID: CGDirectDisplayID) -> NSWindow? {
        guard let screen = NSScreen.screen(for: displayID) else { return nil }

        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        // close() must not free the window while AppKit still holds a reference.
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        // Above everything the user can see, including other apps' full-screen
        // windows: a brightness control that stops applying when you open a video
        // player is not a brightness control.
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        // Click-through. The window covers the entire screen, so anything less
        // would swallow every click on that display.
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.stationary, .canJoinAllSpaces, .ignoresCycle]
        // Keep the dim out of screen recordings and screenshots: it is a local
        // viewing preference, not part of the picture being shared.
        window.sharingType = .none

        let black = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        black.wantsLayer = true
        black.layer?.backgroundColor = NSColor.black.cgColor
        black.alphaValue = 0
        window.contentView = black
        window.orderFrontRegardless()

        windows[displayID] = window
        return window
    }

    /// Resolution changes, rotation, arrangement moves and unplugs all arrive
    /// here. Re-frame what survived, close what did not.
    @objc private func screenParametersChanged() {
        // Snapshot: removeOverlay mutates `windows` while we walk it.
        for (displayID, window) in Array(windows) {
            guard let screen = NSScreen.screen(for: displayID) else {
                removeOverlay(for: displayID)
                continue
            }
            guard window.frame != screen.frame else { continue }
            window.setFrame(screen.frame, display: true)
            window.contentView?.frame = CGRect(origin: .zero, size: screen.frame.size)
        }
    }
}
