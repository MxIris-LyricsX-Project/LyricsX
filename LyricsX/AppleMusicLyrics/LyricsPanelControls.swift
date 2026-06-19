import AppKit
import UIFoundation

// Pure-AppKit chrome controls for the lyrics panel (playback scrubber + buttons).

@available(macOS 15, *)
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

    /// Playback scrubber: a thin track + fill with elapsed / remaining labels,
    /// drag anywhere on it to seek.
    final class PlaybackProgressView: NSView {
        var onSeek: ((TimeInterval) -> Void)?

        private var duration: TimeInterval = 0
        private var currentTime: TimeInterval = 0

        private let track = LayerBackedView()
        private let fill = LayerBackedView()
        private let elapsedLabel = NSTextField(labelWithString: "0:00")
        private let remainingLabel = NSTextField(labelWithString: "-0:00")
        private var fillWidthConstraint: NSLayoutConstraint!

        private let barHeight: CGFloat = 4

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            setup()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        private func setup() {
            for bar in [track, fill] {
                bar.translatesAutoresizingMaskIntoConstraints = false
                // Renderer-driven: `cornerRadius` / `backgroundColor` are applied
                // in `LayerBackedView.updateLayer()`, the only sync-safe window.
                bar.cornerRadius = barHeight / 2
                bar.clipsToBounds = true
            }
            track.backgroundColor = NSColor.white.withAlphaComponent(0.3)
            fill.backgroundColor = .white
            addSubview(track)
            track.addSubview(fill)

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

            fillWidthConstraint = fill.widthAnchor.constraint(equalToConstant: 0)
            NSLayoutConstraint.activate([
                track.leadingAnchor.constraint(equalTo: leadingAnchor),
                track.trailingAnchor.constraint(equalTo: trailingAnchor),
                track.topAnchor.constraint(equalTo: topAnchor),
                track.heightAnchor.constraint(equalToConstant: barHeight),

                fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
                fill.topAnchor.constraint(equalTo: track.topAnchor),
                fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
                fillWidthConstraint,

                elapsedLabel.topAnchor.constraint(equalTo: track.bottomAnchor, constant: 4),
                elapsedLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
                elapsedLabel.bottomAnchor.constraint(equalTo: bottomAnchor),

                remainingLabel.topAnchor.constraint(equalTo: track.bottomAnchor, constant: 4),
                remainingLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }

        func update(currentTime: TimeInterval, duration: TimeInterval) {
            self.currentTime = currentTime
            self.duration = duration
            applyFill()
            elapsedLabel.stringValue = Self.formatTime(currentTime)
            remainingLabel.stringValue = "-" + Self.formatTime(max(0, duration - currentTime))
        }

        override func layout() {
            super.layout()
            applyFill()
        }

        private func applyFill() {
            let progress = duration > 0 ? min(1, max(0, currentTime / duration)) : 0
            fillWidthConstraint.constant = track.bounds.width * progress
        }

        override func mouseDown(with event: NSEvent) {
            seek(with: event)
        }

        override func mouseDragged(with event: NSEvent) {
            seek(with: event)
        }

        private func seek(with event: NSEvent) {
            guard duration > 0, track.bounds.width > 0 else { return }
            let x = track.convert(event.locationInWindow, from: nil).x
            let fraction = max(0, min(1, x / track.bounds.width))
            onSeek?(fraction * duration)
        }

        static func formatTime(_ time: TimeInterval) -> String {
            let totalSeconds = Int(max(0, time))
            return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
        }
    }

    /// Borderless SF Symbol control with a subtle hover background, for the
    /// transport controls. Built on `LayerBackedView` so the hover fill and
    /// corner radius flow through the renderer's `updateLayer` (never poked onto
    /// the layer against AppKit's sync); the glyph lives in a child `NSImageView`
    /// and clicks are handled on `mouseUp` — mirroring `InteractionToggleButton`.
    final class PanelControlButton: LayerBackedView {
        var onClick: (() -> Void)?

        private let pointSize: CGFloat
        private let iconView = NSImageView()
        // The hit area / hover pill extends this far beyond the glyph on every
        // side, so the rounded hover background reads as a circle around the
        // icon instead of being clipped flush to the glyph (which made the hover
        // invisible). The glyph itself stays at its natural size, centred.
        private let hoverPadding: CGFloat = 10
        private var isHovering = false {
            didSet {
                guard isHovering != oldValue else { return }
                backgroundColor = NSColor.white.withAlphaComponent(isHovering ? 0.15 : 0)
            }
        }

        init(symbolName: String, pointSize: CGFloat, onClick: @escaping () -> Void) {
            self.pointSize = pointSize
            super.init(frame: .zero)
            self.onClick = onClick
            translatesAutoresizingMaskIntoConstraints = false
            iconView.contentTintColor = .white
            iconView.imageScaling = .scaleProportionallyDown
            iconView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(iconView)
            NSLayoutConstraint.activate([
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
            // A square sized to the larger glyph dimension plus padding, so every
            // transport button is a circular tap/hover target around its icon.
            let glyphSize = iconView.image?.size ?? NSSize(width: pointSize, height: pointSize)
            let side = max(glyphSize.width, glyphSize.height) + hoverPadding * 2
            return NSSize(width: side, height: side)
        }

        override func layout() {
            super.layout()
            // Pill-shaped hover fill; `cornerRadius` flows through the renderer.
            cornerRadius = bounds.height / 2
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
