import AppKit

// Pure-AppKit chrome controls for the lyrics panel (playback scrubber + buttons).

@available(macOS 15, *)
extension AppleMusicLyrics {
    /// Playback scrubber: a thin track + fill with elapsed / remaining labels,
    /// drag anywhere on it to seek.
    final class PlaybackProgressView: NSView {
        var onSeek: ((TimeInterval) -> Void)?

        private var duration: TimeInterval = 0
        private var currentTime: TimeInterval = 0

        private let track = NSView()
        private let fill = NSView()
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
            for view in [track, fill] {
                view.wantsLayer = true
                view.translatesAutoresizingMaskIntoConstraints = false
                view.layer?.cornerRadius = barHeight / 2
            }
            track.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.3).cgColor
            fill.layer?.backgroundColor = NSColor.white.cgColor
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
            // `cornerRadius` is unguarded against the view→layer sync, so keep it
            // applied to the track/fill on every layout pass.
            track.layer?.cornerRadius = barHeight / 2
            fill.layer?.cornerRadius = barHeight / 2
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

    /// Borderless SF Symbol button with a subtle hover background, for the
    /// transport controls.
    final class PanelControlButton: NSButton {
        var onClick: (() -> Void)?
        private var pointSize: CGFloat
        private var isHovering = false {
            didSet { updateHoverAppearance() }
        }

        init(symbolName: String, pointSize: CGFloat, onClick: @escaping () -> Void) {
            self.pointSize = pointSize
            super.init(frame: .zero)
            self.onClick = onClick
            isBordered = false
            bezelStyle = .regularSquare
            imagePosition = .imageOnly
            contentTintColor = .white
            wantsLayer = true
            translatesAutoresizingMaskIntoConstraints = false
            setSymbol(symbolName)
            target = self
            action = #selector(handleClick)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func setSymbol(_ symbolName: String) {
            let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
        }

        @objc private func handleClick() {
            onClick?()
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

        private func updateHoverAppearance() {
            layer?.cornerRadius = bounds.height / 2
            layer?.backgroundColor = NSColor.white.withAlphaComponent(isHovering ? 0.15 : 0).cgColor
        }

        override func layout() {
            super.layout()
            updateHoverAppearance()
        }
    }
}
