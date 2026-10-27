import AppKit
import Testing
@testable import LyricsXFoundation

@Test @MainActor
func lyricsHUDWindowJoinsEverySpaceAfterConfiguration() {
    let window = NSPanel(
        contentRect: .zero,
        styleMask: [.titled, .utilityWindow],
        backing: .buffered,
        defer: false
    )

    LyricsHUDWindowConfiguration.apply(to: window)

    #expect(window.collectionBehavior.contains(.canJoinAllSpaces))
    #expect(window.collectionBehavior.contains(.fullScreenAuxiliary))
    #expect(!window.collectionBehavior.contains(.moveToActiveSpace))
    #expect(window.collectionBehavior == LyricsHUDWindowConfiguration.collectionBehavior)
}

@Test
func lyricsWindowToggleUsesActualWindowVisibility() {
    #expect(
        LyricsWindowPresentationDecision.action(
            isWindowVisible: false,
            isApplicationActive: false
        ) == .show
    )
    #expect(
        LyricsWindowPresentationDecision.action(
            isWindowVisible: true,
            isApplicationActive: false
        ) == .bringToFront
    )
    #expect(
        LyricsWindowPresentationDecision.action(
            isWindowVisible: true,
            isApplicationActive: true
        ) == .close
    )
}

@Test
func lyricsWindowFallsBackToTheSystemFontWhenItsFontIsGone() {
    // A font chosen for the lyrics window can be removed in Font Book or
    // deactivated by a font manager while its name stays in the preferences.
    let font: NSFont? = LyricsHUDWindowConfiguration.textFont(
        named: "LyricsX Test Font That Is Not Installed",
        size: 21
    )

    #expect(font?.pointSize == 21)
}

@Test
func lyricsWindowUsesTheChosenFontWhileItIsInstalled() {
    let font: NSFont? = LyricsHUDWindowConfiguration.textFont(named: "Helvetica", size: 13)

    #expect(font?.fontName == "Helvetica")
    #expect(font?.pointSize == 13)
}
