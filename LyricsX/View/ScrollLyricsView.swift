import AppKit
import Combine
import CoreText
import LyricsXFoundation
import OpenCC

protocol ScrollLyricsViewDelegate: AnyObject {
    func doubleClickLyricsLine(at position: TimeInterval)
    func lyricsViewContextMenu() -> NSMenu
    func scrollWheelDidStartScroll()
    func scrollWheelDidEndScroll()
}

final class LyricsTextView: LyricsInteractionTextView {
    /// The part of the playing line sung so far, drawn in `color` instead of
    /// the colour its text has: the line's glyphs, within `rects` — the line
    /// fragments sung through, and the one being sung up to the sung edge.
    struct SungPart: Equatable {
        var glyphRange: NSRange
        /// In the view's coordinates; they never overlap.
        var rects: [NSRect]
        var color: NSColor
    }

    /// Drawn over the text, so the sung edge can stop inside a character —
    /// which no colour attribute can — and moving it lays nothing out again.
    var sungPart: SungPart? {
        didSet {
            guard sungPart != oldValue else { return }
            let changedRects = (oldValue?.rects ?? []) + (sungPart?.rects ?? [])
            if let changedArea = changedRects.dropFirst().reduce(changedRects.first, { $0?.union($1) }) {
                setNeedsDisplay(changedArea)
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let sungPart, !sungPart.rects.isEmpty,
              let context = NSGraphicsContext.current?.cgContext,
              let layoutManager else {
            super.draw(dirtyRect)
            return
        }
        // The text as it is, except where the sung part goes…
        context.saveGState()
        context.addRect(bounds)
        context.addRects(sungPart.rects)
        context.clip(using: .evenOdd)
        super.draw(dirtyRect)
        context.restoreGState()
        // …and there the line's glyphs, drawn on a layer of their own and
        // painted over in the sung colour wherever they left ink, so each
        // pixel comes from one colour only.
        context.saveGState()
        context.clip(to: sungPart.rects)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        layoutManager.drawGlyphs(forGlyphRange: sungPart.glyphRange, at: textContainerOrigin)
        context.setBlendMode(.sourceIn)
        sungPart.color.setFill()
        context.fill(sungPart.rects)
        context.endTransparencyLayer()
        context.restoreGState()
    }
}

final class LyricsPlaceholderTextField: LyricsContextMenuTextField {}

class ScrollLyricsView: NSScrollView {
    /// Not `delegate`: with UIFoundation's `AppleInternal` trait on, AppKit's private
    /// headers declare `NSScrollView.delegate`, and a property of that name here
    /// no longer compiles.
    weak var lyricsViewDelegate: ScrollLyricsViewDelegate?

    private var textView: LyricsTextView {
        // swiftlint:disable:next force_cast
        return documentView as! LyricsTextView
    }

    var fadeStripWidth: CGFloat = 24

    @objc dynamic var textColor = #colorLiteral(red: 0.7540688515, green: 0.7540867925, blue: 0.7540771365, alpha: 1) {
        didSet {
            DispatchQueue.main.async {
                let range = self.textView.string.fullRange
                self.textView.textStorage?.addAttribute(.foregroundColor, value: self.textColor, range: range)
                self.paintHighlightedLine()
            }
        }
    }

    @objc dynamic var highlightColor = #colorLiteral(red: 0.8866666667, green: 1, blue: 0.8, alpha: 1) {
        didSet {
            DispatchQueue.main.async {
                self.paintHighlightedLine()
                self.updateSungPart()
            }
        }
    }

    /// The colour of the part of the playing line not sung yet. Setting it
    /// turns on karaoke progress, the way the menu bar shows it: on a line
    /// with inline time tags, the part sung so far in `highlightColor`, its
    /// edge moving smoothly through each word as the tags time it, and the
    /// rest of the line this colour. Nil — the default — marks the whole line
    /// in `highlightColor`.
    var karaokeUnsungTextColor: NSColor? {
        didSet {
            paintHighlightedLine()
            updateSungPart()
        }
    }

    @objc dynamic var fontName = "Helvetica" {
        didSet { updateFont() }
    }

    @objc dynamic var fontSize: CGFloat = 12 {
        didSet { updateFont() }
    }

    /// A font that replaces `fontName` and `fontSize`, for a view that does
    /// not follow the lyrics window's font preferences. The system font is the
    /// reason it exists: it has no name to put in `fontName` — asking for
    /// `.AppleSystemUIFont` by name gets Times.
    var fixedFont: NSFont? {
        didSet { updateFont() }
    }

    private var resolvedFont: NSFont {
        fixedFont ?? LyricsHUDWindowConfiguration.textFont(named: fontName, size: fontSize)
    }

    private var ranges: [(TimeInterval, NSRange)] = []
    /// One per entry of `ranges`: the line's karaoke timing, when it has one.
    private var karaokeLines: [KaraokeLineLayout?] = []
    private var highlightedLineIndex: Int?
    /// The position `highlight(position:)` last marked.
    private var highlightedPosition: TimeInterval?
    private var displayedLyrics: Lyrics?
    private var preferenceObservers: Set<AnyCancellable> = []

    override func awakeFromNib() {
        super.awakeFromNib()

        textView.doubleClickHandler = { [weak self] event in
            self?.handleDoubleClick(with: event)
        }
        textView.contextMenuProvider = { [weak self] _ in
            guard let menu = self?.lyricsViewDelegate?.lyricsViewContextMenu(), !menu.items.isEmpty else {
                return nil
            }
            return menu
        }
        defaults.publisher(for: [
            .preferredLyricsTranslationLanguage,
            .preferBilingualLyrics,
            .chineseConversionIndex,
        ])
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in
            guard let self else { return }
            setupTextContents(lyrics: displayedLyrics)
        }
        .store(in: &preferenceObservers)
    }

    func setupTextContents(lyrics: Lyrics?) {
        displayedLyrics = lyrics
        textView.sungPart = nil
        highlightedLineIndex = nil
        highlightedPosition = nil
        guard let lyrics = lyrics else {
            ranges = []
            karaokeLines = []
            textView.string = ""
            return
        }

        var lrcContent = ""
        var newRanges: [(TimeInterval, NSRange)] = []
        var newKaraokeLines: [KaraokeLineLayout?] = []
        let enabledLrc = lyrics.lines.filter { $0.enabled && !$0.content.isEmpty }
        let languageCode = lyrics.displayTranslationLanguage

        for line in enabledLrc {
            var lineStr = line.content
            if var trans = lyrics.displayTranslation(for: line), defaults[.preferBilingualLyrics],
               languageCode?.hasPrefix("zh") == true {
                if let converter = ChineseConverter.shared {
                    trans = converter.convert(trans)
                }
                lineStr += "\n" + trans
            }
            let range = NSRange(location: lrcContent.utf16.count, length: lineStr.utf16.count)
            newRanges.append((line.position, range))
            newKaraokeLines.append(KaraokeLineLayout(line: line))
            lrcContent += lineStr
            if line != enabledLrc.last {
                lrcContent += "\n\n"
            }
        }
        ranges = newRanges
        karaokeLines = newKaraokeLines
        textView.string = lrcContent
        let range = textView.string.fullRange
        let font = resolvedFont
        let style = NSMutableParagraphStyle().with {
            $0.alignment = .center
        }
        textView.textStorage?.addAttributes([
            .foregroundColor: textColor,
            .paragraphStyle: style,
            .font: font,
        ], range: range)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        updateFadeEdgeMask()
        updateEdgeInset()
        // A new width wraps the lines anew, and the sung part with them.
        updateSungPart()
    }

    override func mouseUp(with event: NSEvent) {
        guard event.clickCount == 2 else {
            super.mouseUp(with: event)
            return
        }

        handleDoubleClick(with: event)
    }

    private func handleDoubleClick(with event: NSEvent) {
        let clickPoint = textView.convert(event.locationInWindow, from: nil)
        let clickRange = ranges.filter { _, range in
            let bounding = textView.layoutManager!.boundingRect(forGlyphRange: range, in: textView.textContainer!)
            return bounding.contains(clickPoint)
        }
        if let (position, _) = clickRange.first {
            lyricsViewDelegate?.doubleClickLyricsLine(at: position)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = lyricsViewDelegate?.lyricsViewContextMenu(), !menu.items.isEmpty else {
            super.rightMouseDown(with: event)
            return
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        switch event.momentumPhase {
        case .began:
            lyricsViewDelegate?.scrollWheelDidStartScroll()
        case .ended,
             .cancelled:
            lyricsViewDelegate?.scrollWheelDidEndScroll()
        default:
            break
        }
    }

    // overriding scrollwheel method breaks trackpad responsive scrolling ability
    override class var isCompatibleWithResponsiveScrolling: Bool {
        return true
    }

    private func updateFadeEdgeMask() {
        let location = fadeStripWidth / frame.height
        wantsLayer = true
        layer?.mask = CAGradientLayer().then {
            $0.frame = bounds
            $0.colors = [#colorLiteral(red: 0, green: 0, blue: 0, alpha: 0), #colorLiteral(red: 0, green: 0, blue: 0, alpha: 1), #colorLiteral(red: 0, green: 0, blue: 0, alpha: 1), #colorLiteral(red: 0, green: 0, blue: 0, alpha: 0)] as [CGColor]
            $0.locations = [0, location as NSNumber, (1 - location) as NSNumber, 1]
            $0.startPoint = .zero
            $0.endPoint = CGPoint(x: 0, y: 1)
        }
    }

    private func updateEdgeInset() {
        guard !ranges.isEmpty else {
            return
        }

        let bounding1 = textView.layoutManager!.boundingRect(forGlyphRange: ranges.first!.1, in: textView.textContainer!)
        let topInset = frame.height / 2 - bounding1.height / 2
        let bounding2 = textView.layoutManager!.boundingRect(forGlyphRange: ranges.last!.1, in: textView.textContainer!)
        let bottomInset = frame.height / 2 - bounding2.height / 2
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsets(top: topInset, left: 0, bottom: bottomInset, right: 0)
    }

    /// Marks the line playing at `position` and, with
    /// `karaokeUnsungTextColor` set, how much of it is sung. Returns whether
    /// the mark moved to another line.
    @discardableResult
    func highlight(position: TimeInterval) -> Bool {
        guard !ranges.isEmpty else {
            return false
        }
        let lineIndex = indexOfLine(at: position)
        let marksAnotherLine = highlightedLineIndex != lineIndex
        if marksAnotherLine {
            if let highlightedLineIndex, ranges.indices.contains(highlightedLineIndex) {
                textView.textStorage?.addAttribute(.foregroundColor, value: textColor, range: ranges[highlightedLineIndex].1)
            }
            highlightedLineIndex = lineIndex
            paintHighlightedLine()
        }
        highlightedPosition = position
        updateSungPart()
        return marksAnotherLine
    }

    /// Whether the sung part of the line playing at `position` is moving
    /// then — between the first and the last of its line's keyframes — so
    /// that `highlight(position:)` draws something new on every frame.
    func karaokeProgressMoves(at position: TimeInterval) -> Bool {
        guard let movingLyricsTimes = karaokeLineShowingProgress(at: position)?.timing.movingLyricsTimes else {
            return false
        }
        return movingLyricsTimes.lowerBound <= position && position < movingLyricsTimes.upperBound
    }

    /// The position after `position` at which `highlight(position:)` marks
    /// something new: the start of the next line or, with karaoke progress,
    /// the moment the sung part of this one starts moving, whichever comes
    /// first. Nil once neither is left.
    func nextHighlightChange(after position: TimeInterval) -> TimeInterval? {
        guard !ranges.isEmpty else {
            return nil
        }
        let lineIndex = indexOfLine(at: position)
        let nextLineStart = ranges.indices.contains(lineIndex + 1) ? ranges[lineIndex + 1].0 : nil
        let karaokeProgressStart = karaokeLineShowingProgress(at: position)?.timing.movingLyricsTimes.lowerBound
        // Only what lies ahead: lines out of order must not ask for a check
        // that is already due, again and again.
        return [nextLineStart, karaokeProgressStart]
            .compactMap { $0 }
            .filter { $0 > position }
            .min()
    }

    /// The karaoke layout of the line playing at `position`, when it shows
    /// karaoke progress.
    private func karaokeLineShowingProgress(at position: TimeInterval) -> KaraokeLineLayout? {
        guard karaokeUnsungTextColor != nil, !ranges.isEmpty else {
            return nil
        }
        return karaokeLines[indexOfLine(at: position)]
    }

    func scroll(position: TimeInterval) {
        guard !ranges.isEmpty else {
            return
        }
        let range = ranges[indexOfLine(at: position)].1

        let bounding = textView.layoutManager!.boundingRect(forGlyphRange: range, in: textView.textContainer!)

        let point = NSPoint(x: 0, y: bounding.midY - frame.height / 2)
        textView.scroll(point)
    }

    /// The last line starting at or before `position`, or the first line
    /// before it starts.
    private func indexOfLine(at position: TimeInterval) -> Int {
        var left = ranges.startIndex
        var right = ranges.endIndex - 1
        while left <= right {
            let mid = (left + right) / 2
            if ranges[mid].0 <= position {
                left = mid + 1
            } else {
                right = mid - 1
            }
        }
        return right.clamped(to: ranges.indices)
    }

    /// Colours the marked line: all of it in `highlightColor` or, with karaoke
    /// progress, in `karaokeUnsungTextColor` — the sung part is drawn over it.
    private func paintHighlightedLine() {
        guard let highlightedLineIndex, ranges.indices.contains(highlightedLineIndex),
              let textStorage = textView.textStorage else {
            return
        }
        let color = karaokeLines[highlightedLineIndex] != nil ? karaokeUnsungTextColor ?? highlightColor : highlightColor
        textStorage.addAttribute(.foregroundColor, value: color, range: ranges[highlightedLineIndex].1)
    }

    /// Puts the sung part of the marked line where `highlightedPosition` has
    /// it: every line fragment sung through, and the one being sung up to
    /// the share of its character sung so far, in whole device pixels — the
    /// menu bar's karaoke progress, drawn the same way.
    private func updateSungPart() {
        textView.sungPart = sungPartOfHighlightedLine()
    }

    private func sungPartOfHighlightedLine() -> LyricsTextView.SungPart? {
        guard karaokeUnsungTextColor != nil,
              let highlightedLineIndex, let highlightedPosition,
              ranges.indices.contains(highlightedLineIndex),
              let karaokeLine = karaokeLines[highlightedLineIndex],
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return nil
        }
        let characterBoundaries = karaokeLine.characterBoundaries
        let characterCount = characterBoundaries.count - 1
        let sungCharacterCount = min(max(0, karaokeLine.timing.sungCharacterCount(atLyricsTime: highlightedPosition)), Double(characterCount))
        guard sungCharacterCount > 0 else {
            return nil
        }
        let lineLocation = ranges[highlightedLineIndex].1.location
        let contentGlyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: lineLocation, length: characterBoundaries[characterCount]),
            actualCharacterRange: nil
        )
        // Where the sung part ends: a share of the character being sung, or
        // nowhere short of the line's end once every character is.
        var sungEdge: (glyphIndex: Int, x: CGFloat)?
        let edgeCharacterIndex = Int(sungCharacterCount.rounded(.down))
        if edgeCharacterIndex < characterCount {
            let characterShare = CGFloat(sungCharacterCount - Double(edgeCharacterIndex))
            let characterRange = NSRange(
                location: lineLocation + characterBoundaries[edgeCharacterIndex],
                length: characterBoundaries[edgeCharacterIndex + 1] - characterBoundaries[edgeCharacterIndex]
            )
            let characterGlyphRange = layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
            let characterExtent = horizontalExtent(of: characterRange, glyphRange: characterGlyphRange, layoutManager: layoutManager, textContainer: textContainer)
            sungEdge = (characterGlyphRange.location, characterExtent.start + (characterExtent.end - characterExtent.start) * characterShare)
        }
        var sungRects: [NSRect] = []
        layoutManager.enumerateLineFragments(forGlyphRange: contentGlyphRange) { fragmentRect, _, _, fragmentGlyphRange, stop in
            guard let sungEdge, sungEdge.glyphIndex < NSMaxRange(fragmentGlyphRange) else {
                sungRects.append(fragmentRect)
                return
            }
            sungRects.append(NSRect(
                x: fragmentRect.minX,
                y: fragmentRect.minY,
                width: max(0, sungEdge.x - fragmentRect.minX),
                height: fragmentRect.height
            ))
            stop.pointee = true
        }
        let containerOrigin = textView.textContainerOrigin
        let scale = window?.backingScaleFactor ?? 2
        let viewRects = sungRects.map { (containerRect: NSRect) -> NSRect in
            let rect = containerRect.offsetBy(dx: containerOrigin.x, dy: containerOrigin.y)
            let snappedMaxX = (rect.maxX * scale).rounded() / scale
            return NSRect(x: rect.minX, y: rect.minY, width: max(0, snappedMaxX - rect.minX), height: rect.height)
        }
        .filter { $0.width > 0 }
        guard !viewRects.isEmpty else {
            return nil
        }
        return LyricsTextView.SungPart(glyphRange: contentGlyphRange, rects: viewRects, color: highlightColor)
    }

    /// Where the characters in `characterRange` start and end along their
    /// line, in the text container's coordinates. Read from the caret
    /// positions, which split a ligature — "fi" — between the characters it
    /// joins, where their glyphs' bounds would give both the whole ligature
    /// and send the sung edge back to its start.
    private func horizontalExtent(
        of characterRange: NSRange,
        glyphRange: NSRange,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> (start: CGFloat, end: CGFloat) {
        let glyphBounds = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        guard glyphRange.length > 0 else {
            return (glyphBounds.minX, glyphBounds.maxX)
        }
        let fragmentRect = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
        let insertionPointCount = layoutManager.getLineFragmentInsertionPoints(
            forCharacterAt: characterRange.location,
            alternatePositions: false,
            inDisplayOrder: false,
            positions: nil,
            characterIndexes: nil
        )
        var positions = [CGFloat](repeating: 0, count: insertionPointCount)
        var characterIndexes = [Int](repeating: 0, count: insertionPointCount)
        _ = layoutManager.getLineFragmentInsertionPoints(
            forCharacterAt: characterRange.location,
            alternatePositions: false,
            inDisplayOrder: false,
            positions: &positions,
            characterIndexes: &characterIndexes
        )
        func caretPosition(before characterIndex: Int) -> CGFloat? {
            characterIndexes.firstIndex(of: characterIndex).map { fragmentRect.minX + positions[$0] }
        }
        // The caret after the character is on the next line when the line
        // wraps right after it; the glyphs' bounds end it there instead.
        let start = caretPosition(before: characterRange.location) ?? glyphBounds.minX
        let end = caretPosition(before: NSMaxRange(characterRange)) ?? glyphBounds.maxX
        return end > start ? (start, end) : (glyphBounds.minX, glyphBounds.maxX)
    }

    func updateFont() {
        let range = textView.string.fullRange
        textView.textStorage?.addAttribute(.font, value: resolvedFont, range: range)
        updateSungPart()
    }
}

/// A line's karaoke timing, with where each of its characters starts in the
/// text view's string, to draw the part sung so far.
private struct KaraokeLineLayout {
    let timing: KaraokeLineTiming
    /// The UTF-16 offset from the line's start of each of its characters —
    /// Swift `Character`s, which the timing counts — and of its end.
    let characterBoundaries: [Int]

    /// Nil for a line without inline time tags, and for one with any
    /// right-to-left run, as in the menu bar: the sung part fills from the
    /// leading edge, so a Hebrew line would start out sung and empty as it
    /// was sung.
    init?(line: LyricsLine) {
        guard let timing = KaraokeLineTiming(line: line), Self.runsLeftToRight(line.content) else {
            return nil
        }
        var boundary = 0
        self.timing = timing
        self.characterBoundaries = [0] + line.content.map { character in
            boundary += character.utf16.count
            return boundary
        }
    }

    private static func runsLeftToRight(_ content: String) -> Bool {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: content))
        let glyphRuns = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        return glyphRuns.allSatisfy { !CTRunGetStatus($0).contains(.rightToLeft) }
    }
}
