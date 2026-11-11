import AppKit
import Metal
import QuartzCore
import Testing
@testable import AppleMusicLyricsPanel

/// Renders a real `SyncedLyricsLineContentLayer` tree offscreen through
/// `CARenderer`, so masks, shadows and in-flight spring animations composite
/// exactly as they do on screen — no app, no player, no window.
///
/// Set `APPLE_MUSIC_LYRICS_PROBE_FRAME_DIRECTORY` to a writable path to also
/// dump every rendered frame as a PNG for eyeballing.
@MainActor
private final class OffscreenLineRenderer {
    let canvas = CGSize(width: 520, height: 140)
    let pixelWidth: Int
    let pixelHeight: Int

    let rootLayer = CALayer()

    private let texture: MTLTexture
    private let commandQueue: MTLCommandQueue
    private let renderer: CARenderer
    private let frameDumpDirectory: URL?

    init() throws {
        // Twice the point size: the glyph layers rasterize at contentsScale 2,
        // and every pixel threshold in the probes below was calibrated against
        // this exact geometry.
        self.pixelWidth = Int(canvas.width) * 2
        self.pixelHeight = Int(canvas.height) * 2

        rootLayer.frame = CGRect(origin: .zero, size: canvas)
        rootLayer.backgroundColor = CGColor(red: 0.25, green: 0.07, blue: 0.05, alpha: 1)
        rootLayer.isGeometryFlipped = true

        let device = try #require(MTLCreateSystemDefaultDevice())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: pixelWidth, height: pixelHeight, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .managed
        self.texture = try #require(device.makeTexture(descriptor: descriptor))
        self.commandQueue = try #require(device.makeCommandQueue())

        self.renderer = CARenderer(mtlTexture: texture, options: [kCARendererColorSpace: CGColorSpaceCreateDeviceRGB()])
        renderer.layer = rootLayer
        renderer.bounds = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)

        self.frameDumpDirectory = ProcessInfo.processInfo.environment["APPLE_MUSIC_LYRICS_PROBE_FRAME_DIRECTORY"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let frameDumpDirectory {
            try FileManager.default.createDirectory(at: frameDumpDirectory, withIntermediateDirectories: true)
        }
    }

    /// Renders the tree as of `time` and returns the BGRA pixels.
    func snapshot(at time: CFTimeInterval, dumpName: String) -> [UInt8] {
        renderer.beginFrame(atTime: time, timeStamp: nil)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()

        let rowBytes = pixelWidth * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * pixelHeight)
        if let buffer = commandQueue.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: texture)
            blit.endEncoding()
            buffer.commit()
            buffer.waitUntilCompleted()
        }
        texture.getBytes(
            &bytes,
            bytesPerRow: rowBytes,
            from: MTLRegionMake2D(0, 0, pixelWidth, pixelHeight),
            mipmapLevel: 0
        )
        dumpIfRequested(bytes: bytes, rowBytes: rowBytes, name: dumpName)
        return bytes
    }

    /// The vertical extent of "ink" — rows whose brightest green channel rises
    /// clearly above the dark red background. Green is used because the
    /// background has almost none while the (gray) glyphs have plenty, which
    /// makes the measure independent of the sweep's color animation.
    func inkRowBand(in pixels: [UInt8]) -> ClosedRange<Int>? {
        let rowBytes = pixelWidth * 4
        var topRow: Int?
        var bottomRow: Int?
        for row in 0 ..< pixelHeight {
            var hasInk = false
            for column in 0 ..< pixelWidth where pixels[row * rowBytes + column * 4 + 1] > 64 {
                hasInk = true
                break
            }
            if hasInk {
                if topRow == nil {
                    topRow = row
                }
                bottomRow = row
            }
        }
        guard let topRow, let bottomRow else { return nil }
        return topRow ... bottomRow
    }

    /// How many pixels in the region are essentially white on every channel.
    /// The sung sweep is the only thing in these scenes that composites to
    /// full white — the un-sung text is half-transparent over dark red and the
    /// glow tops out at 0.4 opacity — so this is a direct "is the sweep
    /// actually painting" measure, which the ink-band geometry above is blind
    /// to.
    func nearWhitePixelCount(in pixels: [UInt8], columns: Range<Int>, rows: Range<Int>) -> Int {
        let rowBytes = pixelWidth * 4
        var count = 0
        for row in rows.clamped(to: 0 ..< pixelHeight) {
            for column in columns.clamped(to: 0 ..< pixelWidth) {
                let base = row * rowBytes + column * 4
                if pixels[base] > 230, pixels[base + 1] > 230, pixels[base + 2] > 230 {
                    count += 1
                }
            }
        }
        return count
    }

    private func dumpIfRequested(bytes: [UInt8], rowBytes: Int, name: String) {
        guard let frameDumpDirectory,
              let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(
                  width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return }
        try? data.write(to: frameDumpDirectory.appendingPathComponent("\(name).png"))
    }
}

/// Serialized on purpose: both probes drive real wall-clock timelines whose
/// word-return passes are `asyncAfter`ed onto the main queue. Run in parallel
/// they interleave at every `await`, and each one's returns land inside the
/// other's measurements.
@Suite(.serialized)
@MainActor
struct LineEmphasisProbes {
    /// One karaoke line worth of fixture: per-character timings over 4 seconds,
    /// the same shape LyricsKit's inline time tags produce.
    private static func makeFixtureLayout() -> AppleMusicLyrics.LineTextLayout? {
        let text = "古巴比伦王颁布了"
        let lineDuration: TimeInterval = 4
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 36, weight: .bold)]
        )
        let timings = (0 ..< text.count).map {
            AppleMusicLyrics.WordTimingEntry(
                characterIndex: $0,
                timeOffset: Double($0) * lineDuration / Double(text.count)
            )
        }
        return AppleMusicLyrics.LineTextLayout.build(
            attributed: attributed,
            content: text,
            wordTimings: timings,
            lineDuration: lineDuration,
            textWidth: 460
        )
    }

    /// `APPLE_MUSIC_LYRICS_TRACE_DIRECTORY` (the same switch the translated-line
    /// probes honour) writes the ripple probe's per-glyph `position.y` samples
    /// to `ripple.tsv`, so a threshold that trips can be read against the real
    /// motion rather than argued about.
    private static func writeRippleTraceIfRequested(_ tracks: [[CGFloat]], frameStep: TimeInterval) {
        guard let directory = ProcessInfo.processInfo.environment["APPLE_MUSIC_LYRICS_TRACE_DIRECTORY"] else { return }
        var lines = ["glyph\ttime\ty"]
        for (glyphIndex, track) in tracks.enumerated() {
            for (sampleIndex, positionY) in track.enumerated() {
                lines.append(String(format: "%d\t%.3f\t%.3f", glyphIndex, Double(sampleIndex) * frameStep, positionY))
            }
        }
        try? lines.joined(separator: "\n").write(toFile: "\(directory)/ripple.tsv", atomically: true, encoding: .utf8)
    }

    private static func glyphLayers(of contentLayer: AppleMusicLyrics.SyncedLyricsLineContentLayer) -> [CALayer] {
        let visualRowColorContainers = (contentLayer.sublayers ?? []).filter { candidateLayer in
            (candidateLayer.sublayers ?? []).contains { sublayer in
                sublayer is AppleMusicLyrics.LineProgressGradientLayer
            }
        }
        return visualRowColorContainers.flatMap { visualRowColorContainer in
            (visualRowColorContainer.mask?.sublayers ?? []).flatMap { colorLayer in
                colorLayer.mask?.sublayers ?? []
            }
        }
    }

    /// The emphasis has to read as one swell travelling along the line, not as
    /// each character taking its turn — which is the difference between Apple
    /// Music's lyrics and a row of metronomes.
    ///
    /// Two properties separate the two, and both are about *overlap*:
    ///
    /// 1. **Each glyph is still in flight when the next one starts.** With
    ///    per-character time tags every word holds one glyph, and if the spring
    ///    is scaled to that single character rather than to the phrase around
    ///    it, every rise has settled before its neighbour begins.
    /// 2. **No glyph is ever parked at the top of its arc.** Word-scaled
    ///    timings put the return about 0.6 s after the spring has already
    ///    settled, so each character visibly freezes, swollen, before dropping.
    ///    A sung glyph *does* come to rest `syllableLift` above where it
    ///    started — Music never lowers it again until the line resets — so
    ///    "parked" means still while away from both rest and that sung height.
    @Test func emphasisRipplesAcrossNeighboursInsteadOfFreezingEachGlyph() async throws {
        let layout = try #require(Self.makeFixtureLayout())
        let renderer = try OffscreenLineRenderer()

        let contentLayer = AppleMusicLyrics.SyncedLyricsLineContentLayer()
        contentLayer.isHighlighted = true
        contentLayer.rebuild(with: layout, contentsScale: 2)
        contentLayer.anchorPoint = .zero
        contentLayer.position = CGPoint(
            x: 30 - contentLayer.textOutset.width,
            y: 30 - contentLayer.textOutset.height
        )
        renderer.rootLayer.addSublayer(contentLayer)
        CATransaction.flush()

        let glyphLayers = Self.glyphLayers(of: contentLayer)
        #expect(glyphLayers.count >= 4, "the fixture needs several glyphs before a ripple can be measured")

        // Sample where every glyph actually *is* on each frame, reading the
        // presentation layer so an in-flight spring reports its rendered
        // position rather than its destination.
        let lineDuration: TimeInterval = 4
        let frameStep: TimeInterval = 1.0 / 20.0
        var tracks = [[CGFloat]](repeating: [], count: glyphLayers.count)
        for frameIndex in 0 ..< 90 {
            let elapsed = Double(frameIndex) * frameStep
            contentLayer.update(elapsedTime: elapsed, fillFraction: CGFloat(min(1, elapsed / lineDuration)))
            CATransaction.flush()
            try await Task.sleep(seconds: frameStep)
            for (glyphIndex, glyphLayer) in glyphLayers.enumerated() {
                tracks[glyphIndex].append((glyphLayer.presentation() ?? glyphLayer).position.y)
            }
        }

        let sampleCount = tracks.map(\.count).min() ?? 0
        #expect(sampleCount > 10, "the timeline produced too few samples to judge")
        let restingPositions = tracks.map { $0.first ?? 0 }
        Self.writeRippleTraceIfRequested(tracks, frameStep: frameStep)
        // A glyph counts as moving when it travels more than this between two
        // samples, and as displaced when it sits this far from where it started.
        let movementThreshold: CGFloat = 0.05
        let displacementThreshold: CGFloat = 0.5
        // Freezing is a stricter question than "is it moving": every spring's
        // velocity passes through zero when it turns around at the top, and a
        // couple of samples either side of that fall under `movementThreshold`
        // without the glyph ever having stopped. A glyph that has genuinely
        // settled and is waiting for its return timer moves by nothing at all,
        // so the two are told apart by an order of magnitude, not by a hair.
        let stillnessThreshold: CGFloat = 0.01

        func isMoving(_ glyphIndex: Int, at sampleIndex: Int) -> Bool {
            abs(tracks[glyphIndex][sampleIndex] - tracks[glyphIndex][sampleIndex - 1]) > movementThreshold
        }

        // Overlap: at the sample where a glyph first moves, its predecessor
        // must still be moving. A phrase-scaled spring keeps each rise going
        // well past the next character's start (about 0.9 s against a 0.5 s
        // spacing here); a per-character spring has settled by then.
        var handoffsWithoutOverlap: [String] = []
        for glyphIndex in 1 ..< tracks.count {
            guard let startSampleIndex = (1 ..< sampleCount).first(where: { isMoving(glyphIndex, at: $0) }) else {
                handoffsWithoutOverlap.append("glyph \(glyphIndex) never moved")
                continue
            }
            if !isMoving(glyphIndex - 1, at: startSampleIndex) {
                let startTime = String(format: "%.2f", Double(startSampleIndex) * frameStep)
                handoffsWithoutOverlap.append("glyph \(glyphIndex - 1) was already still when glyph \(glyphIndex) started at \(startTime)s")
            }
        }
        #expect(
            handoffsWithoutOverlap.isEmpty,
            "the emphasis is stepping through characters instead of rippling: \(handoffsWithoutOverlap.joined(separator: " ⏐ "))"
        )

        // Parking: still while away from both rest and the sung height.
        let sungLift = AppleMusicLyrics.LyricsSpecs.syllableLift
        var longestFrozenRun = 0
        var frozenGlyphIndex = -1
        for (glyphIndex, track) in tracks.enumerated() {
            var run = 0
            for sampleIndex in 1 ..< sampleCount {
                let displacement = restingPositions[glyphIndex] - track[sampleIndex]
                let isAwayFromRest = abs(displacement) > displacementThreshold
                let isAwayFromSungHeight = abs(displacement - sungLift) > displacementThreshold
                let isStill = abs(track[sampleIndex] - track[sampleIndex - 1]) <= stillnessThreshold
                if isAwayFromRest, isAwayFromSungHeight, isStill {
                    run += 1
                    if run > longestFrozenRun {
                        longestFrozenRun = run
                        frozenGlyphIndex = glyphIndex
                    }
                } else {
                    run = 0
                }
            }
        }
        let frozenSeconds = Double(longestFrozenRun) * frameStep
        #expect(
            frozenSeconds < 0.15,
            "glyph \(frozenGlyphIndex) held still away from both rest and the sung height for \(String(format: "%.2f", frozenSeconds))s — it is parking at the top of its arc instead of flowing back"
        )
    }

    /// Drives one full line through its emphasis timeline in real time (the
    /// return pass hops through `DispatchQueue.main`, so wall-clock it is) and
    /// checks the four properties the offscreen harness was built to verify:
    ///
    /// 1. **Nothing is ever clipped.** The ink's height may only grow while
    ///    glyphs swell — the pre-fix bug cut emphasized glyphs to ~35% of
    ///    their height because the mask was confined to an unpadded bounds.
    /// 2. **The lift stays a lift.** The topmost ink row may rise by about
    ///    `syllableLift`, not more — the pre-fix bug over-travelled 20+ pixels
    ///    because the emphasized origin dropped the glyph's own offset.
    /// 3. **The sweep paints.** At fill 0.5 the sung half composites to pure
    ///    white and the un-sung half does not — a colorless sweep once passed
    ///    every geometry check here while the panel showed no karaoke at all.
    /// 4. **No drift.** After the line finishes and every spring returns, each
    ///    glyph layer sits exactly where it started — repositioning through
    ///    `frame` while a scale transform is live used to leak ~7% of the
    ///    glyph size per emphasis cycle.
    @Test func emphasisTimelineKeepsGlyphsIntactAndInPlace() async throws {
        let layout = try #require(Self.makeFixtureLayout())
        let renderer = try OffscreenLineRenderer()

        let contentLayer = AppleMusicLyrics.SyncedLyricsLineContentLayer()
        contentLayer.isHighlighted = true
        contentLayer.rebuild(with: layout, contentsScale: 2)
        contentLayer.anchorPoint = .zero
        contentLayer.position = CGPoint(
            x: 30 - contentLayer.textOutset.width,
            y: 30 - contentLayer.textOutset.height
        )
        renderer.rootLayer.addSublayer(contentLayer)

        let restingPositions = Self.glyphLayers(of: contentLayer).map(\.position)
        #expect(!restingPositions.isEmpty, "fixture produced no glyph layers")

        // The tree only reaches the renderer once the implicit transaction
        // commits, so flush before the first snapshot or it renders empty.
        CATransaction.flush()
        try await Task.sleep(seconds: 0.05)
        let restingInkBand = renderer.inkRowBand(in: renderer.snapshot(at: CACurrentMediaTime(), dumpName: "resting"))
        let restingBand = try #require(restingInkBand, "resting frame rendered no ink")

        // The timeline runs the whole line in real time so every word gets
        // emphasized, and — crucially for the drift probe — every word's
        // return pass actually fires (it is scheduled on wall-clock time).
        let lineDuration: TimeInterval = 4
        let frameStep: TimeInterval = 1.0 / 20.0
        var smallestInkHeight = Int.max
        var highestInkRow = Int.max
        var halfwayPixels: [UInt8]?
        for frameIndex in 0 ..< 80 {
            let elapsed = Double(frameIndex) * frameStep
            contentLayer.update(elapsedTime: elapsed, fillFraction: CGFloat(elapsed / lineDuration))
            CATransaction.flush()
            // A real suspension, not a `RunLoop` spin: the test body occupies
            // the main queue, and the word-return passes are `asyncAfter`ed
            // onto that same queue — they can only run while this is suspended.
            try await Task.sleep(seconds: frameStep)
            let pixels = renderer.snapshot(at: CACurrentMediaTime(), dumpName: String(format: "frame-%03d", frameIndex))
            if frameIndex == 40 {
                halfwayPixels = pixels
            }
            guard let band = renderer.inkRowBand(in: pixels) else { continue }
            smallestInkHeight = min(smallestInkHeight, band.count)
            highestInkRow = min(highestInkRow, band.lowerBound)
        }

        // If rendering silently broke, both bounds below would pass against
        // `Int.max` — so first prove the timeline actually produced ink.
        #expect(smallestInkHeight != Int.max, "no timeline frame rendered any ink")

        // 1. Clipping: with the glow and the swell, height only ever grows.
        //    (Post-fix measurement: 31 resting → up to 41 mid-swell; the bug
        //    collapsed it to 15.)
        #expect(
            smallestInkHeight >= restingBand.count - 2,
            "ink collapsed below its resting height (\(smallestInkHeight) < \(restingBand.count)) — emphasized glyphs are being clipped"
        )

        // 2. Over-travel: `syllableLift` points at contentsScale 2, plus a few
        //    rows of glow and antialiasing. Post-fix the rise measures 7 rows;
        //    the pre-fix over-travel was 20+.
        let allowedRiseInRows = Int(AppleMusicLyrics.LyricsSpecs.syllableLift * 2) + 6
        #expect(
            highestInkRow >= restingBand.lowerBound - allowedRiseInRows,
            "ink rose \(restingBand.lowerBound - highestInkRow) rows above rest (allowed \(allowedRiseInRows)) — the lift is over-travelling"
        )

        // 3. Colour: at the half-way frame (fill 0.5) the sung half of the line
        //    must composite to pure white and the un-sung half must not. The
        //    geometry probes above are blind to colour — a sweep that paints
        //    nothing at all once sailed through them — so this is the one that
        //    keeps the karaoke lighting honest. The guard band skips the 30pt
        //    feather ramp and the glyph swelling at the boundary.
        let halfway = try #require(halfwayPixels, "the timeline never rendered its half-way frame")
        let textOriginPoints: CGFloat = 30
        let boundaryPoints = textOriginPoints + layout.contentSize.width / 2
        let colourGuardBandPoints: CGFloat = 35
        let textRows = Int(textOriginPoints * 2) ..< Int((textOriginPoints + layout.contentSize.height) * 2)
        let sungWhite = renderer.nearWhitePixelCount(
            in: halfway,
            columns: Int((textOriginPoints + 5) * 2) ..< Int((boundaryPoints - colourGuardBandPoints) * 2),
            rows: textRows
        )
        let unsungWhite = renderer.nearWhitePixelCount(
            in: halfway,
            columns: Int((boundaryPoints + colourGuardBandPoints) * 2) ..< Int((textOriginPoints + layout.contentSize.width - 5) * 2),
            rows: textRows
        )
        #expect(
            sungWhite > 500,
            "only \(sungWhite) near-white pixels in the sung half at fill 0.5 — the sweep is not painting"
        )
        #expect(
            unsungWhite < 50,
            "\(unsungWhite) near-white pixels in the un-sung half at fill 0.5 — the sweep is ahead of the fill or the un-sung colour is wrong"
        )

        // 4. Drift: the last word's return fires `2 × wordDuration` after it
        //    starts, so give the tail room to land. The return pass only takes
        //    the swell back — Music leaves every sung glyph `syllableLift`
        //    above its rest until the line is reset — so each glyph must end
        //    exactly that high, with no horizontal creep and no glyph that
        //    settled anywhere else.
        try await Task.sleep(seconds: 1.5)
        let settledPositions = Self.glyphLayers(of: contentLayer).map(\.position)
        #expect(settledPositions.count == restingPositions.count)
        let sungLift = AppleMusicLyrics.LyricsSpecs.syllableLift
        for (index, (resting, settled)) in zip(restingPositions, settledPositions).enumerated() {
            #expect(
                abs(resting.x - settled.x) < 0.5 && abs((resting.y - settled.y) - sungLift) < 0.5,
                "glyph \(index) settled at \(settled), expected \(sungLift) pt above its rest \(resting)"
            )
        }
    }
}
