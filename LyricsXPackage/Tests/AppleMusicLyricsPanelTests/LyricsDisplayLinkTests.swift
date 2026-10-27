import AppKit
import Combine
import LyricsXFoundation
import Testing
@testable import AppleMusicLyricsPanel

/// The panel's periodic drivers only tick while something on screen can change
/// (issue #191): a 120 Hz display link behind a paused, empty, occluded or
/// minimized panel doubled a MacBook Pro's package power.
struct LyricsDisplayLinkPolicyTests {
    private typealias Policy = AppleMusicLyrics.LyricsDisplayLinkPolicy

    @Test func playingLyricsInAVisibleWindowTickEveryFrame() {
        #expect(
            Policy.activity(
                isPlaying: true,
                hasLyrics: true,
                isAttachedToWindow: true,
                isWindowVisible: true,
                isWindowMiniaturized: false,
                isWindowOccluded: false
            ) == .running
        )
    }

    /// A pause, a seek while paused and a line change while paused all leave
    /// the screen one frame behind and nothing moving after it.
    @Test func pausedOrStoppedLyricsRenderOneFrameAndThenStop() {
        #expect(
            Policy.activity(
                isPlaying: false,
                hasLyrics: true,
                isAttachedToWindow: true,
                isWindowVisible: true,
                isWindowMiniaturized: false,
                isWindowOccluded: false
            ) == .renderingSingleFrame
        )
    }

    /// Without lyrics, or with the panel off screen, there is nothing to draw
    /// even while the player plays.
    @Test(arguments: [
        (false, true, true, false, false),
        (true, false, true, false, false),
        (true, true, false, false, false),
        (true, true, true, true, false),
        (true, true, true, false, true),
    ])
    func noLyricsOrNoVisibleWindowLeavesTheLinkIdle(
        hasLyrics: Bool,
        isAttachedToWindow: Bool,
        isWindowVisible: Bool,
        isWindowMiniaturized: Bool,
        isWindowOccluded: Bool
    ) {
        for isPlaying in [true, false] {
            #expect(
                Policy.activity(
                    isPlaying: isPlaying,
                    hasLyrics: hasLyrics,
                    isAttachedToWindow: isAttachedToWindow,
                    isWindowVisible: isWindowVisible,
                    isWindowMiniaturized: isWindowMiniaturized,
                    isWindowOccluded: isWindowOccluded
                ) == .idle
            )
        }
    }

    /// The scrubber and the play / pause symbol tick with playback, and keep
    /// polling while the track's cover has not arrived yet.
    @Test(arguments: [
        (true, false, AppleMusicLyrics.LyricsDisplayLinkPolicy.Activity.running),
        (false, true, .running),
        (false, false, .renderingSingleFrame),
    ])
    func chromeTicksWithPlaybackOrWhileItAwaitsArtwork(
        isPlaying: Bool,
        isAwaitingArtwork: Bool,
        expectedActivity: AppleMusicLyrics.LyricsDisplayLinkPolicy.Activity
    ) {
        #expect(
            Policy.chromeActivity(
                isPlaying: isPlaying,
                isAwaitingArtwork: isAwaitingArtwork,
                isAttachedToWindow: true,
                isWindowVisible: true,
                isWindowMiniaturized: false,
                isWindowOccluded: false
            ) == expectedActivity
        )
    }

    @Test(arguments: [
        (false, true, false, false),
        (true, false, false, false),
        (true, true, true, false),
        (true, true, false, true),
    ])
    func chromeStopsWhileThePanelIsOffScreen(
        isAttachedToWindow: Bool,
        isWindowVisible: Bool,
        isWindowMiniaturized: Bool,
        isWindowOccluded: Bool
    ) {
        #expect(
            Policy.chromeActivity(
                isPlaying: true,
                isAwaitingArtwork: true,
                isAttachedToWindow: isAttachedToWindow,
                isWindowVisible: isWindowVisible,
                isWindowMiniaturized: isWindowMiniaturized,
                isWindowOccluded: isWindowOccluded
            ) == .idle
        )
    }
}

/// When the lyrics go away — a track change, a search that found nothing — the
/// panel fades the lyrics column out rather than hiding it, so the window keeps
/// its size. The previous song's rows used to stay behind that fade, the old
/// highlighted line still sweeping and swelling against the new song's clock.
@Suite(.serialized)
@MainActor
struct PanelLyricsRemovalProbes {
    private static func makeLyrics() throws -> Lyrics {
        let body = (0 ..< 8)
            .map { lineIndex in String(format: "[00:%05.2f]removal probe line %d", Double(lineIndex) * 4, lineIndex) }
            .joined(separator: "\n")
        return try #require(Lyrics(body))
    }

    private static func descendantViews<ViewType: NSView>(of root: NSView, as type: ViewType.Type) -> [ViewType] {
        var found: [ViewType] = []
        func walk(_ view: NSView) {
            if let match = view as? ViewType {
                found.append(match)
            }
            for subview in view.subviews {
                walk(subview)
            }
        }
        walk(root)
        return found
    }

    @Test func clearingTheLyricsRetiresThePreviousSongsLines() async throws {
        let lyrics = try Self.makeLyrics()
        let lyricsSubject = CurrentValueSubject<Lyrics?, Never>(nil)
        let lineIndexSubject = CurrentValueSubject<Int?, Never>(nil)
        let panelViewController = AppleMusicLyrics.LyricsPanelViewController(
            lyricsPublisher: lyricsSubject.eraseToAnyPublisher(),
            currentLineIndexPublisher: lineIndexSubject.eraseToAnyPublisher()
        )
        // Never ordered in: AppKit loads and lays out the hierarchy without
        // putting anything on screen.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = panelViewController
        panelViewController.view.layoutSubtreeIfNeeded()

        lyricsSubject.send(lyrics)
        lineIndexSubject.send(3)
        try await Task.sleep(seconds: 0.3)
        let rowsBeforeRemoval = Self.descendantViews(
            of: panelViewController.view,
            as: AppleMusicLyrics.SyncedLyricsLineView.self
        )
        #expect(rowsBeforeRemoval.filter(\.isHighlighted).map(\.originalIndex) == [3])

        lyricsSubject.send(nil)
        try await Task.sleep(seconds: 0.3)

        let container = try #require(
            Self.descendantViews(
                of: panelViewController.view,
                as: AppleMusicLyrics.SyncedLyricsContainerView.self
            ).first
        )
        // Still a faded arranged subview, never hidden: hiding it changes the
        // stack's fitting size and snaps the window back to it.
        #expect(!container.isHidden)
        #expect(container.alphaValue == 0)
        let rowsAfterRemoval = Self.descendantViews(
            of: panelViewController.view,
            as: AppleMusicLyrics.SyncedLyricsLineView.self
        )
        #expect(rowsAfterRemoval.isEmpty, "\(rowsAfterRemoval.count) rows of the previous song are still in the panel")
        #expect(rowsBeforeRemoval.allSatisfy { !$0.isHighlighted }, "the previous song's line is still the active one")

        // The same lyrics coming back — a re-search that lands on the same
        // file — rebuild the rows rather than finding nothing to change.
        lyricsSubject.send(lyrics)
        try await Task.sleep(seconds: 0.3)
        let rowsAfterReturn = Self.descendantViews(
            of: panelViewController.view,
            as: AppleMusicLyrics.SyncedLyricsLineView.self
        )
        #expect(rowsAfterReturn.count == 8)
        #expect(rowsAfterReturn.filter(\.isHighlighted).map(\.originalIndex) == [3])
        #expect(container.alphaValue == 1)
    }
}
