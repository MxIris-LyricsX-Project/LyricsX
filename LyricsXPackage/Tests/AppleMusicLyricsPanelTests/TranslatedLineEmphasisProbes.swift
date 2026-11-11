import AppKit
import QuartzCore
import Testing
import LyricsXFoundation
@testable import AppleMusicLyricsPanel

/// Reproduction loop for "lines with a translation bounce strangely": the same
/// Apple Music line is driven through the real `SyncedLyricsLineView` with and
/// without its translation, and the per-glyph motion is sampled frame by frame.
/// A row's translation lives in the view's own drawing and its height; the glyph
/// tree must not notice it, so the two tracks have to agree.
@Suite(.serialized)
struct TranslatedLineEmphasisProbes {
    /// 「高中三年 我為什麼」 from the 2026-09-05 comparison screenshot: Apple
    /// Music structured timing (six words, one syllable each), inline tags and
    /// a Simplified translation, exactly as the library file stores it.
    private static let lyricsSource = """
    [ti:等你下课 (with 杨瑞代)]
    [lang:zh-Hant]
    [00:28.454]高中三年 我為什麼
    [00:28.454][tr:zh-Hans]高中三年 我为什么
    [00:28.454][tt]<0,0><317,1><771,3><1657,5><1881,6><2245,8><2913>
    [00:28.454][synchronized-timing]1:eyJkdXJhdGlvbk1pbGxpc2Vjb25kcyI6MjkxMywid29yZHMiOlt7ImVuZGluZ0NoYXJhY3RlckluZGV4IjoxLCJlbmRpbmdUaW1lTWlsbGlzZWNvbmRzIjozMTcsInN0YXJ0aW5nQ2hhcmFjdGVySW5kZXgiOjAsInN0YXJ0aW5nVGltZU1pbGxpc2Vjb25kcyI6MCwic3lsbGFibGVzIjpbeyJlbmRpbmdDaGFyYWN0ZXJJbmRleCI6MSwiZW5kaW5nVGltZU1pbGxpc2Vjb25kcyI6MzE3LCJzdGFydGluZ0NoYXJhY3RlckluZGV4IjowLCJzdGFydGluZ1RpbWVNaWxsaXNlY29uZHMiOjB9XX0seyJlbmRpbmdDaGFyYWN0ZXJJbmRleCI6MywiZW5kaW5nVGltZU1pbGxpc2Vjb25kcyI6NzcxLCJzdGFydGluZ0NoYXJhY3RlckluZGV4IjoxLCJzdGFydGluZ1RpbWVNaWxsaXNlY29uZHMiOjMxNywic3lsbGFibGVzIjpbeyJlbmRpbmdDaGFyYWN0ZXJJbmRleCI6MywiZW5kaW5nVGltZU1pbGxpc2Vjb25kcyI6NzcxLCJzdGFydGluZ0NoYXJhY3RlckluZGV4IjoxLCJzdGFydGluZ1RpbWVNaWxsaXNlY29uZHMiOjMxN31dfSx7ImVuZGluZ0NoYXJhY3RlckluZGV4Ijo0LCJlbmRpbmdUaW1lTWlsbGlzZWNvbmRzIjoxNjU4LCJzdGFydGluZ0NoYXJhY3RlckluZGV4IjozLCJzdGFydGluZ1RpbWVNaWxsaXNlY29uZHMiOjc3MSwic3lsbGFibGVzIjpbeyJlbmRpbmdDaGFyYWN0ZXJJbmRleCI6NCwiZW5kaW5nVGltZU1pbGxpc2Vjb25kcyI6MTY1OCwic3RhcnRpbmdDaGFyYWN0ZXJJbmRleCI6Mywic3RhcnRpbmdUaW1lTWlsbGlzZWNvbmRzIjo3NzF9XX0seyJlbmRpbmdDaGFyYWN0ZXJJbmRleCI6NiwiZW5kaW5nVGltZU1pbGxpc2Vjb25kcyI6MTg4Miwic3RhcnRpbmdDaGFyYWN0ZXJJbmRleCI6NSwic3RhcnRpbmdUaW1lTWlsbGlzZWNvbmRzIjoxNjU4LCJzeWxsYWJsZXMiOlt7ImVuZGluZ0NoYXJhY3RlckluZGV4Ijo2LCJlbmRpbmdUaW1lTWlsbGlzZWNvbmRzIjoxODgyLCJzdGFydGluZ0NoYXJhY3RlckluZGV4Ijo1LCJzdGFydGluZ1RpbWVNaWxsaXNlY29uZHMiOjE2NTh9XX0seyJlbmRpbmdDaGFyYWN0ZXJJbmRleCI6OCwiZW5kaW5nVGltZU1pbGxpc2Vjb25kcyI6MjI0NSwic3RhcnRpbmdDaGFyYWN0ZXJJbmRleCI6Niwic3RhcnRpbmdUaW1lTWlsbGlzZWNvbmRzIjoxODgyLCJzeWxsYWJsZXMiOlt7ImVuZGluZ0NoYXJhY3RlckluZGV4Ijo4LCJlbmRpbmdUaW1lTWlsbGlzZWNvbmRzIjoyMjQ1LCJzdGFydGluZ0NoYXJhY3RlckluZGV4Ijo2LCJzdGFydGluZ1RpbWVNaWxsaXNlY29uZHMiOjE4ODJ9XX0seyJlbmRpbmdDaGFyYWN0ZXJJbmRleCI6OSwiZW5kaW5nVGltZU1pbGxpc2Vjb25kcyI6MjkxMywic3RhcnRpbmdDaGFyYWN0ZXJJbmRleCI6OCwic3RhcnRpbmdUaW1lTWlsbGlzZWNvbmRzIjoyMjQ1LCJzeWxsYWJsZXMiOlt7ImVuZGluZ0NoYXJhY3RlckluZGV4Ijo5LCJlbmRpbmdUaW1lTWlsbGlzZWNvbmRzIjoyOTEzLCJzdGFydGluZ0NoYXJhY3RlckluZGV4Ijo4LCJzdGFydGluZ1RpbWVNaWxsaXNlY29uZHMiOjIyNDV9XX1dfQ==
    [00:31.717]為什麼不好好讀書
    """

    private struct GlyphSample {
        let elapsedTime: TimeInterval
        let positionY: CGFloat
        let scale: CGFloat
    }

    private struct LineTrace {
        let label: String
        let rowHeight: CGFloat
        /// Distance from the row's top edge to the content layer's top edge.
        let contentTopInset: CGFloat
        let glyphCount: Int
        let tracks: [[GlyphSample]]
    }

    @Test @MainActor func translationDoesNotChangeTheGlyphMotion() async throws {
        let translated = try await Self.trace(label: "translated", stripping: [])
        let untranslated = try await Self.trace(label: "untranslated", stripping: ["[tr:"])

        #expect(translated.glyphCount == untranslated.glyphCount)
        #expect(translated.rowHeight > untranslated.rowHeight, "the translated row must be taller")
        #expect(abs(translated.contentTopInset - untranslated.contentTopInset) < 0.001, "the translation sits below the main text, it must not move it")

        let divergences = Self.divergences(between: translated, and: untranslated, tolerance: 0.5)
        #expect(
            divergences.isEmpty,
            "glyph motion differs with a translation: \(divergences.prefix(6).joined(separator: " ⏐ "))"
        )
        Self.writeTraceIfRequested([translated, untranslated])
    }

    /// Not an assertion of parity — the structured timing path is allowed to
    /// move differently from the inline fallback — but the trace is written out
    /// so the two can be compared by eye when the motion itself is in doubt.
    @Test @MainActor func structuredAndInlineTimingTracesAreRecorded() async throws {
        let structured = try await Self.trace(label: "structured", stripping: [])
        let inlineOnly = try await Self.trace(label: "inline-only", stripping: ["[synchronized-timing]"])
        #expect(structured.glyphCount == inlineOnly.glyphCount)
        Self.writeTraceIfRequested([structured, inlineOnly])
    }

    /// Music never lowers a sung glyph again. A `zh` word is `.none`, so its
    /// syllable rises on the soft spring (`sub_1001897C0`) and stays there; a
    /// `.factor` word's return pass lands at `frame.origin.y - syllableLift`
    /// (`sub_10018B2B4`). Either way only a rewind or a deselection
    /// (`sub_100166DBC`) brings a glyph down, so the sung prefix sits three
    /// points high and nothing bounces. Every timed glyph must end the line
    /// lifted, and once lifted must not drop back to rest while the line is
    /// still selected.
    @Test @MainActor func sungGlyphsStayLiftedUntilTheLineResets() async throws {
        let trace = try await Self.trace(label: "structured-lift", stripping: [])
        let lift = AppleMusicLyrics.LyricsSpecs.syllableLift
        var failures: [String] = []
        for (glyphIndex, track) in trace.tracks.enumerated() {
            guard let rest = track.first?.positionY, let final = track.last else { continue }
            let everLifted = track.contains { rest - $0.positionY > lift * 0.8 }
            // The space between 年 and 我 carries no timing and never moves.
            guard everLifted else { continue }
            if abs((rest - final.positionY) - lift) > 0.5 {
                failures.append(String(format: "glyph %d ends %.2f pt above rest, expected %.0f", glyphIndex, rest - final.positionY, lift))
            }
            if let peakIndex = track.indices.min(by: { track[$0].positionY < track[$1].positionY }),
               let dropped = track[peakIndex...].first(where: { rest - $0.positionY < lift * 0.3 }) {
                failures.append(String(format: "glyph %d dropped back to rest at %.2fs", glyphIndex, dropped.elapsedTime))
            }
        }
        let failureSummary = failures.prefix(6).joined(separator: " ⏐ ")
        #expect(failures.isEmpty, "\(failureSummary)")
    }

    // MARK: Harness

    @MainActor
    private static func trace(label: String, stripping markers: [String]) async throws -> LineTrace {
        let source = lyricsSource
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in !markers.contains { marker in line.contains(marker) } }
            .joined(separator: "\n")
        let lyrics = try #require(Lyrics(source), "fixture failed to parse")
        let line = try #require(lyrics.lines.first { $0.content.hasPrefix("高中三年") })
        let lineDuration = try #require(line.timetagDuration)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let rowView = AppleMusicLyrics.SyncedLyricsLineView(frame: NSRect(x: 0, y: 0, width: 640, height: 100))
        rowView.configure(
            line: line,
            translation: line.attachments.translation(),
            originalIndex: 0,
            enabledPosition: 0,
            mainFontSize: 30,
            translationFontSize: 16
        )
        window.contentView?.addSubview(rowView)
        let rowHeight = rowView.preferredHeight(forWidth: 640)
        rowView.frame = NSRect(x: 0, y: 0, width: 640, height: rowHeight)
        rowView.setHighlighted(true)
        rowView.layoutSubtreeIfNeeded()
        rowView.updateKaraoke(elapsedTime: 0, lineDuration: lineDuration, mode: .characterLevel)
        CATransaction.flush()

        let contentLayer = rowView.contentLayer
        let rowLayer = try #require(rowView.layer)
        let glyphLayers = glyphLayers(of: contentLayer)
        #expect(!glyphLayers.isEmpty, "\(label): the row built no glyph layers")

        let frameStep: TimeInterval = 1.0 / 30.0
        let frameCount = Int((lineDuration + 1.0) / frameStep)
        var tracks = [[GlyphSample]](repeating: [], count: glyphLayers.count)
        for frameIndex in 0 ..< frameCount {
            let elapsed = Double(frameIndex) * frameStep
            rowView.updateKaraoke(elapsedTime: elapsed, lineDuration: lineDuration, mode: .characterLevel)
            CATransaction.flush()
            try await Task.sleep(seconds: frameStep)
            for (glyphIndex, glyphLayer) in glyphLayers.enumerated() {
                let presented = glyphLayer.presentation() ?? glyphLayer
                tracks[glyphIndex].append(GlyphSample(
                    elapsedTime: elapsed,
                    positionY: presented.position.y,
                    scale: presented.transform.m11
                ))
            }
        }
        rowView.removeFromSuperview()
        return LineTrace(
            label: label,
            rowHeight: rowHeight,
            contentTopInset: Self.topInset(of: contentLayer, in: rowLayer),
            glyphCount: glyphLayers.count,
            tracks: tracks
        )
    }

    private static func glyphLayers(of contentLayer: AppleMusicLyrics.SyncedLyricsLineContentLayer) -> [CALayer] {
        let visualRowColorContainers = (contentLayer.sublayers ?? []).filter { candidateLayer in
            (candidateLayer.sublayers ?? []).contains { $0 is AppleMusicLyrics.LineProgressGradientLayer }
        }
        return visualRowColorContainers.flatMap { container in
            (container.mask?.sublayers ?? []).flatMap { colorLayer in colorLayer.mask?.sublayers ?? [] }
        }
    }

    private static func divergences(between first: LineTrace, and second: LineTrace, tolerance: CGFloat) -> [String] {
        var divergences: [String] = []
        for glyphIndex in 0 ..< min(first.tracks.count, second.tracks.count) {
            let samples = zip(first.tracks[glyphIndex], second.tracks[glyphIndex])
            for (firstSample, secondSample) in samples {
                let positionDifference = abs(firstSample.positionY - secondSample.positionY)
                let scaleDifference = abs(firstSample.scale - secondSample.scale)
                if positionDifference > tolerance || scaleDifference > 0.02 {
                    divergences.append(String(
                        format: "glyph %d @%.2fs y %.2f vs %.2f scale %.3f vs %.3f",
                        glyphIndex, firstSample.elapsedTime, firstSample.positionY, secondSample.positionY,
                        firstSample.scale, secondSample.scale
                    ))
                }
            }
        }
        return divergences
    }

    /// Where the content layer's top edge sits below the row's top edge, read
    /// through Core Animation so it is right whichever way up the row's backing
    /// layer is.
    private static func topInset(of contentLayer: CALayer, in rowLayer: CALayer) -> CGFloat {
        let frameInRow = contentLayer.convert(contentLayer.bounds, to: rowLayer)
        return rowLayer.contentsAreFlipped() ? frameInRow.minY : rowLayer.bounds.height - frameInRow.maxY
    }

    private static func writeTraceIfRequested(_ traces: [LineTrace]) {
        guard let directory = ProcessInfo.processInfo.environment["APPLE_MUSIC_LYRICS_TRACE_DIRECTORY"] else { return }
        for trace in traces {
            var lines = ["glyph\ttime\ty\tscale"]
            for (glyphIndex, track) in trace.tracks.enumerated() {
                for sample in track {
                    lines.append(String(format: "%d\t%.3f\t%.3f\t%.4f", glyphIndex, sample.elapsedTime, sample.positionY, sample.scale))
                }
            }
            try? lines.joined(separator: "\n").write(
                toFile: "\(directory)/\(trace.label).tsv",
                atomically: true,
                encoding: .utf8
            )
        }
    }
}
