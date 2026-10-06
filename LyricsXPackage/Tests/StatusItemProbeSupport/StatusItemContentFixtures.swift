import AppKit
import LyricsXFoundation

/// The menu bar lyrics item's geometry, copied from `MenuBarLyricsController`.
package enum MenuBarLyricsGeometry {
    package static let lyricsWidth: CGFloat = 183
    package static let lyricsHeight: CGFloat = 24
    package static let lyricsToControlsGap: CGFloat = 6
    package static let controlButtonSize: CGFloat = 24
    package static let controlSpacing: CGFloat = 4
}

package final class TalliedTextField: NSTextField {
    package var drawTally: DrawTally?

    package override func draw(_ dirtyRect: NSRect) {
        drawTally?.recordDraw(source: "textField")
        super.draw(dirtyRect)
    }

    /// `animator().frame` moves the field through here, frame by frame.
    package override func setFrameOrigin(_ newOrigin: NSPoint) {
        if newOrigin.x != frame.origin.x {
            drawTally?.recordPosition(newOrigin.x)
        }
        super.setFrameOrigin(newOrigin)
    }
}

package final class TalliedButton: NSButton {
    package var drawTally: DrawTally?

    package override func draw(_ dirtyRect: NSRect) {
        drawTally?.recordDraw(source: "button")
        super.draw(dirtyRect)
    }
}

package final class TalliedImageView: NSImageView {
    package var drawTally: DrawTally?

    package override func draw(_ dirtyRect: NSRect) {
        drawTally?.recordDraw(source: "imageView")
        super.draw(dirtyRect)
    }
}

/// The text field inside `MLMarqueeLabel` (MarqueeLabel 0.1.0), configured
/// property by property the way `-initWithFrame:` does, so the probes compare
/// against exactly what the app ships before macOS 26.
@MainActor
package func makeMarqueeStyledTextField(drawTally: DrawTally?) -> TalliedTextField {
    let textField = TalliedTextField(frame: .zero)
    textField.isBordered = false
    textField.isEditable = false
    textField.isSelectable = false
    textField.alignment = .left
    textField.cell?.lineBreakMode = .byTruncatingTail
    textField.font = .systemFont(ofSize: 14)
    textField.backgroundColor = .clear
    textField.textColor = .labelColor
    textField.drawTally = drawTally
    return textField
}

/// How wide MarqueeLabel's field is for `text` once sized to fit.
@MainActor
package func marqueeFieldWidth(of text: String) -> CGFloat {
    let textField = makeMarqueeStyledTextField(drawTally: nil)
    textField.stringValue = text
    textField.sizeToFit()
    return textField.frame.width
}

/// Where `-layoutTextField` puts the field inside the marquee box: centred
/// vertically (rounded up), centred horizontally when it fits, otherwise
/// at the scroll position the marquee animation has reached.
package func marqueeTextFieldFrame(fieldSize: NSSize, in boxBounds: NSRect, scrollPosition: CGFloat = 0) -> NSRect {
    let originY = ((boxBounds.height - fieldSize.height) * 0.5).rounded(.up)
    let originX = fieldSize.width <= boxBounds.width
        ? ((boxBounds.width - fieldSize.width) * 0.5).rounded()
        : scrollPosition
    return NSRect(x: originX, y: originY, width: fieldSize.width, height: fieldSize.height)
}

/// `MLMarqueeLabel` without its animation: a layer-backed, clipping box
/// holding the sized-to-fit text field. The reference look, and the
/// reference cost.
package final class MarqueeTextFieldBox: NSView {
    package let textField: TalliedTextField
    private let fieldSize: NSSize

    /// Where the field starts when the line is wider than the box — zero at
    /// rest, negative while scrolling.
    package var scrollPosition: CGFloat = 0 {
        didSet {
            textField.frame = marqueeTextFieldFrame(fieldSize: fieldSize, in: bounds, scrollPosition: scrollPosition)
        }
    }

    package init(text: String, drawTally: DrawTally?) {
        self.textField = makeMarqueeStyledTextField(drawTally: drawTally)
        textField.stringValue = text
        textField.sizeToFit()
        self.fieldSize = textField.frame.size
        super.init(frame: NSRect(x: 0, y: 0, width: MenuBarLyricsGeometry.lyricsWidth, height: MenuBarLyricsGeometry.lyricsHeight))
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(textField)
        textField.frame = marqueeTextFieldFrame(fieldSize: fieldSize, in: bounds)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    package override var intrinsicContentSize: NSSize {
        NSSize(width: MenuBarLyricsGeometry.lyricsWidth, height: MenuBarLyricsGeometry.lyricsHeight)
    }
}

/// `MenuBarControlButton` as `MenuBarLyricsController.configureControlButton`
/// sets it up.
@MainActor
package func makePlaybackControlButton(symbolName: String, drawTally: DrawTally?) -> TalliedButton {
    let button = TalliedButton(frame: NSRect(x: 0, y: 0, width: MenuBarLyricsGeometry.controlButtonSize, height: MenuBarLyricsGeometry.controlButtonSize))
    button.isBordered = false
    button.imagePosition = .imageOnly
    button.imageScaling = .scaleProportionallyDown
    button.bezelStyle = .flexiblePush
    button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    button.drawTally = drawTally
    return button
}

/// What draws the lyric line.
package enum LyricsRendering: String, CaseIterable, Sendable {
    /// MLMarqueeLabel's text field, as shipped before macOS 26.
    case marqueeTextField
    /// `MenuBarMarqueeLabel`, the replacement, scrolling on its own.
    case menuBarMarqueeLabel

    @MainActor
    func makeView(text: String, lineDisplayTime: TimeInterval, drawTally: DrawTally) -> NSView {
        switch self {
        case .marqueeTextField:
            return MarqueeTextFieldBox(text: text, drawTally: drawTally)
        case .menuBarMarqueeLabel:
            guard #available(macOS 26, *) else {
                preconditionFailure("MenuBarMarqueeLabel exists only on macOS 26 and later")
            }
            let marqueeLabel = MenuBarMarqueeLabel(frame: NSRect(x: 0, y: 0, width: MenuBarLyricsGeometry.lyricsWidth, height: MenuBarLyricsGeometry.lyricsHeight))
            marqueeLabel.drawingObserver = { drawTally.recordDraw(source: "menuBarMarqueeLabel") }
            marqueeLabel.scrollPositionObserver = { drawTally.recordPosition($0) }
            marqueeLabel.setStringValue(text, lineDisplayTime: lineDisplayTime)
            return marqueeLabel
        }
    }
}

/// What sits beside the lyric line.
package enum StatusItemNeighbors: String, CaseIterable, Sendable {
    case none
    /// The three playback buttons, configured like `MenuBarControlButton`.
    case playbackButtons
    /// The same three symbols as plain image views — no controls at all.
    case symbolImageViews
}

/// What a probe puts into the status item.
package struct StatusItemContent: Hashable, Sendable, CustomStringConvertible {
    package var lyrics: LyricsRendering
    package var neighbors: StatusItemNeighbors

    package init(lyrics: LyricsRendering, neighbors: StatusItemNeighbors) {
        self.lyrics = lyrics
        self.neighbors = neighbors
    }

    package var description: String {
        "\(lyrics.rawValue)+\(neighbors.rawValue)"
    }

    package init?(description: String) {
        let parts = description.split(separator: "+").map(String.init)
        guard parts.count == 2,
              let lyrics = LyricsRendering(rawValue: parts[0]),
              let neighbors = StatusItemNeighbors(rawValue: parts[1]) else {
            return nil
        }
        self.init(lyrics: lyrics, neighbors: neighbors)
    }

    /// The status item's content view, and the lyric view inside it, laid out
    /// like `MenuBarLyricsController`'s stack view.
    @MainActor
    package func makeViews(text: String, lineDisplayTime: TimeInterval, drawTally: DrawTally) -> (content: NSView, lyrics: NSView) {
        let lyricsView = lyrics.makeView(text: text, lineDisplayTime: lineDisplayTime, drawTally: drawTally)
        lyricsView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            lyricsView.widthAnchor.constraint(equalToConstant: MenuBarLyricsGeometry.lyricsWidth),
            lyricsView.heightAnchor.constraint(equalToConstant: MenuBarLyricsGeometry.lyricsHeight),
        ])
        var arrangedViews: [NSView] = [lyricsView]
        let symbolNames = ["backward.end.fill", "play.fill", "forward.end.fill"]
        let neighborViews: [NSView] = switch neighbors {
        case .none:
            []
        case .playbackButtons:
            symbolNames.map { makePlaybackControlButton(symbolName: $0, drawTally: drawTally) }
        case .symbolImageViews:
            symbolNames.map { symbolName in
                let imageView = TalliedImageView()
                imageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
                imageView.imageScaling = .scaleProportionallyDown
                imageView.drawTally = drawTally
                return imageView
            }
        }
        for neighborView in neighborViews {
            neighborView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                neighborView.widthAnchor.constraint(equalToConstant: MenuBarLyricsGeometry.controlButtonSize),
                neighborView.heightAnchor.constraint(equalToConstant: MenuBarLyricsGeometry.controlButtonSize),
            ])
            arrangedViews.append(neighborView)
        }
        let stackView = NSStackView(views: arrangedViews)
        stackView.orientation = .horizontal
        stackView.distribution = .fill
        stackView.alignment = .centerY
        stackView.spacing = MenuBarLyricsGeometry.controlSpacing
        stackView.setCustomSpacing(MenuBarLyricsGeometry.lyricsToControlsGap, after: lyricsView)
        return (stackView, lyricsView)
    }
}
