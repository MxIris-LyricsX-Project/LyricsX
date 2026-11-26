import AppKit
import Combine
import LyricsXFoundation
import OpenCC

protocol ScrollLyricsViewDelegate: AnyObject {
    func doubleClickLyricsLine(at position: TimeInterval)
    func lyricsViewContextMenu() -> NSMenu
    func scrollWheelDidStartScroll()
    func scrollWheelDidEndScroll()
}

final class LyricsTextView: LyricsInteractionTextView {}

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
            }
        }
    }

    /// The colour of the part of the playing line not sung yet. Setting it
    /// turns on karaoke progress: on a line with inline time tags, each
    /// character takes `highlightColor` once its tag says it starts being
    /// sung, and the rest of the line this colour. Nil — the default — marks
    /// the whole line in `highlightColor`.
    var karaokeUnsungTextColor: NSColor? {
        didSet { paintHighlightedLine() }
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
    private var highlightedRange: NSRange?
    /// How much of `highlightedRange`, in UTF-16 units, is sung; nil when the
    /// marked line shows no karaoke progress.
    private var highlightedSungLength: Int?
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
        guard let lyrics = lyrics else {
            ranges = []
            karaokeLines = []
            textView.string = ""
            highlightedRange = nil
            highlightedSungLength = nil
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
        highlightedRange = nil
        highlightedSungLength = nil
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
    /// `karaokeUnsungTextColor` set, how much of it has started being sung.
    /// Returns whether the mark moved to another line.
    @discardableResult
    func highlight(position: TimeInterval) -> Bool {
        guard !ranges.isEmpty else {
            return false
        }
        let lineIndex = indexOfLine(at: position)
        let range = ranges[lineIndex].1
        let sungLength = karaokeUnsungTextColor == nil
            ? nil
            : karaokeLines[lineIndex]?.sungLength(atLyricsTime: position)
        let marksAnotherLine = highlightedRange != range
        guard marksAnotherLine || sungLength != highlightedSungLength else {
            return false
        }
        if marksAnotherLine, let highlightedRange {
            textView.textStorage?.addAttribute(.foregroundColor, value: textColor, range: highlightedRange)
        }
        highlightedRange = range
        highlightedSungLength = sungLength
        paintHighlightedLine()
        return marksAnotherLine
    }

    /// The position after `position` at which `highlight(position:)` marks
    /// something new: the start of the next line or, with karaoke progress,
    /// of the next character to be sung in this one, whichever comes first.
    /// Nil once neither is left.
    func nextHighlightChange(after position: TimeInterval) -> TimeInterval? {
        guard !ranges.isEmpty else {
            return nil
        }
        let lineIndex = indexOfLine(at: position)
        let nextLineStart = ranges.indices.contains(lineIndex + 1) ? ranges[lineIndex + 1].0 : nil
        let nextCharacterOnset = karaokeUnsungTextColor == nil
            ? nil
            : karaokeLines[lineIndex]?.onsets.nextOnset(afterLyricsTime: position)
        // Only what lies ahead: lines out of order must not ask for a check
        // that is already due, again and again.
        return [nextLineStart, nextCharacterOnset]
            .compactMap { $0 }
            .filter { $0 > position }
            .min()
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
    /// progress, its sung part in `highlightColor` and the rest in
    /// `karaokeUnsungTextColor`.
    private func paintHighlightedLine() {
        guard let highlightedRange, let textStorage = textView.textStorage else {
            return
        }
        if let highlightedSungLength, let karaokeUnsungTextColor {
            textStorage.addAttribute(.foregroundColor, value: karaokeUnsungTextColor, range: highlightedRange)
            let sungRange = NSRange(location: highlightedRange.location, length: highlightedSungLength)
            textStorage.addAttribute(.foregroundColor, value: highlightColor, range: sungRange)
        } else {
            textStorage.addAttribute(.foregroundColor, value: highlightColor, range: highlightedRange)
        }
    }

    func updateFont() {
        let range = textView.string.fullRange
        textView.textStorage?.addAttribute(.font, value: resolvedFont, range: range)
    }
}

/// A line's karaoke timing, with where each of its characters ends in the
/// text view's string, to colour the part sung so far.
private struct KaraokeLineLayout {
    let onsets: KaraokeCharacterOnsets
    /// The UTF-16 length of the line's first one, two, three… characters.
    let characterEndOffsets: [Int]

    init?(line: LyricsLine) {
        guard let onsets = KaraokeCharacterOnsets(line: line) else {
            return nil
        }
        var endOffset = 0
        self.onsets = onsets
        self.characterEndOffsets = line.content.map { character in
            endOffset += character.utf16.count
            return endOffset
        }
    }

    /// How much of the line, in UTF-16 units from its start, has started
    /// being sung at `lyricsTime`.
    func sungLength(atLyricsTime lyricsTime: TimeInterval) -> Int {
        let startedCharacterCount = onsets.startedCharacterCount(atLyricsTime: lyricsTime)
        return startedCharacterCount == 0 ? 0 : characterEndOffsets[startedCharacterCount - 1]
    }
}
