import AppKit
import LyricsXFoundation
import SnapKit

class KaraokeLyricsView: NSView {
    private static let entryXCorrectionKey = "lyricsEntryXCorrection"

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
        var toBeHide = contentStackView.arrangedSubviews.compactMap { $0 as? KaraokeLabel }
        var toBeShow: [NSTextField] = []
        var shouldHideAll = false
        var interruptedEntry: (CALayer, CGFloat)?

        let index = isVertical ? 0 : 1
        if firstLine.trimmingCharacters(in: .whitespaces).isEmpty {
            displayLine1 = nil
            shouldHideAll = true
        } else if toBeHide.count == 2, toBeHide[index].stringValue == firstLine {
            let preview = toBeHide[index]
            if !isVertical, let layer = preview.layer,
               layer.animation(forKey: Self.entryXCorrectionKey) != nil,
               let offset = layer.presentation()?.transform.m41, abs(offset) > 0.01 {
                interruptedEntry = (layer, offset)
            }
            displayLine1 = preview
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
                $0.layer?.removeAnimation(forKey: Self.entryXCorrectionKey)
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
            if !isVertical {
                stabilizeEnteringRows(toBeShow)
                if let (layer, offset) = interruptedEntry {
                    continueInterruptedEntry(on: layer, offset: offset)
                }
            }
        }, completionHandler: {
            self.mouseTest()
        })
    }

    private func stabilizeEnteringRows(_ rows: [NSTextField]) {
        guard !rows.isEmpty, let overlay = layer, let background = backgroundView.layer,
              let stack = contentStackView.layer else { return }

        for row in rows {
            guard let textLayer = row.layer else { continue }
            let layers = [overlay, background, stack, textLayer]
            // These AppKit backing layers use a top-level translation. With
            // zero X anchors, an animated width adds no X translation.
            guard layers.allSatisfy({ $0.anchorPoint.x == 0 && $0.bounds.origin.x == 0
                && CATransform3DIsIdentity($0.transform) && CATransform3DIsIdentity($0.sublayerTransform) })
            else { continue }

            // A recycled row can also animate its own X. Sum the moves from
            // this layout transaction instead of correcting just the parent.
            let moves = layers.compactMap(horizontalPositionMove)
            guard let original = moves.first?.1,
                  moves.allSatisfy({ _, move in
                      move.beginTime == original.beginTime && move.duration == original.duration
                          && move.timingFunction == original.timingFunction
                  })
            else { continue }
            let offset = moves.reduce(CGFloat.zero) { $0 + $1.0 }
            guard abs(offset) > 1 else { continue }

            addEntryXCorrection(to: textLayer, offset: offset, following: original)
        }
    }

    private func continueInterruptedEntry(on textLayer: CALayer, offset: CGFloat) {
        // The preview can be promoted before its old correction finishes.
        // Rebase its remaining X offset on the new position animation,
        // rather than letting the old offset decay against a different path.
        let layers = [layer, backgroundView.layer, contentStackView.layer, textLayer].compactMap { $0 }
        if let newMove = layers.lazy.compactMap(horizontalPositionMove).first(where: { $0.1.beginTime == 0 }) {
            addEntryXCorrection(to: textLayer, offset: offset, following: newMove.1)
        }
    }

    private func horizontalPositionMove(_ layer: CALayer) -> (CGFloat, CABasicAnimation)? {
        guard let move = layer.animation(forKey: "position") as? CABasicAnimation,
              move.keyPath == "position", !move.isAdditive,
              move.speed == 1, move.timeOffset == 0, move.repeatCount == 0, move.repeatDuration == 0,
              !move.autoreverses, let from = move.fromValue as? NSValue else { return nil }
        let targetX = (move.toValue as? NSValue)?.pointValue.x ?? layer.position.x
        let offset = targetX - from.pointValue.x
        guard abs(offset) > 0.01, move.beginTime == 0
            || layer.convertTime(CACurrentMediaTime(), from: nil) < move.beginTime + move.duration
        else { return nil }
        return (offset, move)
    }

    private func addEntryXCorrection(to layer: CALayer, offset: CGFloat, following motion: CABasicAnimation) {
        // Leave the original position/bounds/opacity animations alone.
        let correction = CABasicAnimation(keyPath: "transform.translation.x")
        correction.isAdditive = true
        correction.fromValue = offset
        correction.toValue = 0
        correction.duration = motion.duration
        correction.beginTime = motion.beginTime
        correction.timingFunction = motion.timingFunction
        layer.add(correction, forKey: Self.entryXCorrectionKey)
    }

    // MARK: - Event

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingArea.map(removeTrackingArea)
        if shouldHideWithMouse {
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
        if alphaValue != 0 {
            animator().alphaValue = 0
        }
    }

    override func mouseEntered(with event: NSEvent) {
        animator().alphaValue = 0
    }

    override func mouseExited(with event: NSEvent) {
        animator().alphaValue = 1
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
