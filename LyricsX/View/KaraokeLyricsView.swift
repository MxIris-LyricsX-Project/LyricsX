import AppKit
import LyricsXFoundation
import SnapKit

class KaraokeLyricsView: NSView {
    private let backgroundView: NSView
    private let contentStackView: NSStackView

    @objc dynamic var isVertical = false {
        didSet {
            contentStackView.orientation = isVertical ? .horizontal : .vertical
            (isVertical ? displayLine2 : displayLine1).map { contentStackView.insertArrangedSubview($0, at: 0) }
            updateFontSize()
        }
    }

    @objc dynamic var drawFurigana = false
    @objc dynamic var useSourceFurigana = true
    @objc dynamic var drawRomajin = false

    @objc dynamic var isDraggable = false {
        didSet {
            if !isDraggable, isDragging {
                isDragging = false
                NSCursor.arrow.set()
            }
            // The hand cursor comes from the tracking area, not from cursor
            // rects: rebuilding cursor rects lays the window out outside the
            // line-change animation, so the box jumped to its new origin.
            updateTrackingAreas()
        }
    }

    private var isDragging = false

    @objc dynamic var font = NSFont.labelFont(ofSize: 24) { didSet { updateFontSize() } }
    @objc dynamic var textColor = #colorLiteral(red: 1, green: 1, blue: 1, alpha: 1)
    @objc dynamic var shadowColor = #colorLiteral(red: 0, green: 1, blue: 0.8333333333, alpha: 1)
    @objc dynamic var progressColor = #colorLiteral(red: 0, green: 1, blue: 0.8333333333, alpha: 1)
    @objc dynamic var backgroundColor = #colorLiteral(red: 0, green: 0, blue: 0, alpha: 0.6018835616) {
        didSet {
            backgroundView.layer?.backgroundColor = backgroundColor.cgColor
        }
    }

    @objc dynamic var shouldHideWithMouse = true {
        didSet {
            updateTrackingAreas()
        }
    }

    var displayLine1: KaraokeLabel?
    var displayLine2: KaraokeLabel?

    override init(frame frameRect: NSRect) {
        self.contentStackView = NSStackView(frame: frameRect)
        contentStackView.orientation = .vertical
        contentStackView.autoresizingMask = [.width, .height]
        self.backgroundView = NSView() // NSVisualEffectView(frame: frameRect)
        backgroundView.autoresizingMask = [.width, .height]
        backgroundView.wantsLayer = true
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(backgroundView)
        backgroundView.addSubview(contentStackView)
        backgroundView.layer?.cornerRadius = 12
    }

    @available(*, unavailable)
    required init?(coder decoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateFontSize() {
        var insetX = font.pointSize
        var insetY = insetX / 3
        if isVertical {
            (insetX, insetY) = (insetY, insetX)
        }
        contentStackView.snp.remakeConstraints {
            $0.edges.equalToSuperview().inset(NSEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX))
        }
        contentStackView.spacing = font.pointSize / 3
        backgroundView.layer?.cornerRadius = font.pointSize / 2
    }

    private func lyricsLabel(_ content: String, sourceFurigana: LyricsLine.Attachments.RangeAttribute?) -> KaraokeLabel {
        if let view = contentStackView.subviews.lazy.compactMap({ $0 as? KaraokeLabel }).first(where: { !contentStackView.arrangedSubviews.contains($0) }) {
            view.alphaValue = 0
            view.stringValue = content
            view.sourceFurigana = sourceFurigana
            view.removeProgressAnimation()
            view.removeFromSuperview()
            return view
        }
        return KaraokeLabel(labelWithString: content).then {
            $0.bind(\.font, to: self, withKeyPath: \.font)
            $0.bind(\.textColor, to: self, withKeyPath: \.textColor)
            $0.bind(\.progressColor, to: self, withKeyPath: \.progressColor)
            $0.bind(\._shadowColor, to: self, withKeyPath: \.shadowColor)
            $0.bind(\.isVertical, to: self, withKeyPath: \.isVertical)
            $0.bind(\.drawFurigana, to: self, withKeyPath: \.drawFurigana)
            $0.bind(\.useSourceFurigana, to: self, withKeyPath: \.useSourceFurigana)
            $0.bind(\.drawRomajin, to: self, withKeyPath: \.drawRomajin)
            $0.sourceFurigana = sourceFurigana
            $0.alphaValue = 0
        }
    }

    func displayLrc(
        _ firstLine: String,
        secondLine: String = "",
        firstLineFurigana: LyricsLine.Attachments.RangeAttribute? = nil,
        secondLineFurigana: LyricsLine.Attachments.RangeAttribute? = nil
    ) {
        // Pause/resume and timing corrections often publish the same pair.
        // Keep their views instead of fading out and rebuilding the highlight.
        if let first = displayLine1, first.stringValue == firstLine,
           (displayLine2?.stringValue ?? "") == secondLine,
           sameFurigana(first.sourceFurigana, firstLineFurigana),
           sameFurigana(displayLine2?.sourceFurigana, secondLineFurigana) {
            mouseTest()
            return
        }
        var toBeHide = contentStackView.arrangedSubviews.compactMap { $0 as? KaraokeLabel }
        var toBeShow: [NSTextField] = []
        var shouldHideAll = false

        let index = isVertical ? 0 : 1
        if firstLine.trimmingCharacters(in: .whitespaces).isEmpty {
            displayLine1 = nil
            shouldHideAll = true
        } else if toBeHide.count == 2, toBeHide[index].stringValue == firstLine {
            displayLine1 = toBeHide[index]
            displayLine1?.sourceFurigana = firstLineFurigana
            toBeHide.remove(at: index)
        } else {
            let label = lyricsLabel(firstLine, sourceFurigana: firstLineFurigana)
            displayLine1 = label
            toBeShow.append(label)
        }

        if !secondLine.trimmingCharacters(in: .whitespaces).isEmpty {
            let label = lyricsLabel(secondLine, sourceFurigana: secondLineFurigana)
            displayLine2 = label
            toBeShow.append(label)
        } else {
            displayLine2 = nil
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.allowsImplicitAnimation = true
            context.timingFunction = .swiftOut
            toBeHide.forEach {
                contentStackView.removeArrangedSubview($0)
                $0.isHidden = true
                $0.alphaValue = 0
                $0.removeProgressAnimation()
            }
            toBeShow.forEach {
                if isVertical {
                    contentStackView.insertArrangedSubview($0, at: 0)
                } else {
                    contentStackView.addArrangedSubview($0)
                }
                $0.isHidden = false
                $0.alphaValue = 1
            }
            isHidden = shouldHideAll
            layoutSubtreeIfNeeded()
        }, completionHandler: {
            self.mouseTest()
        })
    }

    private func sameFurigana(
        _ lhs: LyricsLine.Attachments.RangeAttribute?,
        _ rhs: LyricsLine.Attachments.RangeAttribute?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return lhs.attributes.count == rhs.attributes.count
                && zip(lhs.attributes, rhs.attributes).allSatisfy {
                    $0.0.range == $0.1.range && $0.0.content == $0.1.content
                }
        default:
            return false
        }
    }

    // MARK: - Event

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        // Keep the mouse-down target on this persistent container, not on a
        // text field which can consume the press or be recycled mid-drag.
        return isDraggable ? self : hit
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return isDraggable || super.acceptsFirstMouse(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        if isDraggable {
            isDragging = true
            NSCursor.closedHand.set()
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if isDragging { NSCursor.closedHand.set() }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        if isDraggable {
            let location = convert(event.locationInWindow, from: nil)
            (bounds.contains(location) ? NSCursor.openHand : NSCursor.arrow).set()
        }
        super.mouseUp(with: event)
    }

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingArea.map(removeTrackingArea)
        trackingArea = nil
        if shouldHideWithMouse || isDraggable {
            let trackingOptions: NSTrackingArea.Options = [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .assumeInside]
            trackingArea = NSTrackingArea(rect: bounds, options: trackingOptions, owner: self)
            trackingArea.map(addTrackingArea)
        }
        mouseTest()
    }

    private func mouseTest() {
        if shouldHideWithMouse,
           let point = NSEvent.mouseLocation(in: self),
           bounds.contains(point) {
            animator().alphaValue = 0
        } else {
            animator().alphaValue = 1
        }
    }

    override func mouseMoved(with event: NSEvent) {
        if isDraggable {
            (isDragging ? NSCursor.closedHand : NSCursor.openHand).set()
        } else if shouldHideWithMouse, alphaValue != 0 {
            animator().alphaValue = 0
        }
    }

    override func mouseEntered(with event: NSEvent) {
        if isDraggable {
            (isDragging ? NSCursor.closedHand : NSCursor.openHand).set()
        } else if shouldHideWithMouse {
            animator().alphaValue = 0
        }
    }

    override func mouseExited(with event: NSEvent) {
        if isDraggable {
            if !isDragging { NSCursor.arrow.set() }
        } else {
            animator().alphaValue = 1
        }
    }
}

extension NSEvent {
    class func mouseLocation(in view: NSView) -> NSPoint? {
        guard let window = view.window else { return nil }
        let windowLocation = window.convertFromScreen(NSRect(origin: NSEvent.mouseLocation, size: .zero)).origin
        return view.convert(windowLocation, from: nil)
    }
}

extension NSTextField {
    // swiftlint:disable:next identifier_name
    @objc dynamic var _shadowColor: NSColor? {
        get {
            return shadow?.shadowColor
        }
        set {
            shadow = newValue.map { color in
                NSShadow().then {
                    $0.shadowBlurRadius = 3
                    $0.shadowColor = color
                    $0.shadowOffset = .zero
                }
            }
        }
    }
}
