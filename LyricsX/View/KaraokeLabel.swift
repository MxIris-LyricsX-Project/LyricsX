import Cocoa
import SwiftCF
import LyricsXFoundation
import CoreGraphicsExt
import CoreTextExt

class KaraokeLabel: NSTextField {
    @objc dynamic var isVertical = false {
        didSet {
            clearCache()
            invalidateIntrinsicContentSize()
        }
    }

    @objc dynamic var drawFurigana = false {
        didSet {
            clearCache()
            invalidateIntrinsicContentSize()
        }
    }

    @objc dynamic var useSourceFurigana = true {
        didSet {
            clearCache()
            invalidateIntrinsicContentSize()
        }
    }

    @objc dynamic var drawRomajin = false {
        didSet {
            clearCache()
            invalidateIntrinsicContentSize()
        }
    }

    var sourceFurigana: LyricsLine.Attachments.RangeAttribute? {
        didSet {
            clearCache()
            invalidateIntrinsicContentSize()
        }
    }

    override var attributedStringValue: NSAttributedString {
        didSet {
            clearCache()
        }
    }

    override var stringValue: String {
        didSet {
            clearCache()
        }
    }

    @objc override dynamic var font: NSFont? {
        didSet {
            clearCache()
        }
    }

    @objc override dynamic var textColor: NSColor? {
        didSet {
            clearCache()
        }
    }

    private func clearCache() {
        _attrString = nil
        _ctFrame = nil
        needsLayout = true
        needsDisplay = true
        removeProgressAnimation()
    }

    private var _attrString: NSAttributedString?
    private var romajinAnnotations: [(String, NSRange)] = []

    private var attrString: NSAttributedString {
        if let attrString = _attrString {
            return attrString
        }
        let attrString = NSMutableAttributedString(attributedString: attributedStringValue)
        let content = attrString.string
        let string = attrString.string as NSString
        // English-heavy lyrics can be classified as a different language even
        // when they contain Japanese words. Kana is explicit Japanese evidence.
        let isJapaneseLine = string.dominantLanguage == "ja"
        let hasJapaneseText = isJapaneseLine
            || content.range(of: #"[\p{sc=Hiragana}\p{sc=Katakana}]"#, options: .regularExpression) != nil
        let shouldDrawFurigana = drawFurigana && hasJapaneseText
        let shouldDrawRomajin = drawRomajin && hasJapaneseText
        let didApplySourceFurigana = shouldDrawFurigana
            && useSourceFurigana
            && sourceFurigana.map { addSourceFurigana($0, to: attrString, content: content) } == true
        let tokenRanges: [NSRange]
        if hasJapaneseText && !isJapaneseLine {
            // A locale alone does not change the whole-line language decision.
            // Scope tokenization to Japanese runs while retaining UTF-16 offsets.
            let pattern = #"[\p{sc=Han}\p{sc=Hiragana}\p{sc=Katakana}\p{M}ー]+"#
            let expression = try? NSRegularExpression(pattern: pattern)
            tokenRanges = expression?.matches(in: content, range: string.fullRange).map(\.range) ?? []
        } else {
            tokenRanges = [string.fullRange]
        }
        let locale = hasJapaneseText ? CFLocale.from(NSLocale(localeIdentifier: "ja")) : nil
        romajinAnnotations = []
        for range in tokenRanges {
            let tokenRange = CFRange(location: range.location, length: range.length)
            let tokenizer = CFStringTokenizer.create(string: .from(string), range: tokenRange, locale: locale)
            for tokenType in IteratorSequence(tokenizer) where tokenType.contains(.isCJWordMask) {
                if isVertical {
                    let tokenRange = tokenizer.currentTokenRange()
                    let attr: [NSAttributedString.Key: Any] = [
                        .verticalGlyphForm: true,
                        .baselineOffset: (font?.pointSize ?? 24) * 0.25,
                    ]
                    attrString.addAttributes(attr, range: tokenRange.asNS)
                }
                if shouldDrawFurigana && !didApplySourceFurigana {
                    for (furigana, range) in tokenizer.currentFuriganaAnnotations(in: string) {
                        var attr: [CFAttributedString.Key: Any] = [.ctRubySizeFactor: 0.5]
                        attr[.ctForegroundColor] = textColor
                        let annotation = CTRubyAnnotation.create(furigana, attributes: attr)
                        attrString.addAttribute(.cf(.ctRubyAnnotation), value: annotation, range: range)
                    }
                }
                if shouldDrawRomajin, let (romajin, range) = tokenizer.currentRomanjiAnnotation(in: string) {
                    romajinAnnotations.append((romajin as String, range))
                }
            }
        }
        textColor?.do { attrString.addAttributes([.foregroundColor: $0], range: attrString.fullRange) }
        _attrString = attrString
        return attrString
    }

    private func addSourceFurigana(
        _ sourceFurigana: LyricsLine.Attachments.RangeAttribute,
        to attrString: NSMutableAttributedString,
        content: String
    ) -> Bool {
        let annotations = sourceFurigana.attributes.compactMap { attribute -> (range: NSRange, text: CFString)? in
            guard let range = content.nsRange(fromCharacterRange: attribute.range) else { return nil }
            return (range, attribute.content as CFString)
        }
        let style = sourceRubyStyle(for: annotations.map(\.range), in: attrString)
        for (index, annotation) in annotations.enumerated() {
            var attributes: [CFAttributedString.Key: Any] = [.ctRubySizeFactor: 0.5]
            attributes[.ctForegroundColor] = textColor
            if let style {
                attributes[.ctFont] = style.font
                attributes[.ctBaselineOffset] = style.offsets[index]
            }
            let ruby = CTRubyAnnotation.create(annotation.text, attributes: attributes)
            attrString.addAttribute(.cf(.ctRubyAnnotation), value: ruby, range: annotation.range)
        }
        return !annotations.isEmpty
    }

    private func sourceRubyStyle(
        for ranges: [NSRange], in text: NSAttributedString
    ) -> (font: CTFont, offsets: [CGFloat])? {
        guard !isVertical, ranges.count > 1, let font else { return nil }

        // CoreText anchors each ruby to the ascent of its base run. Digits and
        // kana/kanji can resolve to different cascade fonts on the same line.
        let runs = CTLineCreateWithAttributedString(text).glyphRuns.map { run in
            var ascent: CGFloat = 0
            CTRunGetTypographicBounds(run, CFRangeMake(0, 0), &ascent, nil, nil)
            return (range: run.stringRange.asNS, ascent: ascent)
        }
        let ascents = ranges.map { range in
            runs.lazy.filter { NSIntersectionRange(range, $0.range).length > 0 }
                .map(\.ascent).max() ?? font.ascender
        }
        guard let tallest = ascents.max(), let shortest = ascents.min(), tallest - shortest > 0.5 else {
            return nil
        }

        // Use one kana-capable font for the ruby itself, independent of the
        // fallback used by each base run. Give the tallest run a small gap,
        // then add the missing ascent to every shorter run.
        let sample = "あ" as CFString
        let baseRubyFont = NSFont.systemFont(ofSize: font.pointSize * 0.5)
        let rubyFont = CTFontCreateForStringWithLanguage(baseRubyFont as CTFont, sample, CFRangeMake(0, 1), "ja" as CFString)
        let gap = font.pointSize * 0.1
        return (rubyFont, ascents.map { gap + tallest - $0 })
    }

    private var _ctFrame: CTFrame?
//    private var ctFrame: CTFrame {
//        if let ctFrame = _ctFrame {
//            return ctFrame
//        }
//        layoutSubtreeIfNeeded()
//        let progression: CTFrameProgression = isVertical ? .rightToLeft : .topToBottom
//        let frameAttr: [CTFrame.AttributeKey: Any] = [.progression: progression.rawValue as NSNumber]
//        let framesetter = CTFramesetter.create(attributedString: attrString)
//        print(bounds.size)
//        let (suggestSize, fitRange) = framesetter.suggestFrameSize(constraints: bounds.size, frameAttributes: frameAttr)
//        let path = CGPath(rect: CGRect(origin: .zero, size: suggestSize), transform: nil)
//        let ctFrame = framesetter.frame(stringRange: fitRange, path: path, frameAttributes: frameAttr)
//        _ctFrame = ctFrame
//        return ctFrame
//    }

    /// The bounds size `_ctFrame` was laid out for.
    private var ctFrameLayoutSize: CGSize?

    private func ctFrame(_ dirtyRect: NSRect? = nil) -> CTFrame {
        // The layout fits the text into the label's bounds, so it only holds
        // for the size it was made at. A new or reused label draws once at its
        // old, smaller frame before the stack view gives it the size of its
        // new line, and a layout kept from that draw fits none of the text:
        // the line stayed blank until the next line replaced it (#215).
        if let ctFrame = _ctFrame, ctFrameLayoutSize == bounds.size {
            return ctFrame
        }
        if dirtyRect == nil {
            layoutSubtreeIfNeeded()
        }
        let progression: CTFrameProgression = isVertical ? .rightToLeft : .topToBottom
        let frameAttr: [CTFrame.AttributeKey: Any] = [.progression: progression.rawValue as NSNumber]
        let framesetter = CTFramesetter.create(attributedString: attrString)
        // A partial repaint must use the same layout as the progress mask.
        let layoutSize = bounds.size
        let (suggestSize, fitRange) = framesetter.suggestFrameSize(constraints: layoutSize, frameAttributes: frameAttr)
        let path = CGPath(rect: CGRect(origin: .zero, size: suggestSize), transform: nil)
        let ctFrame = framesetter.frame(stringRange: fitRange, path: path, frameAttributes: frameAttr)
        _ctFrame = ctFrame
        ctFrameLayoutSize = layoutSize
        return ctFrame
    }

    override var intrinsicContentSize: NSSize {
        let progression: CTFrameProgression = isVertical ? .rightToLeft : .topToBottom
        let frameAttr: [CTFrame.AttributeKey: Any] = [.progression: progression.rawValue as NSNumber]
        let framesetter = CTFramesetter.create(attributedString: attrString)
        let constraints = CGSize(width: CGFloat.infinity, height: .infinity)
        return framesetter.suggestFrameSize(constraints: constraints, frameAttributes: frameAttr).size
    }

    override func draw(_ dirtyRect: NSRect) {
//        let image = NSImage(size: dirtyRect.size, flipped: true) { rect in
//            guard let context = NSGraphicsContext.current else { return false }
//            let cgContext = context.cgContext
//            cgContext.textMatrix = .identity
//            cgContext.translateBy(x: 0, y: rect.height)
//            cgContext.scaleBy(x: 1.0, y: -1.0)
//            CTFrameDraw(self.ctFrame, cgContext)
//            return true
//        }
//        image.draw(in: dirtyRect)
        guard let context = NSGraphicsContext.current else { return }
        let cgContext = context.cgContext
        cgContext.textMatrix = .identity
        cgContext.translateBy(x: 0, y: bounds.height)
        cgContext.scaleBy(x: 1.0, y: -1.0)
        let textFrame = ctFrame(dirtyRect)
        CTFrameDraw(textFrame, cgContext)

        // Paint text and romaji from one layout snapshot. Do not resolve or
        // force a second layout after part of this draw pass is already painted.
        drawRomajiAnnotations(in: cgContext, frame: textFrame)
    }

    // MARK: - Progress

    // TODO: multi-line
    private lazy var progressLayer: CALayer = {
        let pLayer = CALayer()
        wantsLayer = true
        layer?.addSublayer(pLayer)
        return pLayer
    }()

    @objc dynamic var progressColor: NSColor? {
        get {
            return progressLayer.backgroundColor.flatMap(NSColor.init)
        }
        set {
            progressLayer.backgroundColor = newValue?.cgColor
        }
    }

    func setProgressAnimation(color: NSColor, progress: [(TimeInterval, Int)]) {
        // Geometry and mask changes must be atomic. Pausing this layer also
        // freezes implicit bounds/position animations, possibly at zero height.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        removeProgressAnimation()
        let textFrame = ctFrame()
        guard let line = textFrame.lines.first,
              let origin = textFrame.lineOrigins(range: CFRange(location: 0, length: 1)).first else {
            return
        }
        var lineBounds = line.bounds()
        var transform = CGAffineTransform.translate(x: origin.x, y: origin.y)
        if isVertical {
            transform.transform(by: .swap() * .translate(y: -lineBounds.width))
            transform *= .flip(height: bounds.height)
        }
        lineBounds.apply(t: transform)

        if isVertical {
            // Rotated horizontal line metrics do not cover vertical glyph offsets.
            // Keep the full column width while animating only its height.
            lineBounds.origin.x = bounds.minX
            lineBounds.size.width = bounds.width
        }

        let originalLineBounds = lineBounds
        let romajiBounds = drawRomajiAnnotations(in: nil, frame: textFrame)
        if !romajiBounds.isNull {
            // Romaji is drawn separately below the CoreText frame. Include its
            // actual ink in the mask without changing the label's layout size.
            let paddedBounds = CGRect(x: romajiBounds.minX - 1, y: romajiBounds.minY - 1,
                                      width: romajiBounds.width + 2, height: romajiBounds.height + 2)
            lineBounds = lineBounds.union(paddedBounds.applying(.flip(height: bounds.height)))
        }

        progressLayer.anchorPoint = isVertical ? CGPoint(x: 0.5, y: 0) : CGPoint(x: 0, y: 0.5)
        progressLayer.frame = lineBounds
        progressLayer.backgroundColor = color.cgColor
        let mask = CALayer()
        mask.frame = progressLayer.bounds
        let img = NSImage(size: progressLayer.bounds.size, flipped: false) { _ in
            let context = NSGraphicsContext.current!.cgContext
            let ori = lineBounds.applying(.flip(height: self.bounds.height)).origin
            context.concatenate(.translate(x: -ori.x, y: -ori.y))
            CTFrameDraw(textFrame, context)
            self.drawRomajiAnnotations(in: context, frame: textFrame)
            return true
        }
        mask.contents = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
        progressLayer.mask = mask

        guard let index = progress.firstIndex(where: { $0.0 > 0 }) else { return }
        let leadingInset = isVertical ? originalLineBounds.minY - lineBounds.minY : originalLineBounds.minX - lineBounds.minX
        let fullExtent = isVertical ? lineBounds.height : lineBounds.width
        var map = progress.map { time, index -> (TimeInterval, CGFloat) in
            var offset = line.offset(charIndex: index).primary + leadingInset
            if !romajiBounds.isNull {
                if index <= 0 { offset = 0 }
                if index >= stringValue.count { offset = fullExtent }
            }
            return (time, offset)
        }
        if index > 0 {
            let previous = map[index - 1]
            let next = map[index]
            // Previous time is non-positive. Interpolate forward to time zero,
            // rather than extrapolating backward into a negative layer extent.
            let fraction = CGFloat(-previous.0 / (next.0 - previous.0))
            let offset = (previous.1 + fraction * (next.1 - previous.1)).clamped(to: 0 ... fullExtent)
            map.replaceSubrange(..<index, with: [(0, offset)])
        }

        let duration = map.last!.0
        let animation = CAKeyframeAnimation()
        animation.keyTimes = map.map { ($0.0 / duration) as NSNumber }
        animation.values = map.map { $0.1 }
        animation.keyPath = isVertical ? "bounds.size.height" : "bounds.size.width"
        animation.duration = duration
        animation.beginTime = progressLayer.convertTime(CACurrentMediaTime(), from: nil)
        progressLayer.add(animation, forKey: "inlineProgress")
    }

    func pauseProgressAnimation() {
        guard progressLayer.speed != 0 else { return }
        let pausedTime = progressLayer.convertTime(CACurrentMediaTime(), from: nil)
        progressLayer.speed = 0
        progressLayer.timeOffset = pausedTime
    }

    func resumeProgressAnimation() {
        guard progressLayer.speed == 0 else { return }
        let pausedTime = progressLayer.timeOffset
        progressLayer.speed = 1
        progressLayer.timeOffset = 0
        progressLayer.beginTime = 0
        let timeSincePause = progressLayer.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
        progressLayer.beginTime = timeSincePause
    }

    func removeProgressAnimation() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progressLayer.speed = 1
        progressLayer.timeOffset = 0
        progressLayer.beginTime = 0
        progressLayer.removeAllAnimations()
        progressLayer.frame = .zero
        CATransaction.commit()
    }

    @discardableResult
    private func drawRomajiAnnotations(in context: CGContext?, frame: CTFrame) -> CGRect {
        guard drawRomajin, !romajinAnnotations.isEmpty else { return .null }

        var annotationBounds = CGRect.null

        let lines = frame.lines
        let origins = frame.lineOrigins(range: CFRangeMake(0, lines.count))
        var annotationIndex = 0

        // 处理每行和每个 glyph run
        for (line, origin) in zip(lines, origins) {
            let runs = line.glyphRuns
            for run in runs {
                let range = run.stringRange
                var subIndex = 0

                while annotationIndex + subIndex < romajinAnnotations.count {
                    let (romajin, annotationRange) = romajinAnnotations[annotationIndex + subIndex]
                    if NSRange(location: range.location, length: range.length).contains(annotationRange.location) {
                        var ascent: CGFloat = 0
                        var descent: CGFloat = 0
                        var leading: CGFloat = 0
                        let width = CTRunGetTypographicBounds(run, CFRangeMake(0, 0), &ascent, &descent, &leading)
                        // Query the line's character offset instead of reading
                        // run positions: the latter disturbs cached ruby layout
                        // on subsequent draws of the same CoreText frame.
                        let glyphX = origin.x + line.offset(charIndex: range.location).primary

                        let relativeOffset = CGFloat(annotationRange.location - range.location) / CGFloat(range.length) * width
                        let glyphBounds = CGRect(
                            x: glyphX + relativeOffset,
                            y: origin.y - descent,
                            width: width / CGFloat(range.length) * CGFloat(annotationRange.length),
                            height: ascent + descent
                        )

                        let fontSize = font?.pointSize ?? 24
                        var rubyFontSize = fontSize * 0.3
                        let rubyFontBase = NSFont.systemFont(ofSize: rubyFontSize)
                        let rubyAttrBase: [NSAttributedString.Key: Any] = [
                            .foregroundColor: textColor ?? .black,
                            .font: rubyFontBase,
                        ]
                        var rubyString = NSAttributedString(string: romajin, attributes: rubyAttrBase)
                        var rubyWidth = rubyString.size().width
                        let maxWidth = glyphBounds.width

                        while rubyWidth > maxWidth * 0.8, rubyFontSize > 1 {
                            rubyFontSize *= 0.9
                            let rubyFont = NSFont.systemFont(ofSize: rubyFontSize)
                            let rubyAttr: [NSAttributedString.Key: Any] = [
                                .font: rubyFont,
                                .foregroundColor: textColor ?? .black,
                            ]
                            rubyString = NSAttributedString(string: romajin, attributes: rubyAttr)
                            rubyWidth = rubyString.size().width
                        }

                        let glyphWidth = glyphBounds.width
                        let xOffset = (glyphWidth - rubyWidth) / 2
                        let rubyPoint = CGPoint(
                            x: glyphBounds.minX + xOffset,
                            y: glyphBounds.minY - fontSize * 0.2
                        )
                        let rubyLine = CTLineCreateWithAttributedString(rubyString)
                        let inkBounds = CTLineGetBoundsWithOptions(rubyLine, [.useGlyphPathBounds])
                            .applying(.translate(x: rubyPoint.x, y: rubyPoint.y))
                        annotationBounds = annotationBounds.union(inkBounds)
                        if let context = context {
                            context.textPosition = rubyPoint
                            CTLineDraw(rubyLine, context)
                        }

                        subIndex += 1
                    } else {
                        break
                    }
                }
                annotationIndex += subIndex
            }
        }

        // 处理剩余的 annotations
        while annotationIndex < romajinAnnotations.count {
            let (romajin, _) = romajinAnnotations[annotationIndex]
            if let lastLine = lines.last, let lastOrigin = origins.last, let lastRun = lastLine.glyphRuns.last {
                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                var leading: CGFloat = 0
                let width = CTRunGetTypographicBounds(lastRun, CFRangeMake(0, 0), &ascent, &descent, &leading)
                let glyphX = lastOrigin.x + lastLine.offset(charIndex: lastRun.stringRange.location).primary + width
                let glyphBounds = CGRect(
                    x: glyphX,
                    y: lastOrigin.y - descent,
                    width: width,
                    height: ascent + descent
                )

                let fontSize = font?.pointSize ?? 24
                var rubyFontSize = fontSize * 0.3
                let rubyAttrBase: [NSAttributedString.Key: Any] = [
                    .foregroundColor: textColor ?? .black,
                ]
                var rubyString = NSAttributedString(string: romajin, attributes: rubyAttrBase)
                var rubyWidth = rubyString.size().width
                let maxWidth = glyphBounds.width

                while rubyWidth > maxWidth * 0.8, rubyFontSize > 1 {
                    rubyFontSize *= 0.9
                    let rubyFont = NSFont.systemFont(ofSize: rubyFontSize)
                    let rubyAttr: [NSAttributedString.Key: Any] = [
                        .font: rubyFont,
                        .foregroundColor: textColor ?? .black,
                    ]
                    rubyString = NSAttributedString(string: romajin, attributes: rubyAttr)
                    rubyWidth = rubyString.size().width
                }

                let glyphWidth = glyphBounds.width
                let xOffset = (glyphWidth - rubyWidth) / 2
                let rubyPoint = CGPoint(
                    x: glyphBounds.minX + xOffset,
                    y: glyphBounds.minY - 0.2 * fontSize
                )
                let rubyLine = CTLineCreateWithAttributedString(rubyString)
                let inkBounds = CTLineGetBoundsWithOptions(rubyLine, [.useGlyphPathBounds])
                    .applying(.translate(x: rubyPoint.x, y: rubyPoint.y))
                annotationBounds = annotationBounds.union(inkBounds)
                if let context = context {
                    context.textPosition = rubyPoint
                    CTLineDraw(rubyLine, context)
                }
            }
            annotationIndex += 1
        }
        return annotationBounds
    }
}

private extension String {
    func nsRange(fromCharacterRange range: Range<Int>) -> NSRange? {
        guard range.lowerBound >= 0,
              range.upperBound <= count else {
            return nil
        }
        let lowerBound = index(startIndex, offsetBy: range.lowerBound)
        let upperBound = index(startIndex, offsetBy: range.upperBound)
        return NSRange(lowerBound ..< upperBound, in: self)
    }
}
