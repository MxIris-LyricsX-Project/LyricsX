import Testing
import MusicPlayer
@testable import LyricsXFoundation

@Test
func lyricsWindowPreservesItsPositionForAZeroTimePauseTransition() {
    #expect(LyricsPlaybackPositionPolicy.shouldPreserveCurrentLine(
        previousState: .playing(time: 42),
        newState: .paused(time: 0)
    ))
    #expect(LyricsPlaybackPositionPolicy.shouldPreserveCurrentLine(
        previousState: .playing(time: 42),
        newState: .stopped
    ))

    #expect(!LyricsPlaybackPositionPolicy.shouldPreserveCurrentLine(
        previousState: .playing(time: 42),
        newState: .paused(time: 42)
    ))
    #expect(!LyricsPlaybackPositionPolicy.shouldPreserveCurrentLine(
        previousState: .paused(time: 42),
        newState: .paused(time: 0)
    ))
    #expect(!LyricsPlaybackPositionPolicy.shouldPreserveCurrentLine(
        previousState: nil,
        newState: .stopped
    ))
}
