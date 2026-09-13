import CoreGraphics
import Testing
@testable import AppleMusicLyricsPanel

/// Music 26.6's Now Playing sizing, as `sub_100128AD8` / `sub_100128D3C` /
/// `sub_1001D0A1C` / `sub_1001284F8` compute it. The expected values are the
/// literals read out of `Music.i64`, plus the 2026-09-05 view-hierarchy
/// capture as a worked example (a 533.5 pt lyrics column → 38 pt).
struct NowPlayingLyricsLayoutPolicyTests {
    @Test(arguments: [
        (lyricsWidth: CGFloat(0), expectedFontSize: CGFloat(24)),
        (lyricsWidth: 299.9, expectedFontSize: 24),
        (lyricsWidth: 300, expectedFontSize: 28),
        (lyricsWidth: 527.9, expectedFontSize: 28),
        (lyricsWidth: 528, expectedFontSize: 38),
        (lyricsWidth: 533.5, expectedFontSize: 38),
        (lyricsWidth: 671.9, expectedFontSize: 38),
        (lyricsWidth: 672, expectedFontSize: 50),
        (lyricsWidth: 759.9, expectedFontSize: 50),
        (lyricsWidth: 760, expectedFontSize: 72),
        (lyricsWidth: 1200, expectedFontSize: 72),
    ])
    func mainFontSizeStepsByTheLyricsViewWidth(lyricsWidth: CGFloat, expectedFontSize: CGFloat) {
        #expect(
            AppleMusicLyrics.NowPlayingLyricsLayoutPolicy.mainFontSize(forLyricsWidth: lyricsWidth)
                == expectedFontSize
        )
    }

    /// Music's lyrics view is a fixed share of its window, and the panel hands
    /// its own lyrics column a larger one, so stepping by the panel's column
    /// would run a size (or two) hot. The expected values are what Music
    /// renders in a window of that width: 38 pt in the 1176 pt captured window,
    /// 28 pt in the 993 pt side-by-side screenshot, 50 pt full screen on a
    /// 1512 pt display.
    @Test(arguments: [
        (panelWidth: CGFloat(1176), lyricsColumnWidth: CGFloat(646.8), expectedFontSize: CGFloat(38)),
        (panelWidth: 993, lyricsColumnWidth: 546.1, expectedFontSize: 28),
        (panelWidth: 1512, lyricsColumnWidth: 831.6, expectedFontSize: 50),
        (panelWidth: 1728, lyricsColumnWidth: 950.4, expectedFontSize: 72),
        (panelWidth: 640, lyricsColumnWidth: 592, expectedFontSize: 24),
    ])
    func mainFontSizeMatchesMusicInAWindowOfTheSameWidth(
        panelWidth: CGFloat,
        lyricsColumnWidth: CGFloat,
        expectedFontSize: CGFloat
    ) {
        #expect(
            AppleMusicLyrics.NowPlayingLyricsLayoutPolicy.mainFontSize(
                forPanelWidth: panelWidth,
                lyricsColumnWidth: lyricsColumnWidth
            ) == expectedFontSize
        )
    }

    @Test func aColumnNarrowerThanMusicsShareGovernsTheFontItself() {
        #expect(
            AppleMusicLyrics.NowPlayingLyricsLayoutPolicy.mainFontSize(
                forPanelWidth: 1176,
                lyricsColumnWidth: 320
            ) == 28
        )
    }

    @Test func translationFontIsMusicsLargeTranslationScale() {
        let translationFontSize = AppleMusicLyrics.NowPlayingLyricsLayoutPolicy.translationFontSize(forMainFontSize: 38)
        #expect(abs(translationFontSize - 21.66) < 0.000_001)
    }

    @Test func musicsOwnLineSpacingIsTheConstantItLaysPrettyModeLinesWith() {
        #expect(AppleMusicLyrics.NowPlayingLyricsLayoutPolicy.musicConstantLineSpacing == 50)
    }

    /// The one value deliberately not copied: Music keeps 50 pt at every font
    /// step, so its own lines crowd as the window grows. The panel keeps the
    /// proportions a normal window has, which pins the 28 pt step to Music's
    /// 50 pt and opens the larger steps up.
    @Test(arguments: [
        (mainFontSize: CGFloat(28), expectedLineSpacing: CGFloat(50)),
        (mainFontSize: CGFloat(24), expectedLineSpacing: CGFloat(42.857_142_857_142_854)),
        (mainFontSize: CGFloat(38), expectedLineSpacing: CGFloat(67.857_142_857_142_854)),
        (mainFontSize: CGFloat(50), expectedLineSpacing: CGFloat(89.285_714_285_714_292)),
        (mainFontSize: CGFloat(72), expectedLineSpacing: CGFloat(128.571_428_571_428_58)),
    ])
    func lineSpacingKeepsTheSameProportionAtEveryFontStep(mainFontSize: CGFloat, expectedLineSpacing: CGFloat) {
        let lineSpacing = AppleMusicLyrics.NowPlayingLyricsLayoutPolicy.lineSpacing(forMainFontSize: mainFontSize)
        #expect(abs(lineSpacing - expectedLineSpacing) < 0.000_001)
        // The whole point of the rule: spacing over font size never changes.
        let proportion: CGFloat = 50 / 28
        #expect(abs(lineSpacing / mainFontSize - proportion) < 0.000_001)
    }

    @Test func followingFadesOverOneHundredTwentyEightPointsAndScrollingOverThirty() {
        #expect(AppleMusicLyrics.NowPlayingLyricsLayoutPolicy.edgeFadeDistance(isFollowing: true) == 128)
        #expect(AppleMusicLyrics.NowPlayingLyricsLayoutPolicy.edgeFadeDistance(isFollowing: false) == 30)
    }

    @Test func fadeLocationsMirrorMusicsMaskAtBothEdges() {
        let locations = AppleMusicLyrics.NowPlayingLyricsLayoutPolicy.edgeFadeLocations(
            viewportHeight: 800,
            fadeDistance: 128
        )
        #expect(locations.count == 4)
        #expect(locations[0] == 0)
        #expect(abs(locations[1] - 0.16) < 0.000_001)
        #expect(abs(locations[2] - 0.84) < 0.000_001)
        #expect(locations[3] == 1)
    }

    @Test(arguments: [CGFloat(200), 0])
    func fadesMeetInTheMiddleInsteadOfCrossingWhenTheViewportIsShort(viewportHeight: CGFloat) {
        let locations = AppleMusicLyrics.NowPlayingLyricsLayoutPolicy.edgeFadeLocations(
            viewportHeight: viewportHeight,
            fadeDistance: 128
        )
        #expect(locations == [0, 0.5, 0.5, 1])
    }

    @Test func contentCentreAnchorPutsTheLinesCentreOnTheAnchor() {
        // The capture: artwork centre 361.5 pt down, first line 40 pt tall.
        let topInset = AppleMusicLyrics.LineTransitionPlan.selectedLineTopInset(
            anchor: .contentCenter(y: 361.5),
            visibleHeight: 723,
            contentCenterOffset: 20,
            firstBaselineOffset: 55
        )
        #expect(abs(topInset - 341.5) < 0.000_001)
    }

    @Test func contentCentreAnchorNeverStartsTheDocumentAboveItsTop() {
        let topInset = AppleMusicLyrics.LineTransitionPlan.selectedLineTopInset(
            anchor: .contentCenter(y: 10),
            visibleHeight: 723,
            contentCenterOffset: 45,
            firstBaselineOffset: 55
        )
        #expect(topInset == 0)
    }

    @Test func baselineFractionAnchorKeepsTheLegacyFortyPercentRule() {
        let topInset = AppleMusicLyrics.LineTransitionPlan.selectedLineTopInset(
            anchor: .baselineViewportFraction(0.4),
            visibleHeight: 800,
            contentCenterOffset: 45,
            firstBaselineOffset: 60
        )
        #expect(abs(topInset - 260) < 0.000_001)
    }
}
