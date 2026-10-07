import AppKit
import LyricsXFoundation
import SnapKit

class KaraokeLyricsView: NSView {
    private let backgroundView: NSView
    private let contentStackView: NSStackView

    var preferredSizeDidChange: (() -> Void)?
    private var sizeUpdatePending = false

    /// Size the existing desktop window to its content, not the entire display.
    var preferredWindowSize: NSSize {
        let sizes = contentStackView.arrangedSubviews.filter { !$0.isHidden }.map { $0.intrinsicContentSize }
        let spacing = CGFloat(max(0, sizes.count - 1)) * contentStackView.spacing
        let width = isVertical ? sizes.reduce(0) { $0 + max(0, $1.width) } + spacing : sizes.map(\.width).max() ?? 0
        let height = isVertical ? sizes.map(\.height).max() ?? 0 : sizes.reduce(0) { $0 + max(0, $1.height) } + spacing
        let horizontalInset = isVertical ? font.pointSize / 3 : font.pointSize
        let verticalInset = isVertical ? font.pointSize : font.pointSize / 3
        return NSSize(width: ceil(width + horizontalInset * 2), height: ceil(height + verticalInset * 2))
    }

    private func scheduleSizeUpdate() {
        guard !sizeUpdatePending else { return }
        sizeUpdatePending = true
        // Let KVO bindings update the labels' font/orientation before measuring.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.sizeUpdatePending = false
            self.preferredSizeDidChange?()
        }
    }

    @objc dynamic var isVertical = false {
        didSet {
            contentStackView.orientation = isVertical ? .horizontal : .vertical
            (isVertical ? displayLine2 : displayLine1).map { contentStackView.insertArrangedSubview($0, at: 0) }
            updateFontSize()
        }
    }

    @objc dynamic var drawFurigana = false { didSet { scheduleSizeUpdate() } }
    @objc dynamic var useSourceFurigana = true { didSet { scheduleSizeUpdate() } }
    @objc dynamic var drawRomajin = false { didSet { scheduleSizeUpdate() } }

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
        scheduleSizeUpdate()
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
            scheduleSizeUpdate()
            layoutSubtreeIfNeeded()
        }, completionHandler: {
            self.mouseTest()
        })
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
