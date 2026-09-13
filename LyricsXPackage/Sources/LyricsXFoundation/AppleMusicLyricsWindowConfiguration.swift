import AppKit

/// Window chrome for the Apple Music-style lyrics panel.
///
/// Two AppKit behaviours shape everything here, and both were established by
/// reading AppKit rather than by guessing:
///
/// - A background-only process never gets full screen for free.
///   `-[NSWindow _implicitlyAllowsFullScreenPrimary]` calls `_NXIsBackgroundOnly()`
///   first and bails out when it answers yes, so this app -- an `LSUIElement`
///   agent -- has to ask for `.fullScreenPrimary` explicitly or the zoom button
///   stays a plain zoom button.
/// - Full screen only auto-hides the titlebar when the window owns **neither** a
///   toolbar **nor** a titlebar accessory view controller;
///   `-[_NSFullScreenMenuBarCompanionController _originalWindowShouldAutomaticallyAutohide]`
///   answers no the moment either exists. A pinned titlebar insets the content
///   view, and the strip it leaves behind shows the full screen Space's black
///   backdrop straight through this window's clear background.
///
/// The panel wants both things at once: the empty toolbar is what gives a titled
/// window macOS's larger corner radius, and full screen has to be free of it.
/// So the toolbar is dropped on the way into full screen and restored on the way
/// out -- corners are moot while full screen anyway -- and the pin control lives
/// inside the panel instead of in a titlebar accessory.
public enum AppleMusicLyricsWindowConfiguration {
    public static let styleMask: NSWindow.StyleMask = [
        .titled,
        .closable,
        .miniaturizable,
        .resizable,
        .fullSizeContentView,
    ]

    public static let minimumSize = NSSize(width: 980, height: 600)

    @MainActor
    public static func apply(to window: NSWindow) {
        window.styleMask = styleMask
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = false
        window.contentMinSize = minimumSize
        installCornerRadiusToolbar(on: window)
    }

    /// An empty toolbar, carried for its side effect: a titled window with a
    /// toolbar is drawn with the larger of macOS's two window corner radii.
    @MainActor
    public static func installCornerRadiusToolbar(on window: NSWindow) {
        window.toolbar = NSToolbar()
        window.toolbarStyle = .unified
    }

    /// Everything that would keep AppKit from auto-hiding the titlebar has to be
    /// gone before the transition starts.
    ///
    /// The window level is part of that: a floating window sits above the
    /// detached titlebar window AppKit slides down when the pointer reaches the
    /// top of the screen, so a pinned panel would hide its own traffic lights.
    /// Pinning means nothing in full screen -- the panel owns the whole Space --
    /// so the level is dropped for the duration too.
    @MainActor
    public static func prepareForFullScreen(_ window: NSWindow) {
        window.toolbar = nil
        for accessory in window.titlebarAccessoryViewControllers.indices.reversed() {
            window.removeTitlebarAccessoryViewController(at: accessory)
        }
        window.level = .normal
    }

    @MainActor
    public static func restoreAfterFullScreen(_ window: NSWindow, isPinned: Bool) {
        installCornerRadiusToolbar(on: window)
        window.level = isPinned ? .floating : .normal
    }
}
