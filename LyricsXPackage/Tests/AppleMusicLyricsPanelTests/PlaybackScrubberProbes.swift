import AppKit
import AppKitPlus
import Testing
@testable import AppleMusicLyricsPanel

/// The panel's scrubber: AppKitPlus's `NSPlaybackSlider` over Music's elapsed
/// and remaining time labels.
///
/// Which view a click reaches is asserted on the window's hit test, not on a
/// delivered click. Built with the macOS 27 SDK, the slider tracks the mouse
/// through gesture recognizers that AppKit collects from the hit-test view up,
/// and whether a delivered click reproduces anything depends on the SDK the test
/// host links and on the window being key.
///
/// Scrubbing is driven the way AppKit's tracking drives the slider: through its
/// cell's three tracking methods, with the action AppKit sends on the press,
/// after every movement and once more after the release — the order
/// `NSPlaybackSlider` documents and AppKitPlus pins in its own tests.
@MainActor
struct PlaybackScrubberProbes {
    private nonisolated static let trackDuration: TimeInterval = 217.699

    // MARK: - Clicks

    /// A click on a time label used to scrub to the very start or the very end
    /// of the track, skipping to the previous or the next song: the labels sit
    /// under the ends of the bar, and AppKit handed the click on to the bar.
    /// Music's own time labels are inert.
    @Test func aClickOnATimeLabelDoesNotReachTheSlider() throws {
        let mounted = try Self.mountScrubber()

        for label in mounted.timeLabels {
            let receiver = mounted.receiverOfClick(at: NSPoint(x: label.bounds.midX, y: label.bounds.midY), in: label)
            let reachesTheScrubber = receiver?.isDescendant(of: mounted.scrubber) ?? false
            #expect(!reachesTheScrubber, "a click on \"\(label.stringValue)\" reaches \(receiver.map { "\(type(of: $0))" } ?? "nothing")")
        }
    }

    @Test func everyPointOnTheBarReachesTheSlider() throws {
        let mounted = try Self.mountScrubber()
        let slider = mounted.slider

        var missedPoints: [NSPoint] = []
        for x in stride(from: 0.5, to: slider.bounds.width, by: 1) {
            for y in [0.5, slider.bounds.midY, slider.bounds.height - 0.5] {
                let point = NSPoint(x: x, y: y)
                if mounted.receiverOfClick(at: point, in: slider)?.isDescendant(of: slider) != true {
                    missedPoints.append(point)
                }
            }
        }

        #expect(missedPoints.isEmpty, "\(missedPoints.count) points on the bar miss the slider, the first at \(missedPoints.first.map { "\($0)" } ?? "-")")
    }

    // MARK: - Seeking

    @Test func aClickSeeksOnceToWhereTheBarWasPressed() throws {
        let mounted = try Self.mountScrubber()

        mounted.press(atFraction: 0.5)
        mounted.release()

        #expect(mounted.recordedSeeks.count == 1, "seeks: \(mounted.recordedSeeks)")
        let seek = try #require(mounted.recordedSeeks.first)
        #expect(abs(seek - 108.85) < 0.01)
    }

    @Test func aDragSeeksOnlyWhereTheBarIsLetGo() throws {
        let mounted = try Self.mountScrubber()

        mounted.press(atFraction: 0.25)
        mounted.drag(toFraction: 0.5)
        mounted.drag(toFraction: 0.75)
        #expect(mounted.recordedSeeks.isEmpty, "sought while the bar was still pressed: \(mounted.recordedSeeks)")

        mounted.release()
        #expect(mounted.recordedSeeks.count == 1, "seeks: \(mounted.recordedSeeks)")
        let seek = try #require(mounted.recordedSeeks.first)
        #expect(abs(seek - 163.274) < 0.01)
    }

    @Test func aSecondClickOnTheSameSpotSeeksAgain() throws {
        let mounted = try Self.mountScrubber()

        mounted.press(atFraction: 0.5)
        mounted.release()
        mounted.press(atFraction: 0.5)
        mounted.release()

        #expect(mounted.recordedSeeks.count == 2, "seeks: \(mounted.recordedSeeks)")
    }

    @Test func theTimeLabelsFollowAPressedBar() throws {
        let mounted = try Self.mountScrubber()

        mounted.press(atFraction: 0.25)
        mounted.drag(toFraction: 0.75)

        #expect(mounted.elapsedLabel.stringValue == "2:43")
        #expect(mounted.remainingLabel.stringValue == "-0:54")
    }

    @Test func playbackDoesNotMoveAPressedBar() throws {
        let mounted = try Self.mountScrubber()

        mounted.press(atFraction: 0.75)
        mounted.scrubber.update(currentTime: 6.5, duration: Self.trackDuration)

        #expect(abs(mounted.slider.doubleValue - 163.274) < 0.01)
        #expect(mounted.elapsedLabel.stringValue == "2:43")
    }

    @Test func playbackMovesTheBarAgainAfterTheRelease() throws {
        let mounted = try Self.mountScrubber()

        mounted.press(atFraction: 0.75)
        mounted.release()
        mounted.scrubber.update(currentTime: 30, duration: Self.trackDuration)

        #expect(mounted.slider.doubleValue == 30)
        #expect(mounted.elapsedLabel.stringValue == "0:30")
    }

    /// VoiceOver's increment — like the arrow keys — moves the slider and sends
    /// its action without pressing the bar.
    @Test func movingTheSliderWithoutPressingItSeeksAtOnce() throws {
        let mounted = try Self.mountScrubber()

        // NSSlider returns false from this even though it has moved the value
        // and sent the action; the seek is what counts.
        _ = mounted.slider.accessibilityPerformIncrement()

        #expect(mounted.slider.doubleValue > 6, "the increment left the slider at \(mounted.slider.doubleValue)")
        #expect(mounted.recordedSeeks == [mounted.slider.doubleValue])
    }

    /// A player that reports no duration has nothing to seek into.
    @Test func aScrubberWithoutADurationDoesNotSeek() throws {
        let mounted = try Self.mountScrubber(duration: 0)

        mounted.press(atFraction: 0.5)
        mounted.release()

        #expect(mounted.recordedSeeks.isEmpty, "seeks: \(mounted.recordedSeeks)")
    }

    // MARK: - Fixture

    @MainActor
    private final class MountedScrubber {
        let window: NSWindow
        let scrubber: AppleMusicLyrics.PlaybackProgressView
        let slider: NSPlaybackSlider
        private let sliderCell: NSPlaybackSliderCell
        private(set) var recordedSeeks: [TimeInterval] = []
        private var lastTrackingPoint = NSPoint.zero

        init(window: NSWindow, scrubber: AppleMusicLyrics.PlaybackProgressView, slider: NSPlaybackSlider, sliderCell: NSPlaybackSliderCell) {
            self.window = window
            self.scrubber = scrubber
            self.slider = slider
            self.sliderCell = sliderCell
            scrubber.onSeek = { [weak self] time in self?.recordedSeeks.append(time) }
        }

        var timeLabels: [NSTextField] {
            scrubber.subviews.compactMap { $0 as? NSTextField }
        }

        var elapsedLabel: NSTextField {
            timeLabels.min { $0.frame.minX < $1.frame.minX }!
        }

        var remainingLabel: NSTextField {
            timeLabels.max { $0.frame.minX < $1.frame.minX }!
        }

        /// The view the window hands a click at `point`, given in `view`'s
        /// coordinates.
        func receiverOfClick(at point: NSPoint, in view: NSView) -> NSView? {
            window.contentView?.superview?.hitTest(view.convert(point, to: nil))
        }

        func press(atFraction fraction: CGFloat) {
            let point = trackingPoint(atFraction: fraction)
            _ = sliderCell.startTracking(at: point, in: slider)
            lastTrackingPoint = point
            sendSliderAction()
        }

        func drag(toFraction fraction: CGFloat) {
            let point = trackingPoint(atFraction: fraction)
            _ = sliderCell.continueTracking(last: lastTrackingPoint, current: point, in: slider)
            lastTrackingPoint = point
            sendSliderAction()
        }

        func release() {
            sliderCell.stopTracking(last: lastTrackingPoint, current: lastTrackingPoint, in: slider, mouseIsUp: true)
            sendSliderAction()
        }

        func sendSliderAction() {
            slider.sendAction(slider.action, to: slider.target)
        }

        private func trackingPoint(atFraction fraction: CGFloat) -> NSPoint {
            NSPoint(x: slider.bounds.width * fraction, y: slider.bounds.midY)
        }
    }

    private static func mountScrubber(duration: TimeInterval = trackDuration) throws -> MountedScrubber {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let contentView = try #require(window.contentView)
        let scrubber = AppleMusicLyrics.PlaybackProgressView()
        scrubber.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scrubber)
        // Placed as the panel places it: the column gives it a width, and what
        // is inside it gives it a height.
        NSLayoutConstraint.activate([
            scrubber.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            scrubber.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            scrubber.widthAnchor.constraint(equalToConstant: 300),
        ])
        scrubber.update(currentTime: 6, duration: duration)
        contentView.layoutSubtreeIfNeeded()

        let slider = try #require(scrubber.subviews.lazy.compactMap { $0 as? NSPlaybackSlider }.first, "the scrubber carries an NSPlaybackSlider")
        let sliderCell = try #require(slider.cell as? NSPlaybackSliderCell)
        let mounted = MountedScrubber(window: window, scrubber: scrubber, slider: slider, sliderCell: sliderCell)
        try #require(mounted.timeLabels.count == 2, "the scrubber carries an elapsed and a remaining label")
        try #require(slider.bounds.width == 300 && slider.bounds.height == 16, "slider laid out at \(slider.frame)")
        return mounted
    }
}
