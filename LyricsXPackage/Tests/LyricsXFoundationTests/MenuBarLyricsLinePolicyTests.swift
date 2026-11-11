import Testing
@testable import LyricsXFoundation

// The menu bar's lyric line used to change only when there was a line to show.
// A song without lyrics, and the start of every song before its first line,
// went on showing the last line of the song before; with "Hide lyrics when
// paused" on, pausing hid nothing.

private typealias Display = MenuBarLyricsLinePolicy.Display

@Test
func aSongWithoutLyricsShowsThePlaceholder() {
    // A track change clears the lyrics, so this is also what the start of the
    // next song shows until its lyrics and its first line arrive.
    let display = MenuBarLyricsLinePolicy.display(
        lineCount: nil,
        currentLineIndex: nil,
        isPlaying: true,
        hidesLyricsWhenPaused: false
    )

    #expect(display == .placeholder)
}

@Test
func pausingShowsThePlaceholderWhenLyricsHideWhilePaused() {
    let display = MenuBarLyricsLinePolicy.display(
        lineCount: 30,
        currentLineIndex: 12,
        isPlaying: false,
        hidesLyricsWhenPaused: true
    )

    #expect(display == .placeholder)
}

@Test
func pausingKeepsTheLineWhenLyricsStayWhilePaused() {
    let display = MenuBarLyricsLinePolicy.display(
        lineCount: 30,
        currentLineIndex: 12,
        isPlaying: false,
        hidesLyricsWhenPaused: false
    )

    #expect(display == .line(index: 12))
}

@Test
func playingShowsTheCurrentLine() {
    let display = MenuBarLyricsLinePolicy.display(
        lineCount: 30,
        currentLineIndex: 12,
        isPlaying: true,
        hidesLyricsWhenPaused: true
    )

    #expect(display == .line(index: 12))
}

@Test
func lyricsBeingReplacedKeepTheLineThatIsShowing() {
    // The app clears the line index before it replaces the lyrics on screen —
    // a translation arriving, another candidate picked — and sets it again
    // right after. The placeholder in between would flash, and the line would
    // start scrolling over.
    let display = MenuBarLyricsLinePolicy.display(
        lineCount: 30,
        currentLineIndex: nil,
        isPlaying: true,
        hidesLyricsWhenPaused: false
    )

    #expect(display == .unchanged)
}

@Test
func anIndexPastTheEndOfTheLyricsLeavesTheLineAlone() {
    let display = MenuBarLyricsLinePolicy.display(
        lineCount: 30,
        currentLineIndex: 30,
        isPlaying: true,
        hidesLyricsWhenPaused: false
    )

    #expect(display == .unchanged)
}
