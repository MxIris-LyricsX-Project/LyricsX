import CoreGraphics
import Foundation

extension AppleMusicLyrics {
    /// Where the selected line settles inside the viewport.
    enum SelectedLineAnchor: Equatable {
        /// The first main-text baseline sits at this fraction of the visible
        /// height — the project's original calibration, kept for the narrow
        /// layout that has no cover to align with.
        case baselineViewportFraction(CGFloat)
        /// The line's whole content block (main text plus translation) is
        /// centred on this y, measured down from the viewport's top edge. This
        /// is Music's `.center(rect:)`, whose rect Music builds from its
        /// `activeBaseline` anchor.
        case contentCenter(y: CGFloat)
    }

    /// Music 26.6's Now Playing (`prettyMode`) lyrics sizing and placement, read
    /// out of `Music.i64` on 2026-09-13.
    ///
    /// `Music.LyricsXViewController` recomputes its `LyricsSpecs` from
    /// `viewWillLayout` (`sub_100125ABC` → `sub_100128AD8`): the main font size
    /// is stepped by the lyrics view's own width, every other font is a multiple
    /// of it (`sub_100128D3C`), and the per-mode closure `sub_1001D0A1C` fixes
    /// the line spacing. The same layout pass rebuilds the outer gradient mask
    /// (`sub_1001284F8`).
    enum NowPlayingLyricsLayoutPolicy {
        /// `sub_100128AD8`: below the first threshold — or outside pretty mode —
        /// Music uses 24 pt.
        static let narrowMainFontSize: CGFloat = 24
        /// The width thresholds and the font size each one unlocks, in the order
        /// `sub_100128AD8` tests them.
        static let mainFontSizeSteps: [(minimumLyricsWidth: CGFloat, fontSize: CGFloat)] = [
            (300, 28),
            (528, 38),
            (672, 50),
            (760, 72),
        ]
        /// `sub_100128D3C` derives `translationLargeFont` as the main size × 0.57
        /// (`translationSmallFont` is × 0.46, background vocals × 0.63).
        static let translationFontScale: CGFloat = 0.57
        /// `LyricsSpecs.lineSpacing` in pretty mode (`sub_1001D0A1C`; the sidebar
        /// uses 36). `sub_1001E0C34` lays the next line at `previous.maxY +
        /// lineSpacing`, so it is the gap between two lines' text blocks.
        ///
        /// Music holds this at 50 for every font step, which is the one value in
        /// here the panel deliberately does not copy — see
        /// ``lineSpacing(forMainFontSize:)``.
        static let musicConstantLineSpacing: CGFloat = 50
        /// The font step at which the panel's spacing equals Music's 50 pt. It is
        /// the size a normal, non-full-screen window lands on.
        static let lineSpacingReferenceFontSize: CGFloat = 28

        /// The gap between two lines' text blocks.
        ///
        /// Because Music's spacing is a constant while its font steps up to
        /// 72 pt, its own lines crowd together as the window grows — JH checked
        /// Music at full screen and judged it too tight to copy. So the spacing
        /// rides the font here instead, keeping the proportions of a normal-sized
        /// window at every step: at the 28 pt step it is exactly Music's 50 pt,
        /// and at the 72 pt full-screen step it opens up to about 129 pt.
        static func lineSpacing(forMainFontSize mainFontSize: CGFloat) -> CGFloat {
            musicConstantLineSpacing * max(0, mainFontSize) / lineSpacingReferenceFontSize
        }

        /// `sub_1001284F8`: while the lyrics follow playback, both the top and
        /// the bottom of the container fade over this many points.
        static let followingEdgeFadeDistance: CGFloat = 128
        /// The same function narrows both fades to this while the user is
        /// scrolling through the lyrics themselves.
        static let scrollingEdgeFadeDistance: CGFloat = 30

        /// The share of the window Music's Now Playing layout hands to the view
        /// whose width drives the steps above.
        ///
        /// The 2026-09-05 hierarchy capture (`Music.viewhierarchy`) has a
        /// 1176 × 811 window whose `Music.LyricsXViewController` view — the one
        /// `sub_100128AD8` measures — is 533.5 pt wide, sitting at x = 556 with
        /// the 329 pt artwork centred in the left half and 86.5 pt of trailing
        /// margin. The panel's own columns are proportional too but give the
        /// lyrics a larger share (~55 %), so stepping the font by the panel's
        /// column would show a size, or two, above what Music shows in a window
        /// of the same width.
        ///
        /// A second sample measured off a side-by-side screenshot of both
        /// windows at 993 pt agrees to within about 4 %: Music renders 28 pt
        /// there, which this fraction reproduces.
        static let lyricsViewPanelWidthFraction: CGFloat = 533.5 / 1176

        /// The width the font steps run on: the narrower of the panel's own
        /// lyrics column and the column Music would carve out of a window this
        /// wide. Taking the narrower one keeps the text inside a column that is
        /// tighter than Music's (a very tall, narrow window) from overflowing.
        static func steppedFontReferenceWidth(panelWidth: CGFloat, lyricsColumnWidth: CGFloat) -> CGFloat {
            min(lyricsColumnWidth, max(0, panelWidth) * lyricsViewPanelWidthFraction)
        }

        static func mainFontSize(forPanelWidth panelWidth: CGFloat, lyricsColumnWidth: CGFloat) -> CGFloat {
            mainFontSize(
                forLyricsWidth: steppedFontReferenceWidth(
                    panelWidth: panelWidth,
                    lyricsColumnWidth: lyricsColumnWidth
                )
            )
        }

        static func mainFontSize(forLyricsWidth lyricsWidth: CGFloat) -> CGFloat {
            var fontSize = narrowMainFontSize
            for step in mainFontSizeSteps where lyricsWidth >= step.minimumLyricsWidth {
                fontSize = step.fontSize
            }
            return fontSize
        }

        static func translationFontSize(forMainFontSize mainFontSize: CGFloat) -> CGFloat {
            mainFontSize * translationFontScale
        }

        static func edgeFadeDistance(isFollowing: Bool) -> CGFloat {
            isFollowing ? followingEdgeFadeDistance : scrollingEdgeFadeDistance
        }

        /// Music's mask locations `[0, d / H, 1 - d / H, 1]`, expressed for a
        /// gradient that runs from the top of the container to the bottom. A
        /// container shorter than two fades meets in the middle instead of
        /// crossing over.
        static func edgeFadeLocations(viewportHeight: CGFloat, fadeDistance: CGFloat) -> [CGFloat] {
            guard viewportHeight > 0 else { return [0, 0.5, 0.5, 1] }
            let fadeFraction = min(max(fadeDistance / viewportHeight, 0), 0.5)
            return [0, fadeFraction, 1 - fadeFraction, 1]
        }
    }
}
