import MusicPlayer

public enum LyricsPlaybackPositionPolicy {
    /// Some now-playing sources briefly report a zero-time non-playing state
    /// when playback is paused. Preserve the current lyric for that transition;
    /// later paused-state seeks must still be allowed to update the position.
    public static func shouldPreserveCurrentLine(
        previousState: PlaybackState?,
        newState: PlaybackState
    ) -> Bool {
        previousState?.isPlaying == true &&
            !newState.isPlaying &&
            newState.time <= 0
    }
}
