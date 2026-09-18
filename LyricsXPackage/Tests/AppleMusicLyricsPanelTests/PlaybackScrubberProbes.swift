import AppKit
import Testing
@testable import AppleMusicLyricsPanel

/// Reproduction loop for "clicking a time label skips to the previous or next
/// track". The scrubber's two labels sit at the ends of the bar, and AppKit
/// hands a click on a non-selectable `NSTextField` to its next responder — the
/// scrubber — which read the click's x as a scrub to the very start or the
/// very end of the track. Music's own time labels are inert.
///
/// Each probe resolves the click the way `NSWindow` would: hit-test the
/// content view, then deliver `mouseDown` to whatever it found.
@MainActor
struct PlaybackScrubberProbes {
    private static let trackDuration: TimeInterval = 217.699
    private static let scrubberFrame = NSRect(x: 20, y: 20, width: 300, height: 24)

    @Test func clickingTheRemainingTimeLabelDoesNotSeek() throws {
        let mounted = try Self.mountScrubber()
        let label = try #require(mounted.timeLabels.max { $0.frame.minX < $1.frame.minX })

        mounted.click(at: label.frame.center, in: mounted.scrubber)

        #expect(mounted.recordedSeeks.isEmpty, "a click on the remaining-time label scrubbed to \(mounted.recordedSeeks)")
    }

    @Test func clickingTheElapsedTimeLabelDoesNotSeek() throws {
        let mounted = try Self.mountScrubber()
        let label = try #require(mounted.timeLabels.min { $0.frame.minX < $1.frame.minX })

        mounted.click(at: label.frame.center, in: mounted.scrubber)

        #expect(mounted.recordedSeeks.isEmpty, "a click on the elapsed-time label scrubbed to \(mounted.recordedSeeks)")
    }

    @Test func clickingTheMiddleOfTheBarSeeksToTheMiddleOfTheTrack() throws {
        let mounted = try Self.mountScrubber()
        let bar = try #require(mounted.bar)

        mounted.click(at: bar.frame.center, in: mounted.scrubber)

        let seek = try #require(mounted.recordedSeeks.first)
        #expect(abs(seek - Self.trackDuration / 2) < 1)
        #expect(mounted.recordedSeeks.count == 1)
    }

    // MARK: - Fixture

    private final class MountedScrubber {
        let window: NSWindow
        let scrubber: AppleMusicLyrics.PlaybackProgressView
        private(set) var recordedSeeks: [TimeInterval] = []

        init(window: NSWindow, scrubber: AppleMusicLyrics.PlaybackProgressView) {
            self.window = window
            self.scrubber = scrubber
            scrubber.onSeek = { [weak self] time in self?.recordedSeeks.append(time) }
        }

        var timeLabels: [NSTextField] {
            scrubber.subviews.compactMap { $0 as? NSTextField }
        }

        /// The bar is the one direct subview that is not a label.
        var bar: NSView? {
            scrubber.subviews.first { !($0 is NSTextField) }
        }

        /// Deliver a left click at `point` (in `view`'s coordinates) the way the
        /// window does: hit-test from the content view down, then send
        /// `mouseDown` to the view that claimed the point.
        func click(at point: NSPoint, in view: NSView) {
            let contentView = window.contentView!
            let pointInWindow = view.convert(point, to: nil)
            let pointInContentView = contentView.convert(pointInWindow, from: nil)
            let event = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: pointInWindow,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            )!
            contentView.hitTest(pointInContentView)?.mouseDown(with: event)
        }
    }

    private static func mountScrubber() throws -> MountedScrubber {
        let windowFrame = NSRect(x: 0, y: 0, width: 340, height: 80)
        let window = NSWindow(contentRect: windowFrame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let contentView = try #require(window.contentView)
        let scrubber = AppleMusicLyrics.PlaybackProgressView(frame: scrubberFrame)
        contentView.addSubview(scrubber)
        scrubber.update(currentTime: 6, duration: trackDuration)
        contentView.layoutSubtreeIfNeeded()
        let mounted = MountedScrubber(window: window, scrubber: scrubber)
        try #require(mounted.timeLabels.count == 2, "the scrubber carries an elapsed and a remaining label")
        try #require(mounted.bar != nil)
        return mounted
    }
}

extension NSRect {
    fileprivate var center: NSPoint {
        NSPoint(x: midX, y: midY)
    }
}
