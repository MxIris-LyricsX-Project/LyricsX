import AppKit
import CoreText
import QuartzCore

/// Draws inside the system-owned status item. No NSTextField or auxiliary window.
final class NativeMarqueeView: NSView {
    private(set) var stringValue = ""
    private(set) var font = NSFont.systemFont(ofSize: 14)

    private var textImage: CGImage?
    private var textSize = NSSize.zero
    private var renderScale: CGFloat = 2
    private var lineDisplayTime: TimeInterval = 2
    private var lineStartTime: TimeInterval = 0
    private var pausedAt: TimeInterval?
    private var screenAsleep = false
    private var animationTimer: Timer?
    private var pageTimer: Timer?
    private var pages: [String] = []
    private var pageEnds: [TimeInterval] = []
    private var sleepObservers: [NSObjectProtocol] = []
    private var textOffset: CGFloat = 0
    private var scrollStart: TimeInterval = 0
    private var scrollDuration: TimeInterval = 0
    private var scrollTravel: CGFloat = 0

    // Used by the standalone validation harness, not exposed in the app UI.
    private(set) var drawCount = 0
    private(set) var bitmapBuildCount = 0
    var isAnimating: Bool { animationTimer != nil }
    var isPaging: Bool { pageTimer != nil }
    var staticPageCount: Int { pages.count }
    private(set) var currentPageIndex = 0
    private(set) var visibleString = ""
    var currentTextOffset: CGFloat { textOffset }
    /// Zero pages through stationary text; positive values set the scrolling rate.
    var frameRate: Double = 30 {
        didSet {
            guard frameRate != oldValue else { return }
            if (oldValue <= 0) != (frameRate <= 0) {
                lineStartTime = CACurrentMediaTime()
                if pausedAt != nil { pausedAt = lineStartTime }
                rebuildLayout()
            }
            updateAnimation()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        let nc = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            nc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                self?.setScreenAsleep(true)
            },
            nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.setScreenAsleep(false)
            },
        ]
    }

    required init?(coder: NSCoder) {
        fatalError("Use init(frame:)")
    }

    deinit {
        animationTimer?.invalidate()
        pageTimer?.invalidate()
        for observer in sleepObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    // Let the native status button receive clicks and track its own menu.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setStringValue(_ value: String, lineDisplayTime: TimeInterval) {
        let duration = lineDisplayTime.isFinite && lineDisplayTime > 0 ? lineDisplayTime : 5
        // Frontmost-app notifications must not restart the same lyric's animation.
        guard value != stringValue || duration != self.lineDisplayTime else { return }
        stringValue = value
        setAccessibilityLabel(value)
        self.lineDisplayTime = duration
        lineStartTime = CACurrentMediaTime()
        if pausedAt != nil { pausedAt = lineStartTime }
        rebuildLayout()
        updateAnimation()
    }

    func setPlaybackPaused(_ paused: Bool) {
        if paused, pausedAt == nil {
            pausedAt = CACurrentMediaTime()
        } else if !paused, let pausedAt = pausedAt {
            lineStartTime += CACurrentMediaTime() - pausedAt
            self.pausedAt = nil
        }
        updateAnimation()
    }

    override func setFrameSize(_ newSize: NSSize) {
        guard newSize != frame.size else { return }
        super.setFrameSize(newSize)
        if frameRate <= 0 { rebuildLayout() }
        updateAnimation()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let scale = max(1, NSScreen.screens.map(\.backingScaleFactor).max() ?? 2)
        if scale != renderScale {
            renderScale = scale
            rebuildLayout()
        }
        updateAnimation()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateAnimation()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateAnimation()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func setScreenAsleep(_ asleep: Bool) {
        screenAsleep = asleep
        updateAnimation()
    }

    private func rebuildLayout() {
        pages = frameRate <= 0 ? Self.paginate(stringValue, font: font, width: bounds.width) : []
        currentPageIndex = -1
        pageEnds = []
        if !pages.isEmpty {
            // Give a short final fragment a readable share without extending
            // this lyric into the next line's time slot.
            let minimum = min(0.8, lineDisplayTime / Double(pages.count))
            let remaining = max(0, lineDisplayTime - minimum * Double(pages.count))
            let totalWeight = Double(pages.reduce(0) { $0 + $1.count })
            var end: TimeInterval = 0
            for page in pages {
                end += minimum + remaining * Double(page.count) / max(1, totalWeight)
                pageEnds.append(end)
            }
        }
        if frameRate > 0 { rebuildTextImage(stringValue) }
    }

    /// CoreText chooses word/line boundaries; composed character boundaries
    /// additionally protect emoji and combining marks in narrow menu widths.
    static func paginate(_ value: String, font: NSFont, width: CGFloat) -> [String] {
        guard !value.isEmpty, width.isFinite, width > 0 else { return [] }
        let text = value as NSString
        let attributed = NSAttributedString(string: value, attributes: [.font: font])
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        var start = 0
        var result: [String] = []
        while start < text.length {
            let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
            var end = min(text.length, start + max(1, count))
            let cluster = text.rangeOfComposedCharacterSequence(at: end - 1)
            if NSMaxRange(cluster) > end {
                end = cluster.location > start ? cluster.location : NSMaxRange(cluster)
            }
            let page = text.substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !page.isEmpty { result.append(page) }
            start = end
        }
        return result
    }

    private func rebuildTextImage(_ value: String) {
        visibleString = value
        textImage = nil
        guard !value.isEmpty else {
            textSize = .zero
            needsDisplay = true
            return
        }
        let text = NSAttributedString(string: value, attributes: [
            .font: font,
            .foregroundColor: NSColor.white,
        ])
        let measured = text.size()
        textSize = NSSize(width: ceil(measured.width * renderScale) / renderScale,
                          height: ceil(measured.height * renderScale) / renderScale)
        let pixelWidth = max(1, Int(ceil(textSize.width * renderScale)))
        let pixelHeight = max(1, Int(ceil(textSize.height * renderScale)))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelWidth,
                                           pixelsHigh: pixelHeight, bitsPerSample: 8,
                                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: renderScale, y: renderScale)
        text.draw(at: .zero)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        textImage = bitmap.cgImage
        bitmapBuildCount += 1
        needsDisplay = true
    }

    private func updateAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        pageTimer?.invalidate()
        pageTimer = nil
        let elapsed = max(0, (pausedAt ?? CACurrentMediaTime()) - lineStartTime)
        if frameRate <= 0 {
            updateStaticPage(elapsed: elapsed)
            return
        }
        let fullWidth = textSize.width
        let travel = max(0, fullWidth - bounds.width)
        let movingDuration = fullWidth > 0 ? lineDisplayTime * Double(travel / fullWidth) : 0
        let startDelay = (lineDisplayTime - movingDuration) / 2
        scrollStart = lineStartTime + startDelay
        scrollDuration = movingDuration
        scrollTravel = travel
        let progress = frameRate > 0 && movingDuration > 0 ? min(1, max(0, (elapsed - startDelay) / movingDuration)) : 0
        let offset = travel > 0 ? -travel * CGFloat(progress) : (bounds.width - textSize.width) / 2
        let snapped = (offset * renderScale).rounded() / renderScale
        if snapped != textOffset {
            textOffset = snapped
            needsDisplay = true
        }
        guard frameRate > 0, travel > 0, pausedAt == nil, !screenAsleep,
              window != nil, !isHiddenOrHasHiddenAncestor,
              elapsed < startDelay + movingDuration else { return }
        if elapsed < startDelay {
            animationTimer = Timer.scheduledTimer(withTimeInterval: startDelay - elapsed, repeats: false) { [weak self] _ in
                self?.updateAnimation()
            }
        } else {
            // Publish actual redraws for AppKit's status-item snapshot pipeline.
            let timer = Timer(timeInterval: 1 / max(1, frameRate), repeats: true) { [weak self] _ in
                self?.advanceAnimation()
            }
            timer.tolerance = 0.002
            animationTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func updateStaticPage(elapsed: TimeInterval) {
        let index = pageEnds.firstIndex { elapsed < $0 } ?? max(0, pages.count - 1)
        let text = pages.isEmpty ? "" : pages[index]
        if index != currentPageIndex || visibleString != text {
            currentPageIndex = index
            rebuildTextImage(text)
        }
        // Keep multipage text at the same leading edge, including the last page.
        textOffset = pages.count > 1 ? 0 : ((bounds.width - textSize.width) * renderScale / 2).rounded() / renderScale
        needsDisplay = true
        guard index + 1 < pages.count, pausedAt == nil, !screenAsleep,
              window != nil, !isHiddenOrHasHiddenAncestor else { return }
        let timer = Timer(timeInterval: max(0.001, pageEnds[index] - elapsed), repeats: false) { [weak self] _ in
            self?.updateAnimation()
        }
        pageTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    private func advanceAnimation() {
        guard window != nil, !isHiddenOrHasHiddenAncestor, pausedAt == nil, !screenAsleep else {
            animationTimer?.invalidate()
            animationTimer = nil
            return
        }
        let elapsed = CACurrentMediaTime() - scrollStart
        let progress = scrollDuration > 0 ? min(1, max(0, elapsed / scrollDuration)) : 1
        let offset = -scrollTravel * CGFloat(progress)
        let snapped = (offset * renderScale).rounded() / renderScale
        if snapped != textOffset {
            textOffset = snapped
            needsDisplay = true
        }
        if progress >= 1 {
            animationTimer?.invalidate()
            animationTimer = nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        drawCount += 1
        guard let textImage = textImage, let context = NSGraphicsContext.current?.cgContext else { return }
        let y = ((bounds.height - textSize.height) * renderScale / 2).rounded() / renderScale
        let rect = NSRect(x: textOffset, y: y, width: textSize.width, height: textSize.height)
        context.saveGState()
        context.clip(to: bounds)
        context.clip(to: rect, mask: textImage)
        NSColor.labelColor.setFill()
        context.fill(bounds)
        context.restoreGState()
    }

}
