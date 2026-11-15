import AppKit
import CoreText
import LyricsXFoundation

/// The outcome of `StatusItemKaraokeRendering.run()`, written by the probe host.
package struct StatusItemKaraokeReport: Codable, Sendable {
    package var comparedSnapshotCount: Int
    /// Snapshots with progress that are not the sung drawing before the
    /// edge and the plain one after it.
    package var compositionMismatches: [String]
    /// Snapshots taken before the first character is sung that differ from
    /// the line without progress.
    package var unsungMismatches: [String]
    /// Lines whose fully sung snapshot looks like the plain one.
    package var indistinguishableSungLines: [String]
    /// Lines whose measured character boundaries miss the drawn ink.
    package var inkAlignmentErrors: [String]
    /// Pauses, resumes and re-anchors that left the progress elsewhere than
    /// a line anchored at that moment directly.
    package var clockMismatches: [String]
    /// A long line's scroll position after a timing for another line with
    /// the same text: back at the start.
    package var restartedScrollPosition: Double
    /// The same line's scroll position after its own timing is given again
    /// at another moment: unchanged.
    package var reanchoredScrollPosition: Double
    package var expectedReanchoredScrollPosition: Double
    /// Whether new text dropped the previous line's progress.
    package var newTextDroppedProgress: Bool
    /// Lines with right-to-left text that show progress. Their characters
    /// run against the edge's direction, so none may.
    package var rightToLeftLinesShowingProgress: [String]
    /// How often telling a playing line without progress that it has none,
    /// again, restarted its motion clocks — the controller does it on every
    /// app activation, with the switch off too.
    package var motionUpdatesForRepeatedAbsentProgress: Int
    /// The same for a playing line given its own timing again at the lyrics
    /// time its clock already shows — the same activations, switch on.
    package var motionUpdatesForRepeatedConsistentProgress: Int
    /// Whether that line, given its own timing at a lyrics time well away
    /// from its clock, moved its progress there: a jump still re-anchors.
    package var jumpReanchoredProgress: Bool
}

/// `MenuBarMarqueeLabel`'s karaoke progress, snapshot by snapshot.
///
/// Snapshotted the way the menu bar's replicants are, under the menu bar's
/// vibrant appearances and the plain ones, for short lines (centred) and a
/// long line mid-scroll. A snapshot with progress must be, pixel for pixel,
/// the fully sung snapshot up to the edge and the plain one after it — both
/// parts copies cut at a pixel edge — and a line nobody has started singing
/// must look exactly as it did without progress. The rest checks the clock:
/// a pause stops the progress, a resume carries on from it, and a timing for
/// another line with the same text starts a long line's scroll over.
///
/// It runs inside the probe host for the same reason as
/// `StatusItemSnapshotParity`: no window may open in the test process.
@available(macOS 26, *)
@MainActor
package enum StatusItemKaraokeRendering {
    private static let appearanceNames: [NSAppearance.Name] = [.vibrantDark, .vibrantLight, .darkAqua, .aqua]
    private static let shortLines = ["Let It Go, let it go", "终于做了这个决定"]
    private static let longLine = "终于做了这个决定，别人怎么说我不理，要随着我的心，大步踏出去"
    private static let longLineScrollPosition: CGFloat = -120
    private static let lineDisplayTime: TimeInterval = 10
    private static let lineStart: TimeInterval = 42
    private static let secondsPerCharacter: TimeInterval = 0.2

    package static func run() throws -> StatusItemKaraokeReport {
        let snapshotter = ReplicantSnapshotter()
        var comparedSnapshotCount = 0
        var compositionMismatches: [String] = []
        var unsungMismatches: [String] = []
        var indistinguishableSungLines: [String] = []
        let cases: [(text: String, scrollPosition: CGFloat)] = shortLines.map { ($0, 0) } + [(longLine, longLineScrollPosition)]
        for appearanceName in appearanceNames {
            guard let appearance = NSAppearance(named: appearanceName) else {
                throw StatusItemSnapshotParityError.missingAppearance(appearanceName.rawValue)
            }
            for (text, scrollPosition) in cases {
                let caseName = "\(appearanceName.rawValue) “\(text)”"
                let marqueeLabel = pausedMarqueeLabel(showing: text, scrolledTo: scrollPosition)
                let timing = timing(for: text)
                let plain = try snapshotter.snapshot(of: marqueeLabel, appearance: appearance)

                marqueeLabel.setKaraokeTiming(timing, lyricsTime: lineStart - 1)
                let beforeSinging = try snapshotter.snapshot(of: marqueeLabel, appearance: appearance)
                marqueeLabel.setKaraokeTiming(timing, lyricsTime: timing.movingLyricsTimes.upperBound + 1)
                let sung = try snapshotter.snapshot(of: marqueeLabel, appearance: appearance)
                // Partway into a character, so the edge cuts through a glyph.
                let partway = lineStart + (Double(text.count / 2) + 0.4) * secondsPerCharacter
                marqueeLabel.setKaraokeTiming(timing, lyricsTime: partway)
                let partial = try snapshotter.snapshot(of: marqueeLabel, appearance: appearance)
                comparedSnapshotCount += 3

                if try differingPixelCount(plain, beforeSinging, columns: 0 ..< plain.pixelsWide) > 0 {
                    unsungMismatches.append(caseName)
                }
                if try differingPixelCount(plain, sung, columns: 0 ..< plain.pixelsWide) == 0 {
                    indistinguishableSungLines.append(caseName)
                }
                guard let sungWidth = marqueeLabel.sungWidth else {
                    compositionMismatches.append("\(caseName): no sung width partway through the line")
                    continue
                }
                let scale = CGFloat(plain.pixelsWide) / MenuBarLyricsGeometry.lyricsWidth
                let edgeInPixels = (marqueeLabel.textFrame.minX + sungWidth) * scale
                let edgeColumn = Int(edgeInPixels.rounded())
                guard abs(edgeInPixels - CGFloat(edgeColumn)) < 0.001, (1 ..< plain.pixelsWide).contains(edgeColumn) else {
                    compositionMismatches.append("\(caseName): edge at \(edgeInPixels) px, not a pixel edge inside the view")
                    continue
                }
                let sungPartDifference = try differingPixelCount(sung, partial, columns: 0 ..< edgeColumn)
                let unsungPartDifference = try differingPixelCount(plain, partial, columns: edgeColumn ..< plain.pixelsWide)
                if sungPartDifference > 0 || unsungPartDifference > 0 {
                    compositionMismatches.append(
                        "\(caseName) edge \(edgeColumn) px: \(sungPartDifference) px differ from the sung drawing before it, \(unsungPartDifference) px from the plain one after it"
                    )
                }
            }
        }

        let restartProbe = restartedScrollPositions()
        return try StatusItemKaraokeReport(
            comparedSnapshotCount: comparedSnapshotCount,
            compositionMismatches: compositionMismatches,
            unsungMismatches: unsungMismatches,
            indistinguishableSungLines: indistinguishableSungLines,
            inkAlignmentErrors: inkAlignmentErrors(snapshotter: snapshotter),
            clockMismatches: clockMismatches(),
            restartedScrollPosition: Double(restartProbe.restarted),
            reanchoredScrollPosition: Double(restartProbe.reanchored),
            expectedReanchoredScrollPosition: Double(longLineScrollPosition),
            newTextDroppedProgress: newTextDropsProgress(),
            rightToLeftLinesShowingProgress: rightToLeftLinesShowingProgress(),
            motionUpdatesForRepeatedAbsentProgress: motionUpdatesForRepeatedAbsentProgress(),
            motionUpdatesForRepeatedConsistentProgress: repeatedConsistentProgress().motionUpdateCount,
            jumpReanchoredProgress: repeatedConsistentProgress().jumpReanchored
        )
    }

    /// Every character starts `secondsPerCharacter` after the one before it,
    /// and the line lasts until the last one is sung.
    private static func timing(for text: String, lineStart: TimeInterval = lineStart) -> KaraokeLineTiming {
        let tags = (0 ..< text.count).map {
            LyricsLine.Attachments.InlineTimeTag.Tag(index: $0, time: Double($0) * secondsPerCharacter)
        }
        let timeTag = LyricsLine.Attachments.InlineTimeTag(tags: tags, duration: Double(text.count) * secondsPerCharacter)
        guard let timing = KaraokeLineTiming(lineStart: lineStart, characterCount: text.count, timeTag: timeTag) else {
            preconditionFailure("a line sung character by character has a timing")
        }
        return timing
    }

    /// A view showing `text`, paused once a long line's scroll has reached
    /// `scrollPosition`; every karaoke time it is then given stays put.
    private static func pausedMarqueeLabel(showing text: String, scrolledTo scrollPosition: CGFloat) -> MenuBarMarqueeLabel {
        var currentTime: CFTimeInterval = 0
        let marqueeLabel = MenuBarMarqueeLabel(frame: NSRect(x: 0, y: 0, width: MenuBarLyricsGeometry.lyricsWidth, height: MenuBarLyricsGeometry.lyricsHeight))
        marqueeLabel.clock = { currentTime }
        marqueeLabel.setStringValue(text, lineDisplayTime: lineDisplayTime)
        let fieldWidth = marqueeFieldWidth(of: text)
        let travel = fieldWidth - MenuBarLyricsGeometry.lyricsWidth
        if travel > 0, scrollPosition < 0 {
            let movingDuration = lineDisplayTime * Double(travel / fieldWidth)
            let restDuration = (lineDisplayTime - movingDuration) / 2
            currentTime = restDuration + movingDuration * Double(-scrollPosition / travel)
        }
        marqueeLabel.setPlaybackPaused(true)
        return marqueeLabel
    }

    /// The first and last inked columns of each short line, against where
    /// the view says its first character starts plus where Core Text puts
    /// the glyphs' ink. A wrong text padding moves every edge by that much.
    private static func inkAlignmentErrors(snapshotter: ReplicantSnapshotter) throws -> [String] {
        guard let appearance = NSAppearance(named: .aqua) else {
            throw StatusItemSnapshotParityError.missingAppearance(NSAppearance.Name.aqua.rawValue)
        }
        var errors: [String] = []
        for text in shortLines {
            let marqueeLabel = pausedMarqueeLabel(showing: text, scrolledTo: 0)
            let snapshot = try snapshotter.snapshot(of: marqueeLabel, appearance: appearance)
            guard let attributedText = marqueeLabel.cell?.attributedStringValue,
                  let firstBoundary = marqueeLabel.characterBoundaries.first,
                  let inkedColumns = inkedColumnRange(of: snapshot) else {
                errors.append("“\(text)”: nothing to measure")
                continue
            }
            let scale = CGFloat(snapshot.pixelsWide) / MenuBarLyricsGeometry.lyricsWidth
            let glyphBounds = CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(attributedText), .useGlyphPathBounds)
            let textFrameMinX = marqueeLabel.textFrame.minX
            let expectedInkStart = textFrameMinX + firstBoundary + glyphBounds.minX
            let expectedInkEnd = textFrameMinX + firstBoundary + glyphBounds.maxX
            let measuredInkStart = CGFloat(inkedColumns.lowerBound) / scale
            let measuredInkEnd = CGFloat(inkedColumns.upperBound) / scale
            // Antialiasing spreads ink about a pixel past the glyph outline.
            let tolerance: CGFloat = 1
            if abs(measuredInkStart - expectedInkStart) > tolerance || abs(measuredInkEnd - expectedInkEnd) > tolerance {
                errors.append(
                    "“\(text)”: ink \(measuredInkStart)–\(measuredInkEnd) pt, characters measured at \(expectedInkStart)–\(expectedInkEnd) pt"
                )
            }
        }
        return errors
    }

    /// Pausing, resuming and anchoring while paused, each against a line
    /// anchored directly at the lyrics time the clock should have reached.
    private static func clockMismatches() -> [String] {
        let text = shortLines[0]
        let timing = timing(for: text)
        var mismatches: [String] = []
        func expectSungWidth(_ marqueeLabel: MenuBarMarqueeLabel, atLyricsTime lyricsTime: TimeInterval, _ situation: String) {
            let expectedWidth = directlyAnchoredSungWidth(text: text, timing: timing, lyricsTime: lyricsTime)
            if marqueeLabel.sungWidth != expectedWidth || expectedWidth == nil {
                mismatches.append("\(situation): \(String(describing: marqueeLabel.sungWidth)) pt, expected \(String(describing: expectedWidth)) pt")
            }
        }

        var currentTime: CFTimeInterval = 100
        let playingLabel = MenuBarMarqueeLabel(frame: NSRect(x: 0, y: 0, width: MenuBarLyricsGeometry.lyricsWidth, height: MenuBarLyricsGeometry.lyricsHeight))
        playingLabel.clock = { currentTime }
        playingLabel.setStringValue(text, lineDisplayTime: lineDisplayTime)
        playingLabel.setKaraokeTiming(timing, lyricsTime: lineStart)
        currentTime += 1
        playingLabel.setPlaybackPaused(true)
        expectSungWidth(playingLabel, atLyricsTime: lineStart + 1, "paused after playing 1 s")
        currentTime += 3
        playingLabel.setPlaybackPaused(true)
        expectSungWidth(playingLabel, atLyricsTime: lineStart + 1, "still paused 3 s later")
        playingLabel.setPlaybackPaused(false)
        expectSungWidth(playingLabel, atLyricsTime: lineStart + 1, "just resumed")
        currentTime += 0.6
        playingLabel.setPlaybackPaused(true)
        expectSungWidth(playingLabel, atLyricsTime: lineStart + 1.6, "paused again after playing 0.6 s more")

        // Playback jumped while paused: the anchor is the paused position.
        playingLabel.setKaraokeTiming(timing, lyricsTime: lineStart + 2.2)
        currentTime += 5
        playingLabel.setPlaybackPaused(false)
        currentTime += 0.4
        playingLabel.setPlaybackPaused(true)
        expectSungWidth(playingLabel, atLyricsTime: lineStart + 2.6, "anchored while paused, then played 0.4 s")
        return mismatches
    }

    private static func directlyAnchoredSungWidth(text: String, timing: KaraokeLineTiming, lyricsTime: TimeInterval) -> CGFloat? {
        let marqueeLabel = MenuBarMarqueeLabel(frame: NSRect(x: 0, y: 0, width: MenuBarLyricsGeometry.lyricsWidth, height: MenuBarLyricsGeometry.lyricsHeight))
        let fixedTime: CFTimeInterval = 7
        marqueeLabel.clock = { fixedTime }
        marqueeLabel.setStringValue(text, lineDisplayTime: lineDisplayTime)
        marqueeLabel.setPlaybackPaused(true)
        marqueeLabel.setKaraokeTiming(timing, lyricsTime: lyricsTime)
        return marqueeLabel.sungWidth
    }

    /// A long line mid-scroll given a timing for another line with the same
    /// text, and the same line given its own timing again.
    private static func restartedScrollPositions() -> (restarted: CGFloat, reanchored: CGFloat) {
        let firstTiming = timing(for: longLine)
        let repeatedTiming = timing(for: longLine, lineStart: lineStart + 30)

        let reanchoredLabel = pausedMarqueeLabel(showing: longLine, scrolledTo: longLineScrollPosition)
        reanchoredLabel.setKaraokeTiming(firstTiming, lyricsTime: lineStart + 1)
        reanchoredLabel.setKaraokeTiming(firstTiming, lyricsTime: lineStart + 2)

        let restartedLabel = pausedMarqueeLabel(showing: longLine, scrolledTo: longLineScrollPosition)
        restartedLabel.setKaraokeTiming(firstTiming, lyricsTime: lineStart + 1)
        restartedLabel.setKaraokeTiming(repeatedTiming, lyricsTime: lineStart + 30)
        return (restartedLabel.scrollPosition, reanchoredLabel.scrollPosition)
    }

    private static func newTextDropsProgress() -> Bool {
        let marqueeLabel = pausedMarqueeLabel(showing: shortLines[0], scrolledTo: 0)
        marqueeLabel.setKaraokeTiming(timing(for: shortLines[0]), lyricsTime: lineStart + 1)
        guard marqueeLabel.sungWidth != nil else { return false }
        marqueeLabel.setStringValue(shortLines[1], lineDisplayTime: lineDisplayTime)
        return marqueeLabel.sungWidth == nil
    }

    /// A Hebrew line, a line with a Hebrew word in it, and a line with a
    /// single Hebrew letter in it — the last of which keeps its character
    /// boundaries in order and only Core Text's run direction gives away.
    private static func rightToLeftLinesShowingProgress() -> [String] {
        ["שלום עולם", "Love אהבה forever", "Hello א world"].filter { text in
            let marqueeLabel = pausedMarqueeLabel(showing: text, scrolledTo: 0)
            marqueeLabel.setKaraokeTiming(timing(for: text), lyricsTime: lineStart + 0.9)
            return marqueeLabel.sungWidth != nil
        }
    }

    /// A line playing on a clock the probe moves.
    private static func playingMarqueeLabel(showing text: String, clock: @escaping () -> CFTimeInterval) -> MenuBarMarqueeLabel {
        let marqueeLabel = MenuBarMarqueeLabel(frame: NSRect(x: 0, y: 0, width: MenuBarLyricsGeometry.lyricsWidth, height: MenuBarLyricsGeometry.lyricsHeight))
        marqueeLabel.clock = clock
        marqueeLabel.setStringValue(text, lineDisplayTime: lineDisplayTime)
        return marqueeLabel
    }

    private static func motionUpdatesForRepeatedAbsentProgress() -> Int {
        var currentTime: CFTimeInterval = 0
        let marqueeLabel = playingMarqueeLabel(showing: shortLines[0]) { currentTime }
        var motionUpdateCount = 0
        marqueeLabel.motionUpdateObserver = { motionUpdateCount += 1 }
        for repetition in 0 ..< 3 {
            currentTime += 0.5
            marqueeLabel.setKaraokeTiming(nil, lyricsTime: lineStart + Double(repetition))
        }
        return motionUpdateCount
    }

    /// Re-sends a playing line's own timing three times at the lyrics time
    /// its clock shows, give or take player jitter, then once two seconds
    /// off.
    private static func repeatedConsistentProgress() -> (motionUpdateCount: Int, jumpReanchored: Bool) {
        var currentTime: CFTimeInterval = 0
        let text = shortLines[0]
        let timing = timing(for: text)
        let marqueeLabel = playingMarqueeLabel(showing: text) { currentTime }
        marqueeLabel.setKaraokeTiming(timing, lyricsTime: lineStart)
        var motionUpdateCount = 0
        marqueeLabel.motionUpdateObserver = { motionUpdateCount += 1 }
        for (elapsed, jitter) in [(0.5, 0.02), (1.0, -0.03), (1.5, 0.0)] {
            currentTime = elapsed
            marqueeLabel.setKaraokeTiming(timing, lyricsTime: lineStart + elapsed + jitter)
        }
        let consistentMotionUpdateCount = motionUpdateCount
        let widthBeforeJump = marqueeLabel.sungWidth
        marqueeLabel.setKaraokeTiming(timing, lyricsTime: lineStart + 3.5)
        let jumpReanchored = marqueeLabel.sungWidth != widthBeforeJump
            && marqueeLabel.sungWidth == directlyAnchoredSungWidth(text: text, timing: timing, lyricsTime: lineStart + 3.5)
        return (consistentMotionUpdateCount, jumpReanchored)
    }

    /// How many pixels in `columns` differ between two snapshots of the
    /// same size.
    private static func differingPixelCount(_ reference: NSBitmapImageRep, _ candidate: NSBitmapImageRep, columns: Range<Int>) throws -> Int {
        guard reference.pixelsWide == candidate.pixelsWide, reference.pixelsHigh == candidate.pixelsHigh,
              reference.bitsPerPixel == 32, candidate.bitsPerPixel == 32,
              let referenceBytes = reference.bitmapData, let candidateBytes = candidate.bitmapData else {
            throw StatusItemSnapshotParityError.incomparableSnapshots
        }
        var differingPixelCount = 0
        for row in 0 ..< reference.pixelsHigh {
            for column in columns.clamped(to: 0 ..< reference.pixelsWide) {
                let referenceOffset = row * reference.bytesPerRow + column * 4
                let candidateOffset = row * candidate.bytesPerRow + column * 4
                for channel in 0 ..< 4 where referenceBytes[referenceOffset + channel] != candidateBytes[candidateOffset + channel] {
                    differingPixelCount += 1
                    break
                }
            }
        }
        return differingPixelCount
    }

    /// The columns holding any ink, from the first to just past the last.
    private static func inkedColumnRange(of snapshot: NSBitmapImageRep) -> Range<Int>? {
        guard snapshot.bitsPerPixel == 32, let bytes = snapshot.bitmapData else { return nil }
        var firstColumn: Int?
        var lastColumn: Int?
        for column in 0 ..< snapshot.pixelsWide {
            for row in 0 ..< snapshot.pixelsHigh where bytes[row * snapshot.bytesPerRow + column * 4 + 3] > 0 {
                firstColumn = firstColumn ?? column
                lastColumn = column
                break
            }
        }
        guard let firstColumn, let lastColumn else { return nil }
        return firstColumn ..< (lastColumn + 1)
    }
}
