import AppKit
import Testing
@testable import LyricsXFoundation

private func makePanelWindow() -> NSWindow {
    NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
}

@Test @MainActor
func panelWindowAsksForFullScreenBecauseAnAgentAppNeverGetsItImplicitly() {
    let window = makePanelWindow()

    AppleMusicLyricsWindowConfiguration.apply(to: window)

    // `-[NSWindow _implicitlyAllowsFullScreenPrimary]` bails out for a
    // background-only process, and this app is an LSUIElement agent, so without
    // this the zoom button stays a plain zoom button.
    #expect(window.collectionBehavior.contains(.fullScreenPrimary))
    #expect(window.styleMask.contains(.fullSizeContentView))
    #expect(window.titlebarAppearsTransparent)
}

@Test @MainActor
func panelWindowCarriesAnEmptyToolbarForItsCornerRadius() {
    let window = makePanelWindow()

    AppleMusicLyricsWindowConfiguration.apply(to: window)

    // The toolbar has no items and is never meant to: a titled window with a
    // toolbar is the only way to get macOS's larger window corner radius.
    #expect(window.toolbar != nil)
    #expect(window.toolbar?.items.isEmpty == true)
    #expect(window.toolbarStyle == .unified)
}

@Test @MainActor
func fullScreenLeavesNothingThatWouldPinTheTitlebarOpen() {
    let window = makePanelWindow()
    AppleMusicLyricsWindowConfiguration.apply(to: window)
    let accessory = NSTitlebarAccessoryViewController()
    accessory.view = NSView()
    accessory.layoutAttribute = .right
    window.addTitlebarAccessoryViewController(accessory)
    window.level = .floating

    AppleMusicLyricsWindowConfiguration.prepareForFullScreen(window)

    // Either a toolbar or a titlebar accessory makes
    // `_originalWindowShouldAutomaticallyAutohide` answer no, which docks the
    // titlebar at the top of the screen for the whole session and insets the
    // content view -- the strip left behind is the black full screen Space
    // showing through this window's clear background.
    #expect(window.toolbar == nil)
    #expect(window.titlebarAccessoryViewControllers.isEmpty)
    // A floating window would cover the detached titlebar AppKit slides down
    // when the pointer reaches the top of the screen.
    #expect(window.level == .normal)
}

@Test @MainActor
func leavingFullScreenBringsBackTheCornerRadiusAndThePinnedLevel() {
    let window = makePanelWindow()
    AppleMusicLyricsWindowConfiguration.apply(to: window)
    AppleMusicLyricsWindowConfiguration.prepareForFullScreen(window)

    AppleMusicLyricsWindowConfiguration.restoreAfterFullScreen(window, isPinned: true)

    #expect(window.toolbar != nil)
    #expect(window.toolbarStyle == .unified)
    #expect(window.level == .floating)
}

@Test @MainActor
func leavingFullScreenUnpinnedReturnsToTheNormalLevel() {
    let window = makePanelWindow()
    AppleMusicLyricsWindowConfiguration.apply(to: window)
    AppleMusicLyricsWindowConfiguration.prepareForFullScreen(window)

    AppleMusicLyricsWindowConfiguration.restoreAfterFullScreen(window, isPinned: false)

    #expect(window.level == .normal)
}
