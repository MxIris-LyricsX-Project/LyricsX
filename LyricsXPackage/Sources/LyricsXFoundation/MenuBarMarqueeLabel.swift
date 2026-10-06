import AppKit
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

    /// The most frames a second a scrolling line moves at; zero or less means
    /// `defaultMaximumScrollFramesPerSecond`, and anything above the
    /// display's refresh rate follows the display. Every frame the line moves
    /// costs a replicant snapshot round trip of the whole status item, so
    /// this — not how the text is drawn — is what scrolling costs: a cap
    /// trades smoothness for CPU.
    public var maximumScrollFramesPerSecond: Double = 0 {
        didSet {
            if maximumScrollFramesPerSecond != oldValue {
                updateScrolling()
            }
        }
    }

    private static let fallbackLineDisplayTime: TimeInterval = 5

    private struct BitmapKey: Hashable {
        let appearanceName: NSAppearance.Name
        let scale: CGFloat
        let colorSpaceName: String
    }

    private var lineDisplayTime = MenuBarMarqueeLabel.fallbackLineDisplayTime
    /// What MarqueeLabel's `sizeToFit` makes its field for the current line.
    package private(set) var fieldSize = NSSize.zero
    /// One bitmap per appearance: every snapshot flips the appearance and
    /// back, so a single entry would be re-rendered twice per snapshot.
    private var cachedBitmaps: [BitmapKey: CGImage] = [:]

    private var lineStartTime: CFTimeInterval = 0
    private var pausedTime: CFTimeInterval?
    private var isScreenAsleep = false
    /// Wakes the view when a line's resting part ends.
    private var restTimer: Timer?
    /// Moves the line while it scrolls, in step with the screen's refresh.
    private var displayLink: CADisplayLink?
    private var screenSleepObservers: [NSObjectProtocol] = []

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

    /// The clock the scroll timing reads. Probes replace it to place the line
    /// at an exact moment.
    package var clock: () -> CFTimeInterval = CACurrentMediaTime

    /// Called on every draw. Probes count with it.
    package var drawingObserver: (() -> Void)?

    /// Called whenever the scroll position changes. Probes measure the motion
    /// with it.
    package var scrollPositionObserver: ((CGFloat) -> Void)?

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
    /// whenever another app becomes active.
    public func setStringValue(_ value: String, lineDisplayTime: TimeInterval) {
        guard !value.isEmpty else { return }
        let duration = lineDisplayTime.isFinite && lineDisplayTime > 0 ? lineDisplayTime : Self.fallbackLineDisplayTime
        guard value != super.stringValue || duration != self.lineDisplayTime else { return }
        super.stringValue = value
        self.lineDisplayTime = duration
        setAccessibilityValue(value)
        updateFieldSize()
        lineStartTime = clock()
        if pausedTime != nil {
            pausedTime = lineStartTime
        }
        needsDisplay = true
        updateScrolling()
    }

    /// Freezes a scrolling line while playback is paused, and resumes it
    /// from the same place.
    public func setPlaybackPaused(_ isPaused: Bool) {
        if isPaused, pausedTime == nil {
            pausedTime = clock()
        } else if !isPaused, let pausedTime {
            lineStartTime += clock() - pausedTime
            self.pausedTime = nil
        }
        updateScrolling()
    }

    // MARK: - Layout

    public override func setFrameSize(_ newSize: NSSize) {
        guard newSize != frame.size else { return }
        super.setFrameSize(newSize)
        updateScrolling()
        needsDisplay = true
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopObservingScreenSleep()
        } else {
            startObservingScreenSleep()
        }
        updateScrolling()
    }

    public override func viewDidHide() {
        super.viewDidHide()
        updateScrolling()
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        updateScrolling()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // The field size is aligned to the old screen's pixels.
        updateFieldSize()
        updateScrolling()
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
        let colorSpace = context.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let key = BitmapKey(
            appearanceName: NSAppearance.currentDrawing().name,
            scale: scale,
            colorSpaceName: (colorSpace.name as String?) ?? "unnamed"
        )
        if cachedBitmaps[key] == nil {
            cachedBitmaps[key] = renderTextBitmap(scale: scale, colorSpace: colorSpace)
        }
        guard let bitmap = cachedBitmaps[key] else { return }
        // Positions are whole device pixels, so this is a plain copy. A
        // fractional position would make every one of the six draws a frame
        // costs resample the bitmap in software: at display rate that alone
        // more than doubled the CPU, for motion no smoother than
        // MarqueeLabel's, which moves in whole points.
        context.saveGState()
        context.interpolationQuality = .none
        context.draw(bitmap, in: textFrame)
        context.restoreGState()
    }

    /// Where MarqueeLabel's `-layoutTextField` puts its field: centred
    /// vertically (rounded up), centred horizontally when it fits, otherwise
    /// at the scroll position.
    private var textFrame: NSRect {
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
    }

    private func renderTextBitmap(scale: CGFloat, colorSpace: CGColorSpace) -> CGImage? {
        guard let textCell else { return nil }
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
        textCell.draw(withFrame: NSRect(origin: .zero, size: fieldSize), in: self)
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
    }

    private var scrollPlan: ScrollPlan {
        ScrollPlan(fieldWidth: fieldSize.width, visibleWidth: bounds.width, lineDisplayTime: lineDisplayTime)
    }

    private func updateScrolling() {
        stopScrollClocks()
        let plan = scrollPlan
        let elapsed = (pausedTime ?? clock()) - lineStartTime
        scrollPosition = snappedToDevicePixels(plan.position(at: elapsed))

        guard plan.travel > 0, pausedTime == nil, !isScreenAsleep,
              window != nil, !isHiddenOrHasHiddenAncestor,
              elapsed < plan.restDuration + plan.movingDuration else {
            return
        }
        if elapsed < plan.restDuration {
            let timer = Timer(timeInterval: plan.restDuration - elapsed, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateScrolling() }
            }
            // Common modes, so the line keeps moving while a menu is open.
            RunLoop.main.add(timer, forMode: .common)
            restTimer = timer
        } else {
            startDisplayLink()
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

    private func stopScrollClocks() {
        restTimer?.invalidate()
        restTimer = nil
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func displayLinkDidFire(_ displayLink: CADisplayLink) {
        advanceScrolling()
    }

    private func advanceScrolling() {
        let plan = scrollPlan
        let elapsed = clock() - lineStartTime
        scrollPosition = snappedToDevicePixels(plan.position(at: elapsed))
        if elapsed >= plan.restDuration + plan.movingDuration {
            stopScrollClocks()
        }
    }

    /// Whole device pixels — half points on Retina, finer than the whole
    /// points MarqueeLabel's animated frame moves by.
    private func snappedToDevicePixels(_ position: CGFloat) -> CGFloat {
        let scale = window?.backingScaleFactor ?? 2
        return (position * scale).rounded() / scale
    }

    // MARK: - Screen sleep

    private func startObservingScreenSleep() {
        guard screenSleepObservers.isEmpty else { return }
        let notificationCenter = NSWorkspace.shared.notificationCenter
        screenSleepObservers = [
            notificationCenter.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setScreenAsleep(true) }
            },
            notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setScreenAsleep(false) }
            },
        ]
    }

    private func stopObservingScreenSleep() {
        for observer in screenSleepObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        screenSleepObservers = []
    }

    private func setScreenAsleep(_ isAsleep: Bool) {
        isScreenAsleep = isAsleep
        updateScrolling()
    }
}
