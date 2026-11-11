import Foundation

extension AppleMusicLyrics {
    /// Decides when the panel's periodic drivers — the karaoke display link and
    /// the 10 Hz chrome timer — have to tick (issue #191).
    ///
    /// The display link used to start as soon as the lyrics view joined a window
    /// and stop only when it left, so it ran at the display's full rate (120 Hz
    /// on ProMotion) for as long as the panel was open: paused, without lyrics,
    /// occluded, minimized or on another Space. Every tick resolves the playback
    /// time and walks the highlighted line's sweep, word schedule and syllable
    /// lifts, so an idle panel cost as much as a playing one.
    ///
    /// Only playback moves anything the link drives. Everything a tick starts —
    /// word swells, syllable lifts, the clip and row springs — is a Core
    /// Animation animation or a dispatched work item that finishes on its own,
    /// so stopping the link never cuts an animation short. While playback
    /// plays, the link keeps the display's full rate: a lower cap was tried and
    /// rejected as visibly choppy.
    enum LyricsDisplayLinkPolicy {
        enum Activity: Equatable {
            /// The lyrics move with playback: tick on every display frame.
            case running
            /// Nothing moves on its own, but the screen has to show the latest
            /// state once — the position a pause landed on, a seek or a line
            /// change while paused, lyrics that just arrived. One tick, then idle.
            case renderingSingleFrame
            /// Nothing the link draws is on screen.
            case idle
        }

        static func activity(
            isPlaying: Bool,
            hasLyrics: Bool,
            isAttachedToWindow: Bool,
            isWindowVisible: Bool,
            isWindowMiniaturized: Bool,
            isWindowOccluded: Bool
        ) -> Activity {
            guard hasLyrics,
                  isOnScreen(
                      isAttachedToWindow: isAttachedToWindow,
                      isWindowVisible: isWindowVisible,
                      isWindowMiniaturized: isWindowMiniaturized,
                      isWindowOccluded: isWindowOccluded
                  )
            else {
                return .idle
            }
            return isPlaying ? .running : .renderingSingleFrame
        }

        /// The panel's chrome — the scrubber, its time labels and the play /
        /// pause symbol — follows the same rule, with one difference: while a
        /// track still has no cover the timer keeps polling for one, because a
        /// player can publish its artwork after the track change it belongs to.
        static func chromeActivity(
            isPlaying: Bool,
            isAwaitingArtwork: Bool,
            isAttachedToWindow: Bool,
            isWindowVisible: Bool,
            isWindowMiniaturized: Bool,
            isWindowOccluded: Bool
        ) -> Activity {
            guard isOnScreen(
                isAttachedToWindow: isAttachedToWindow,
                isWindowVisible: isWindowVisible,
                isWindowMiniaturized: isWindowMiniaturized,
                isWindowOccluded: isWindowOccluded
            ) else {
                return .idle
            }
            return isPlaying || isAwaitingArtwork ? .running : .renderingSingleFrame
        }

        /// A window on another Space or entirely covered reports itself visible
        /// but drops `.visible` from its occlusion state; a minimized one keeps
        /// neither.
        private static func isOnScreen(
            isAttachedToWindow: Bool,
            isWindowVisible: Bool,
            isWindowMiniaturized: Bool,
            isWindowOccluded: Bool
        ) -> Bool {
            isAttachedToWindow && isWindowVisible && !isWindowMiniaturized && !isWindowOccluded
        }
    }
}
