import AppKit
import AppKitPlus
import UIFoundation

/// Pure-AppKit chrome controls for the lyrics panel (playback scrubber + buttons).
extension AppleMusicLyrics {
    /// An `NSImageView` with a fixed corner radius. Mirrors `UIFoundation.ImageView`:
    /// an image-bearing `NSImageView` does not take the `updateLayer` fast path,
    /// so the (unguarded) `cornerRadius` is re-applied in `layout()` — which runs
    /// after every geometry/full property sync — while `clipsToBounds` drives
    /// `masksToBounds` durably. This keeps the layer poking encapsulated here
    /// instead of leaking into the view controller's `viewDidLayout`.
    final class RoundedImageView: NSImageView {
        var cornerRadius: CGFloat = 0 {
            didSet {
                guard cornerRadius != oldValue else { return }
                needsLayout = true
            }
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            clipsToBounds = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layout() {
            super.layout()
            layer?.cornerRadius = cornerRadius
        }
    }

    /// Playback scrubber: AppKitPlus's `NSPlaybackSlider` — the time slider of
    /// Music's full-screen player — over elapsed / remaining labels. Press or drag
    /// the bar to scrub; the labels are inert.
    ///
    /// The seek happens once, on release. While the bar is pressed it follows the
    /// pointer, the labels show where it is, and playback updates leave it alone —
    /// the 10 Hz chrome tick would otherwise pull it back from under the pointer.
    /// The arrow keys and VoiceOver move the slider without pressing it, and seek
    /// at once.
    final class PlaybackProgressView: NSView, NSPlaybackSliderDelegate {
        var onSeek: ((TimeInterval) -> Void)?

        private let timeSlider = NSPlaybackSlider()
        private let elapsedLabel = NSTextField(labelWithString: "0:00")
        private let remainingLabel = NSTextField(labelWithString: "-0:00")

        private var duration: TimeInterval = 0
        /// The time the bar shows while it is not pressed: playback's, or where
        /// the last seek went until playback reports it.
        private var displayedTime: TimeInterval = 0
        private var isScrubbing = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            setup()
        }

        /// Only the slider takes clicks, and the hit test hands back the slider
        /// itself rather than this view: built with the macOS 27 SDK, a system
        /// control tracks the mouse through gesture recognizers, which AppKit
        /// collects from the window's hit-test view up — a hit on this view would
        /// leave the slider's out. The time labels sit under the ends of the bar
        /// and stay inert, as Music's are: a click on one falls through to the
        /// window-drag root view. (A click on a label used to reach the
        /// hand-drawn bar this slider replaced, which read its x as a scrub to
        /// the very start or the very end of the track — the previous or the
        /// next song.)
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let hitView = super.hitTest(point), hitView.isDescendant(of: timeSlider) else {
                return nil
            }
            return hitView
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        private func setup() {
            timeSlider.minValue = 0
            timeSlider.maxValue = 0
            timeSlider.scrubbingDelegate = self
            timeSlider.primaryAction = NSAction { [weak self] _ in
                self?.timeSliderValueDidChange()
            }
            timeSlider.translatesAutoresizingMaskIntoConstraints = false
            addSubview(timeSlider)

            for label in [elapsedLabel, remainingLabel] {
                label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
                label.textColor = NSColor.white.withAlphaComponent(0.6)
                label.isBezeled = false
                label.drawsBackground = false
                label.isEditable = false
                label.isSelectable = false
                label.translatesAutoresizingMaskIntoConstraints = false
                addSubview(label)
            }
            remainingLabel.alignment = .right

            // Music puts its time labels 6 points below the slider's 16-point row.
            let labelSpacing: CGFloat = 6
            NSLayoutConstraint.activate([
                timeSlider.leadingAnchor.constraint(equalTo: leadingAnchor),
                timeSlider.trailingAnchor.constraint(equalTo: trailingAnchor),
                timeSlider.topAnchor.constraint(equalTo: topAnchor),

                elapsedLabel.topAnchor.constraint(equalTo: timeSlider.bottomAnchor, constant: labelSpacing),
                elapsedLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
                elapsedLabel.bottomAnchor.constraint(equalTo: bottomAnchor),

                remainingLabel.topAnchor.constraint(equalTo: timeSlider.bottomAnchor, constant: labelSpacing),
                remainingLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }

        func update(currentTime: TimeInterval, duration: TimeInterval) {
            self.duration = duration
            if timeSlider.maxValue != duration {
                timeSlider.maxValue = duration
            }
            // A pressed bar follows the pointer, not playback.
            guard !isScrubbing else { return }
            displayedTime = currentTime
            timeSlider.doubleValue = currentTime
            showTime(currentTime)
        }

        // MARK: NSPlaybackSliderDelegate

        func playbackSliderDidBeginScrubbing(_ playbackSlider: NSPlaybackSlider) {
            isScrubbing = true
            showTime(playbackSlider.doubleValue)
        }

        func playbackSliderDidEndScrubbing(_ playbackSlider: NSPlaybackSlider) {
            isScrubbing = false
            seek(to: playbackSlider.doubleValue)
        }

        /// Sent on the press, after every movement of a drag, once more after the
        /// release, and for each arrow key or VoiceOver adjustment.
        private func timeSliderValueDidChange() {
            let time = timeSlider.doubleValue
            if isScrubbing {
                showTime(time)
            } else if time != displayedTime {
                // The arrow keys and VoiceOver. The action that follows a release
                // carries the time `playbackSliderDidEndScrubbing(_:)` has just
                // sought to, and stops at the comparison above.
                seek(to: time)
            }
        }

        private func seek(to time: TimeInterval) {
            displayedTime = time
            showTime(time)
            guard duration > 0 else { return }
            onSeek?(time)
        }

        private func showTime(_ time: TimeInterval) {
            elapsedLabel.stringValue = Self.formatTime(time)
            remainingLabel.stringValue = "-" + Self.formatTime(max(0, duration - time))
        }

        static func formatTime(_ time: TimeInterval) -> String {
            let totalSeconds = Int(max(0, time))
            return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
        }
    }

    /// Borderless SF Symbol control with a subtle hover background, for the
    /// transport controls. The hover highlight is a rounded-square fill in a
    /// dedicated child `LayerBackedView` behind the glyph, faded in/out by
    /// animating its `alphaValue` (the AppKit-blessed way to animate a layer-backed
    /// view). The glyph lives in another child `NSImageView` and clicks are handled
    /// on `mouseUp` — mirroring `InteractionToggleButton`.
    final class PanelControlButton: LayerBackedView {
        var onClick: (() -> Void)?

        private let pointSize: CGFloat
        private let iconView = NSImageView()
        private let hoverBackground = LayerBackedView()
        /// The hit area / hover square extends this far beyond the glyph on every
        /// side, so the rounded background reads as a frame around the icon instead
        /// of being clipped flush to the glyph (which made the hover invisible).
        /// The glyph itself stays at its natural size, centred.
        private let hoverPadding: CGFloat = 10
        // Rounded-square (NOT circular) hover fill.
        private let hoverCornerRadius: CGFloat = 8
        private let hoverFadeDuration: TimeInterval = 0.16
        private var isHovering = false {
            didSet {
                guard isHovering != oldValue else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = hoverFadeDuration
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    hoverBackground.animator().alphaValue = isHovering ? 1 : 0
                }
            }
        }

        init(symbolName: String, pointSize: CGFloat, onClick: @escaping () -> Void) {
            self.pointSize = pointSize
            super.init(frame: .zero)
            self.onClick = onClick
            translatesAutoresizingMaskIntoConstraints = false

            // Rounded-square hover fill behind the glyph, hidden until hovered.
            hoverBackground.translatesAutoresizingMaskIntoConstraints = false
            hoverBackground.backgroundColor = NSColor.white.withAlphaComponent(0.15)
            hoverBackground.cornerRadius = hoverCornerRadius
            hoverBackground.clipsToBounds = true
            hoverBackground.alphaValue = 0
            addSubview(hoverBackground)

            iconView.contentTintColor = .white
            iconView.imageScaling = .scaleProportionallyDown
            iconView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(iconView)

            NSLayoutConstraint.activate([
                hoverBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
                hoverBackground.trailingAnchor.constraint(equalTo: trailingAnchor),
                hoverBackground.topAnchor.constraint(equalTo: topAnchor),
                hoverBackground.bottomAnchor.constraint(equalTo: bottomAnchor),
                iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
                iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            setSymbol(symbolName)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func setSymbol(_ symbolName: String) {
            let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            invalidateIntrinsicContentSize()
        }

        override var intrinsicContentSize: NSSize {
            // A square sized to the larger glyph dimension plus padding, so the
            // rounded-square hover fill frames the icon with even margin.
            let glyphSize = iconView.image?.size ?? NSSize(width: pointSize, height: pointSize)
            let side = max(glyphSize.width, glyphSize.height) + hoverPadding * 2
            return NSSize(width: side, height: side)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self
            ))
        }

        override func mouseEntered(with event: NSEvent) {
            isHovering = true
        }

        override func mouseExited(with event: NSEvent) {
            isHovering = false
        }

        override func mouseDown(with event: NSEvent) {
            // accept; act on mouseUp inside bounds
        }

        override func mouseUp(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            if bounds.contains(point) {
                onClick?()
            }
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }
}
