import AppKit
import CoreText
import QuartzCore

/// The menu bar's lyric line, drawn without an `NSTextField`.
///
/// Since macOS 26 the menu bar does not show a status item's own window. It
/// shows snapshots ("replicants") that AppKit renders whenever the item
/// changes, and every snapshot flips the item to the snapshot's appearance
/// and back. An `NSTextField` inside the item reacts to that flip by dirtying
/// the item again, which schedules the next snapshot: MarqueeLabel's text
/// field kept LyricsX at ~49% CPU on macOS 27.2 with nothing playing,
/// re-snapshotting the item about 300 times a second.
///
/// This control draws with `MenuBarMarqueeLabelCell`, an `NSTextFieldCell`
/// configured exactly as MarqueeLabel configures its field's, so its snapshot
/// is pixel-identical. It is an `NSControl` with that cell — what
/// `NSTextField` itself is — minus whatever `NSTextField` adds that answers
/// the flip: in the probes the plain control with the same cell never kept
/// the item re-snapshotting, so a line that is not moving costs nothing.
///
/// A line wider than the view scrolls with MarqueeLabel's timing: it rests,
/// moves at constant speed to its far end, and rests again, the moving part
/// taking the share of the line's time that the overflow takes of the text's
/// width. Each frame is a copy of a bitmap rendered once per appearance,
/// because every frame the line moves costs one snapshot round trip.
///
/// Given the line's karaoke timing, it also shows how much of the line has
/// been sung: the sung part in `sungTextColor` — the accent colour unless
/// set — the rest as before, the edge between them moving with playback.
/// That edge costs what scrolling does — every step is a snapshot round
/// trip — so it moves in whole device pixels, only when it reaches the next
/// one, and no faster than scrolling.
///
/// Only macOS 26 and later need it, so that is all it supports.
@available(macOS 26, *)
public final class MenuBarMarqueeLabel: NSControl {
    public override class var cellClass: AnyClass? {
        get { MenuBarMarqueeLabelCell.self }
        set {}
    }

    /// What MarqueeLabel's animation reaches on a 60 Hz display, where it
    /// moves its field one whole point per frame. Thirty looked visibly
    /// choppy; following a 120 Hz display doubles the cost for motion few
    /// would tell apart.
    public static let defaultMaximumScrollFramesPerSecond: Double = 60

    /// The most frames a second a scrolling line, or its karaoke progress,
    /// moves at; zero or less means `defaultMaximumScrollFramesPerSecond`,
    /// and anything above the display's refresh rate follows the display.
    /// Every frame the line moves costs a replicant snapshot round trip of
    /// the whole status item, so this — not how the text is drawn — is what
    /// moving costs: a cap trades smoothness for CPU.
    public var maximumScrollFramesPerSecond: Double = 0 {
        didSet {
            if maximumScrollFramesPerSecond != oldValue {
                updateMotion()
            }
        }
    }

    private static let fallbackLineDisplayTime: TimeInterval = 5

    /// How far a lyrics time given again for the same line may be from the
    /// view's own clock and still be taken as the same moment. The
    /// controller re-sends the line on every app activation with a position
    /// freshly read from the player, which wobbles by a few hundredths;
    /// re-anchoring on that wobble restarted the display link and nudged
    /// the edge back and forth. A pause, a resume or a jump moves further.
    private static let karaokeReanchorTolerance: TimeInterval = 0.1

    /// The colour the sung part of a line is drawn in; `nil`, the default,
    /// follows the system accent colour.
    public var sungTextColor: NSColor? {
        didSet {
            guard sungTextColor != oldValue else { return }
            discardSungBitmaps()
        }
    }

    private var resolvedSungTextColor: NSColor {
        sungTextColor ?? .controlAccentColor
    }

    private struct BitmapKey: Hashable {
        let appearanceName: NSAppearance.Name
        let scale: CGFloat
        let colorSpaceName: String
        /// Drawn in `resolvedSungTextColor` rather than the cell's own colour.
        let isSung: Bool
    }

    private var lineDisplayTime = MenuBarMarqueeLabel.fallbackLineDisplayTime
    /// What MarqueeLabel's `sizeToFit` makes its field for the current line.
    package private(set) var fieldSize = NSSize.zero
    /// One bitmap per appearance: every snapshot flips the appearance and
    /// back, so a single entry would be re-rendered twice per snapshot. A
    /// line with karaoke progress keeps a sung one per appearance as well.
    private var cachedBitmaps: [BitmapKey: CGImage] = [:]

    private var lineStartTime: CFTimeInterval = 0
    private var pausedTime: CFTimeInterval?
    private var isScreenAsleep = false
    /// Wakes the view when the line, or its karaoke progress, starts moving.
    private var restTimer: Timer?
    /// Moves the line and its karaoke progress, in step with the screen's
    /// refresh, while either is moving.
    private var displayLink: CADisplayLink?
    /// Each observer with the centre it was added to.
    private var notificationObservers: [(notificationCenter: NotificationCenter, observer: NSObjectProtocol)] = []

    private var karaokeTiming: KaraokeLineTiming?
    /// The lyrics time `setKaraokeTiming(_:lyricsTime:)` was last given, and
    /// the clock's time then — or, while paused, the time playback paused.
    private var karaokeAnchorLyricsTime: TimeInterval = 0
    private var karaokeAnchorClockTime: CFTimeInterval = 0

    /// Where the text's frame starts while a line wider than the view is
    /// scrolling: zero at rest, negative while moving.
    package private(set) var scrollPosition: CGFloat = 0 {
        didSet {
            if scrollPosition != oldValue {
                needsDisplay = true
                scrollPositionObserver?(scrollPosition)
            }
        }
    }

    /// How far into the text's frame the sung part reaches, in whole device
    /// pixels; `nil` when the line shows no karaoke progress.
    package private(set) var sungWidth: CGFloat? {
        didSet {
            if sungWidth != oldValue {
                needsDisplay = true
                sungWidthObserver?(sungWidth)
            }
        }
    }

    /// Where each character of the current line starts in the text's frame,
    /// and finally where its last one ends: the karaoke progress after `n`
    /// characters reaches `characterBoundaries[n]`.
    package private(set) var characterBoundaries: [CGFloat] = []

    /// The clock the scroll and karaoke timing read. Probes replace it to
    /// place the line at an exact moment.
    package var clock: () -> CFTimeInterval = CACurrentMediaTime

    /// Called on every draw. Probes count with it.
    package var drawingObserver: (() -> Void)?

    /// Called whenever the scroll position changes. Probes measure the motion
    /// with it.
    package var scrollPositionObserver: ((CGFloat) -> Void)?

    /// Called whenever the sung width changes. Probes measure the karaoke
    /// progress with it.
    package var sungWidthObserver: ((CGFloat?) -> Void)?

    /// Called whenever the view re-evaluates its motion, which stops and
    /// restarts its display link or timer. Probes count with it.
    package var motionUpdateObserver: (() -> Void)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Setting it shows a new line for the current line's duration; see
    /// `setStringValue(_:lineDisplayTime:)`.
    public override var stringValue: String {
        get { super.stringValue }
        set { setStringValue(newValue, lineDisplayTime: lineDisplayTime) }
    }

    /// Shows `value` for a line that lasts `lineDisplayTime` seconds.
    ///
    /// An empty `value` is ignored and the previous line stays, as with
    /// MarqueeLabel. Calling again with the same line and duration does not
    /// restart its scrolling — the controller re-sends the current line
    /// whenever another app becomes active. A new `value` drops the karaoke
    /// progress, which belonged to the line before.
    public func setStringValue(_ value: String, lineDisplayTime: TimeInterval) {
        guard !value.isEmpty else { return }
        let duration = lineDisplayTime.isFinite && lineDisplayTime > 0 ? lineDisplayTime : Self.fallbackLineDisplayTime
        guard value != super.stringValue || duration != self.lineDisplayTime else { return }
        if value != super.stringValue {
            karaokeTiming = nil
        }
        super.stringValue = value
        self.lineDisplayTime = duration
        setAccessibilityValue(value)
        updateFieldSize()
        restartLine()
        needsDisplay = true
        updateMotion()
    }

    /// Shows the karaoke progress of the current line: `timing` as it stands
    /// at `lyricsTime`, the playback position at this moment with the lyrics'
    /// offset applied. `nil` shows the line without progress.
    ///
    /// The progress then moves on with the view's own clock, and stops while
    /// playback is paused; call again whenever playback jumps. A timing for
    /// a different line than the one before — the same text sung again —
    /// also starts the line's scrolling over, or the progress of a long line
    /// would begin past the view's leading edge.
    public func setKaraokeTiming(_ timing: KaraokeLineTiming?, lyricsTime: TimeInterval) {
        // The controller sends the line again on every app activation, with
        // the switch off too: no progress then and now, or the same progress
        // at the moment the clock already shows, changes nothing, and must
        // not restart a scrolling line's display link.
        guard timing != nil || karaokeTiming != nil else { return }
        if let karaokeTiming, timing == karaokeTiming,
           abs(lyricsTime - currentLyricsTime) < Self.karaokeReanchorTolerance {
            return
        }
        if let previousTiming = karaokeTiming, let timing, previousTiming != timing {
            restartLine()
        }
        karaokeTiming = timing
        karaokeAnchorLyricsTime = lyricsTime.isFinite ? lyricsTime : 0
        karaokeAnchorClockTime = pausedTime ?? clock()
        updateMotion()
    }

    /// Freezes a scrolling line and its karaoke progress while playback is
    /// paused, and resumes them from the same place.
    public func setPlaybackPaused(_ isPaused: Bool) {
        if isPaused, pausedTime == nil {
            pausedTime = clock()
        } else if !isPaused, let pausedTime {
            let pauseDuration = clock() - pausedTime
            lineStartTime += pauseDuration
            karaokeAnchorClockTime += pauseDuration
            self.pausedTime = nil
        }
        updateMotion()
    }

    /// Starts the line's scroll timing from now.
    private func restartLine() {
        lineStartTime = clock()
        if pausedTime != nil {
            pausedTime = lineStartTime
        }
    }

    // MARK: - Layout

    public override func setFrameSize(_ newSize: NSSize) {
        guard newSize != frame.size else { return }
        super.setFrameSize(newSize)
        updateMotion()
        needsDisplay = true
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopObservingNotifications()
        } else {
            startObservingNotifications()
        }
        updateMotion()
    }

    public override func viewDidHide() {
        super.viewDidHide()
        updateMotion()
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        updateMotion()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // The field size is aligned to the old screen's pixels.
        updateFieldSize()
        updateMotion()
    }

    /// Clicks belong to the status item's button, which tracks its menu.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        drawingObserver?()
        guard let context = NSGraphicsContext.current?.cgContext, !stringValue.isEmpty else { return }
        let scale = Self.deviceScale(of: context)
        // The window's colour space, not the context's. `context.colorSpace`
        // is CGBitmapContextGetColorSpace, and only the replicant snapshot
        // draws into a bitmap context, in the window's colour space; the
        // other draws of a status item go to a display list, where it logged
        // "invalid context" each time — hundreds of lines a second while the
        // line moved.
        let colorSpace = window?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let appearanceName = NSAppearance.currentDrawing().name
        let colorSpaceName = (colorSpace.name as String?) ?? "unnamed"
        func bitmapKey(isSung: Bool) -> BitmapKey {
            BitmapKey(appearanceName: appearanceName, scale: scale, colorSpaceName: colorSpaceName, isSung: isSung)
        }
        guard let bitmap = textBitmap(for: bitmapKey(isSung: false), colorSpace: colorSpace) else { return }
        let frame = textFrame
        // Positions are whole device pixels, so this is a plain copy. A
        // fractional position would make every one of the six draws a frame
        // costs resample the bitmap in software: at display rate that alone
        // more than doubled the CPU, for motion no smoother than
        // MarqueeLabel's, which moves in whole points.
        context.saveGState()
        context.interpolationQuality = .none
        if let sungWidth, sungWidth > 0, let sungBitmap = textBitmap(for: bitmapKey(isSung: true), colorSpace: colorSpace) {
            // The sung width is whole device pixels too, so each part is a
            // copy of its own bitmap cut at a pixel edge: no pixel is blended
            // from both.
            let sungEdge = frame.minX + min(sungWidth, frame.width)
            context.saveGState()
            context.clip(to: NSRect(x: frame.minX, y: frame.minY, width: sungEdge - frame.minX, height: frame.height))
            context.draw(sungBitmap, in: frame)
            context.restoreGState()
            if sungEdge < frame.maxX {
                context.clip(to: NSRect(x: sungEdge, y: frame.minY, width: frame.maxX - sungEdge, height: frame.height))
                context.draw(bitmap, in: frame)
            }
        } else {
            context.draw(bitmap, in: frame)
        }
        context.restoreGState()
    }

    /// Where MarqueeLabel's `-layoutTextField` puts its field: centred
    /// vertically (rounded up), centred horizontally when it fits, otherwise
    /// at the scroll position.
    package var textFrame: NSRect {
        let originY = ((bounds.height - fieldSize.height) * 0.5).rounded(.up)
        let originX = fieldSize.width <= bounds.width
            ? ((bounds.width - fieldSize.width) * 0.5).rounded()
            : scrollPosition
        return NSRect(x: originX, y: originY, width: fieldSize.width, height: fieldSize.height)
    }

    /// The cell `cellClass` gave this control, already set up the way
    /// MarqueeLabel set up its field.
    private var textCell: MenuBarMarqueeLabelCell? {
        cell as? MenuBarMarqueeLabelCell
    }

    /// What `sizeToFit` gives the field: the cell size grown outward to whole
    /// device pixels. Half a point too narrow truncates the line; half a
    /// point too wide shows more of an overhanging glyph — a colour emoji at
    /// the end of a line — than MarqueeLabel's field, which clips at its
    /// frame.
    private func updateFieldSize() {
        guard let textCell, !stringValue.isEmpty else { return }
        fieldSize = backingAlignedRect(NSRect(origin: .zero, size: textCell.cellSize), options: .alignAllEdgesOutward).size
        cachedBitmaps.removeAll()
        updateCharacterBoundaries()
    }

    /// Lays the line out the way the cell draws it — its attributed string on
    /// one line, inset by the cell's text padding — and records where each
    /// character starts.
    ///
    /// The progress fills from the leading edge, so it only fits a line
    /// whose characters run left to right. A line with any right-to-left
    /// run gets no boundaries and shows no progress: filled from the left, a
    /// Hebrew line started out fully sung and emptied as it was sung. The
    /// runs' direction is what tells, not the order of the boundaries — a
    /// single Hebrew letter in an English line keeps them in order, its own
    /// width folded into the space before it.
    private func updateCharacterBoundaries() {
        guard let textCell, !stringValue.isEmpty else {
            characterBoundaries = []
            return
        }
        let attributedText = textCell.attributedStringValue
        let text = attributedText.string
        let line = CTLineCreateWithAttributedString(attributedText)
        let textOrigin = textCell.titleRect(forBounds: NSRect(origin: .zero, size: fieldSize)).minX
            + MenuBarMarqueeLabelCell.horizontalTextPadding
        let boundaries = (Array(text.indices) + [text.endIndex]).map { characterIndex in
            textOrigin + CTLineGetOffsetForStringIndex(line, characterIndex.utf16Offset(in: text), nil)
        }
        let glyphRuns = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        let runsLeftToRight = glyphRuns.allSatisfy { !CTRunGetStatus($0).contains(.rightToLeft) }
        characterBoundaries = runsLeftToRight ? boundaries : []
    }

    private func textBitmap(for key: BitmapKey, colorSpace: CGColorSpace) -> CGImage? {
        if cachedBitmaps[key] == nil {
            cachedBitmaps[key] = renderTextBitmap(scale: key.scale, colorSpace: colorSpace, textColor: key.isSung ? resolvedSungTextColor : nil)
        }
        return cachedBitmaps[key]
    }

    /// The line drawn by the cell — or, given `textColor`, by a copy of the
    /// cell in that colour, which leaves every other setting as it is.
    private func renderTextBitmap(scale: CGFloat, colorSpace: CGColorSpace, textColor: NSColor?) -> CGImage? {
        guard let textCell else { return nil }
        let drawingCell: NSTextFieldCell
        if let textColor, let recolouredCell = textCell.copy() as? NSTextFieldCell {
            recolouredCell.textColor = textColor
            drawingCell = recolouredCell
        } else {
            drawingCell = textCell
        }
        // Exactly the field's frame: in a running app the text field's layer
        // clips a glyph that overhangs it — a colour emoji at the end of a
        // line does — and so does this bitmap.
        let pixelWidth = Int((fieldSize.width * scale).rounded(.up))
        let pixelHeight = Int((fieldSize.height * scale).rounded(.up))
        guard pixelWidth > 0, pixelHeight > 0,
              let bitmapContext = CGContext(
                  data: nil,
                  width: pixelWidth,
                  height: pixelHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        bitmapContext.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmapContext, flipped: false)
        drawingCell.draw(withFrame: NSRect(origin: .zero, size: fieldSize), in: self)
        NSGraphicsContext.restoreGraphicsState()
        return bitmapContext.makeImage()
    }

    private static func deviceScale(of context: CGContext) -> CGFloat {
        let transform = context.userSpaceToDeviceSpaceTransform
        return max(1, (transform.a * transform.a + transform.b * transform.b).squareRoot())
    }

    // MARK: - Scrolling

    private struct ScrollPlan {
        let travel: CGFloat
        let restDuration: TimeInterval
        let movingDuration: TimeInterval

        /// MarqueeLabel's split of the line's time: the moving part is the
        /// overflow's share of the text width, the rest is split evenly
        /// before and after.
        init(fieldWidth: CGFloat, visibleWidth: CGFloat, lineDisplayTime: TimeInterval) {
            self.travel = max(0, fieldWidth - visibleWidth)
            self.movingDuration = fieldWidth > 0 ? lineDisplayTime * Double(travel / fieldWidth) : 0
            self.restDuration = (lineDisplayTime - movingDuration) / 2
        }

        func position(at elapsed: TimeInterval) -> CGFloat {
            guard travel > 0, movingDuration > 0 else { return 0 }
            let progress = min(1, max(0, (elapsed - restDuration) / movingDuration))
            return -travel * CGFloat(progress)
        }

        func isMoving(at elapsed: TimeInterval) -> Bool {
            travel > 0 && elapsed >= restDuration && elapsed < restDuration + movingDuration
        }
    }

    private var scrollPlan: ScrollPlan {
        ScrollPlan(fieldWidth: fieldSize.width, visibleWidth: bounds.width, lineDisplayTime: lineDisplayTime)
    }

    // MARK: - Karaoke progress

    /// The lyrics time now, as the last anchor and the clock since tell it;
    /// stopped while paused.
    private var currentLyricsTime: TimeInterval {
        karaokeAnchorLyricsTime + ((pausedTime ?? clock()) - karaokeAnchorClockTime)
    }

    /// How far the sung part reaches at `lyricsTime`: nothing before the
    /// first character, the whole frame once the last one is sung, and in
    /// between the share of each character sung so far.
    private func sungWidth(atLyricsTime lyricsTime: TimeInterval) -> CGFloat? {
        guard let karaokeTiming, let lastBoundaryIndex = characterBoundaries.indices.last, lastBoundaryIndex > 0 else {
            return nil
        }
        let sungCharacterCount = min(max(0, karaokeTiming.sungCharacterCount(atLyricsTime: lyricsTime)), Double(lastBoundaryIndex))
        if sungCharacterCount <= 0 {
            return 0
        }
        if sungCharacterCount >= Double(lastBoundaryIndex) {
            // A glyph that overhangs the end of the line is sung too.
            return fieldSize.width
        }
        let characterIndex = Int(sungCharacterCount.rounded(.down))
        let characterShare = CGFloat(sungCharacterCount - Double(characterIndex))
        let characterStart = characterBoundaries[characterIndex]
        let characterEnd = characterBoundaries[characterIndex + 1]
        return snappedToDevicePixels(characterStart + (characterEnd - characterStart) * characterShare)
    }

    // MARK: - Motion

    /// Puts the line and its karaoke progress where the clock has them, and
    /// keeps them moving: the display link while either moves, otherwise a
    /// one-off timer for whichever starts moving first.
    private func updateMotion() {
        motionUpdateObserver?()
        stopMotionClocks()
        let plan = scrollPlan
        let elapsed = (pausedTime ?? clock()) - lineStartTime
        let lyricsTime = currentLyricsTime
        scrollPosition = snappedToDevicePixels(plan.position(at: elapsed))
        sungWidth = sungWidth(atLyricsTime: lyricsTime)

        guard pausedTime == nil, !isScreenAsleep, window != nil, !isHiddenOrHasHiddenAncestor else {
            return
        }
        var needsDisplayLink = plan.isMoving(at: elapsed)
        var secondsUntilMoving: TimeInterval?
        if plan.travel > 0, elapsed < plan.restDuration {
            secondsUntilMoving = plan.restDuration - elapsed
        }
        if let karaokeTiming, sungWidth != nil {
            let movingLyricsTimes = karaokeTiming.movingLyricsTimes
            if lyricsTime < movingLyricsTimes.lowerBound {
                secondsUntilMoving = min(secondsUntilMoving ?? .infinity, movingLyricsTimes.lowerBound - lyricsTime)
            } else if lyricsTime < movingLyricsTimes.upperBound {
                needsDisplayLink = true
            }
        }
        if needsDisplayLink {
            startDisplayLink()
        } else if let secondsUntilMoving {
            let timer = Timer(timeInterval: secondsUntilMoving, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateMotion() }
            }
            // Common modes, so the line keeps moving while a menu is open.
            RunLoop.main.add(timer, forMode: .common)
            restTimer = timer
        }
    }

    /// The screen's display link rather than the view's: the status item's
    /// window is not a real on-screen window on macOS 26 and later.
    private func startDisplayLink() {
        guard let screen = window?.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let displayLink = screen.displayLink(target: self, selector: #selector(displayLinkDidFire(_:)))
        let framesPerSecond = Float(maximumScrollFramesPerSecond > 0 ? maximumScrollFramesPerSecond : Self.defaultMaximumScrollFramesPerSecond)
        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: framesPerSecond,
            maximum: framesPerSecond,
            preferred: framesPerSecond
        )
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    private func stopMotionClocks() {
        restTimer?.invalidate()
        restTimer = nil
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func displayLinkDidFire(_ displayLink: CADisplayLink) {
        advanceMotion()
    }

    private func advanceMotion() {
        let plan = scrollPlan
        let elapsed = clock() - lineStartTime
        let lyricsTime = currentLyricsTime
        scrollPosition = snappedToDevicePixels(plan.position(at: elapsed))
        sungWidth = sungWidth(atLyricsTime: lyricsTime)
        let karaokeIsMoving = karaokeTiming.map { sungWidth != nil && $0.movingLyricsTimes.contains(lyricsTime) } ?? false
        if !plan.isMoving(at: elapsed), !karaokeIsMoving {
            // Whatever moved has stopped: wait for the next thing to move, or
            // for nothing.
            updateMotion()
        }
    }

    /// Whole device pixels — half points on Retina, finer than the whole
    /// points MarqueeLabel's animated frame moves by.
    private func snappedToDevicePixels(_ position: CGFloat) -> CGFloat {
        let scale = window?.backingScaleFactor ?? 2
        return (position * scale).rounded() / scale
    }

    // MARK: - Notifications

    private func startObservingNotifications() {
        guard notificationObservers.isEmpty else { return }
        let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
        notificationObservers = [
            (workspaceNotificationCenter, workspaceNotificationCenter.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setScreenAsleep(true) }
            }),
            (workspaceNotificationCenter, workspaceNotificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setScreenAsleep(false) }
            }),
            // The accent colour is a system setting; the sung bitmaps were
            // drawn in the old one.
            (NotificationCenter.default, NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemColorsDidChange() }
            }),
        ]
    }

    private func stopObservingNotifications() {
        for (notificationCenter, observer) in notificationObservers {
            notificationCenter.removeObserver(observer)
        }
        notificationObservers = []
    }

    private func setScreenAsleep(_ isAsleep: Bool) {
        isScreenAsleep = isAsleep
        updateMotion()
    }

    private func systemColorsDidChange() {
        // A custom colour is not the accent colour, but it may be a system
        // colour that follows the same settings.
        discardSungBitmaps()
    }

    /// Drops the sung bitmaps, drawn in a colour that no longer applies.
    private func discardSungBitmaps() {
        cachedBitmaps = cachedBitmaps.filter { !$0.key.isSung }
        if sungWidth != nil {
            needsDisplay = true
        }
    }
}
