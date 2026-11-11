import AppKit
import Combine
import Testing
import LyricsXFoundation
@testable import AppleMusicLyricsPanel

/// Real `.lrcx` material for the probes below.
///
/// Uses the lyrics the app itself has already downloaded (`~/Music/LyricsX`),
/// overridable with `APPLE_MUSIC_LYRICS_FIXTURE_DIRECTORY`. Real files carry
/// everything synthetic fixtures forget: mixed CJK/Latin lines, missing or
/// messy time tags, translations, credit lines, interludes.
private enum LyricsLibrary {
    static let directory: URL? = {
        if let override = ProcessInfo.processInfo.environment["APPLE_MUSIC_LYRICS_FIXTURE_DIRECTORY"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let applicationDefault = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/LyricsX", isDirectory: true)
        return FileManager.default.fileExists(atPath: applicationDefault.path) ? applicationDefault : nil
    }()

    static var isAvailable: Bool {
        directory != nil
    }

    /// How many files the sweep reads. 40 keeps the probe fast; widen with the
    /// environment variable for an occasional full-library pass.
    static let sweepLimit = ProcessInfo.processInfo.environment["APPLE_MUSIC_LYRICS_FIXTURE_SWEEP_LIMIT"]
        .flatMap(Int.init) ?? 40

    static func fileURLs() -> [URL] {
        guard let directory,
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: directory, includingPropertiesForKeys: nil
              )
        else { return [] }
        return entries
            .filter { $0.pathExtension == "lrcx" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(sweepLimit)
            .map { $0 }
    }

    static func loadLyrics(from url: URL) -> Lyrics? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Lyrics(content)
    }

    /// The lines the panel actually shows — same filter as
    /// `SyncedLyricsContainerView.rebuildLineViews`.
    static func displayedLines(of lyrics: Lyrics) -> [(originalIndex: Int, line: LyricsLine)] {
        lyrics.lines.enumerated()
            .filter { $0.element.enabled && !$0.element.content.isEmpty }
            .map { (originalIndex: $0.offset, line: $0.element) }
    }
}

@Suite(.enabled(
    if: LyricsLibrary.isAvailable,
    "no .lrcx library found — populate ~/Music/LyricsX or set APPLE_MUSIC_LYRICS_FIXTURE_DIRECTORY"
))
struct LyricsLibraryFixtureProbes {
    /// Every displayed line of every sampled library file must survive the
    /// karaoke layout pipeline: `LineTextLayout.build` succeeds, produces a
    /// positive content box that contains its words, and `KaraokeFill` stays
    /// inside `0...1` no matter how messy the file's time tags are. The
    /// assertions are about the engine's robustness, not the data's
    /// cleanliness — real libraries contain non-monotonic and truncated tags,
    /// and the panel must shrug those off.
    @Test func everyDisplayedLibraryLineSurvivesKaraokeLayout() {
        let files = LyricsLibrary.fileURLs()
        #expect(!files.isEmpty, "library directory exists but holds no .lrcx files")

        let font = NSFont.systemFont(ofSize: 36, weight: .bold)
        // Core Text hangs whitespace at a wrap point outside the line box, and
        // a word keeps its trailing space — so an ink-bearing word may
        // legitimately poke one space width past the content box.
        let spaceHangAllowance = NSAttributedString(string: " ", attributes: [.font: font]).size().width + 2
        var parsedFileCount = 0
        var laidOutLineCount = 0
        var wordTimedLineCount = 0
        var violations: [String] = []

        for url in files {
            guard let lyrics = LyricsLibrary.loadLyrics(from: url) else {
                violations.append("\(url.lastPathComponent): failed to parse")
                continue
            }
            parsedFileCount += 1
            let displayedLines = LyricsLibrary.displayedLines(of: lyrics)
            if displayedLines.isEmpty {
                violations.append("\(url.lastPathComponent): parsed to zero displayable lines")
                continue
            }

            for (_, line) in displayedLines {
                let describe = { "\(url.lastPathComponent): '\(line.content.prefix(24))'" }
                let timings = line.wordTimingEntries ?? []
                let lineDuration = max(line.timetagDuration ?? 5, 0.5)
                let attributed = NSAttributedString(string: line.content, attributes: [.font: font])

                guard let layout = AppleMusicLyrics.LineTextLayout.build(
                    attributed: attributed,
                    content: line.content,
                    wordTimings: timings,
                    lineDuration: lineDuration,
                    textWidth: 460
                ) else {
                    violations.append("\(describe()): layout failed")
                    continue
                }
                laidOutLineCount += 1

                if layout.contentSize.width <= 0 || layout.contentSize.height <= 0 {
                    violations.append("\(describe()): degenerate content size \(layout.contentSize)")
                }
                if layout.words.isEmpty {
                    violations.append("\(describe()): layout produced no words")
                }
                for word in layout.words where !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // A word may hang one space width past the box per
                    // consecutive whitespace character it carries ('up   )'
                    // hangs three), but its ink may not escape.
                    let hangAllowance = spaceHangAllowance * CGFloat(max(1, Self.longestWhitespaceRun(in: word.text)))
                    if word.frame.minX < -1 || word.frame.maxX > layout.contentSize.width + hangAllowance {
                        violations.append("\(describe()): word '\(word.text)' escapes the content box \(word.frame)")
                    }
                }

                if !timings.isEmpty {
                    wordTimedLineCount += 1
                    for sampleFraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
                        let fill = AppleMusicLyrics.KaraokeFill.fraction(
                            elapsedTime: lineDuration * sampleFraction,
                            lineDuration: lineDuration,
                            wordTimings: timings,
                            totalCharacterCount: line.content.count,
                            mode: .characterLevel
                        )
                        if !(0 ... 1).contains(fill) {
                            violations.append("\(describe()): fill \(fill) out of range at \(sampleFraction)")
                        }
                    }
                    // Real files carry tags past the declared timetag duration,
                    // so "past the end" means past the later of the two.
                    let endTime = max(lineDuration, timings.map(\.timeOffset).max() ?? 0) + 0.001
                    let fillPastEnd = AppleMusicLyrics.KaraokeFill.fraction(
                        elapsedTime: endTime,
                        lineDuration: lineDuration,
                        wordTimings: timings,
                        totalCharacterCount: line.content.count,
                        mode: .characterLevel
                    )
                    if fillPastEnd != 1 {
                        violations.append("\(describe()): fill past the end is \(fillPastEnd), not 1")
                    }
                }
            }
        }

        #expect(parsedFileCount > 0, "not one library file parsed")
        #expect(laidOutLineCount > 0, "not one line reached layout")
        #expect(
            wordTimedLineCount > 0,
            "no word-timed line in the sample — the sweep proved nothing about karaoke layout"
        )
        #expect(
            violations.isEmpty,
            "\(violations.count) violation(s) across \(parsedFileCount) files; first five: \(violations.prefix(5).joined(separator: " ⏐ "))"
        )
    }

    /// Feeds a real library file to the actual scroll container and checks the
    /// panel-visible outcome: one row per displayable line, laid out top to
    /// bottom without overlap, and highlighting selects exactly the asked-for
    /// row. Runs the container off-window, which is a supported mode (the
    /// display link and scroll springs only arm inside a window).
    @Test @MainActor func containerViewDisplaysARealLibraryFile() throws {
        let (url, lyrics) = try #require(
            Self.firstSubstantialFile(),
            "no library file with ≥ 8 displayable lines and word timing in the sample"
        )
        let displayedLines = LyricsLibrary.displayedLines(of: lyrics)

        let container = AppleMusicLyrics.SyncedLyricsContainerView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 800)
        )
        container.update(lyrics: lyrics, highlightedLineIndex: nil, mainFontSize: 30, translationFontSize: 16)
        container.layoutSubtreeIfNeeded()

        let rowViews = Self.descendantViews(of: container, as: AppleMusicLyrics.SyncedLyricsLineView.self)
        #expect(
            rowViews.count == displayedLines.count,
            "\(url.lastPathComponent): \(displayedLines.count) displayable lines but \(rowViews.count) rows"
        )

        let rowsInDocumentOrder = rowViews.sorted { $0.frame.minY < $1.frame.minY }
        for row in rowsInDocumentOrder where row.frame.height <= 0 {
            Issue.record("row for line \(row.originalIndex) laid out with height \(row.frame.height)")
        }
        for (upper, lower) in zip(rowsInDocumentOrder, rowsInDocumentOrder.dropFirst())
            where lower.frame.minY < upper.frame.maxY - 0.5 {
            Issue.record("rows \(upper.originalIndex) and \(lower.originalIndex) overlap")
        }

        // Highlight a middle line and check exactly that row lights up.
        let middle = displayedLines[displayedLines.count / 2]
        container.update(
            lyrics: lyrics,
            highlightedLineIndex: middle.originalIndex,
            mainFontSize: 30,
            translationFontSize: 16
        )
        let highlightedRows = rowViews.filter(\.isHighlighted)
        #expect(highlightedRows.map(\.originalIndex) == [middle.originalIndex])
    }

    /// End to end through the real panel: inject lyrics parsed from a library
    /// file through the same publisher seam the app uses, and check the panel
    /// builds its rows and follows line-index changes. This is the extraction's
    /// contract — the whole panel drivable without the app or a playing track.
    @Test @MainActor func panelViewControllerDisplaysInjectedLibraryLyrics() async throws {
        let (_, lyrics) = try #require(Self.firstSubstantialFile())
        let displayedLines = LyricsLibrary.displayedLines(of: lyrics)

        let lyricsSubject = CurrentValueSubject<Lyrics?, Never>(nil)
        let lineIndexSubject = CurrentValueSubject<Int?, Never>(nil)
        let panelViewController = AppleMusicLyrics.LyricsPanelViewController(
            lyricsPublisher: lyricsSubject.eraseToAnyPublisher(),
            currentLineIndexPublisher: lineIndexSubject.eraseToAnyPublisher()
        )

        // A window that is never ordered in: enough for AppKit to load the view
        // hierarchy and run layout, without putting anything on screen.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = panelViewController
        panelViewController.view.layoutSubtreeIfNeeded()

        lyricsSubject.send(lyrics)
        // Delivery hops through `receive(on: DispatchQueue.main)`; suspend so
        // the main queue can run it.
        try await Task.sleep(seconds: 0.3)

        let rowViews = Self.descendantViews(
            of: panelViewController.view,
            as: AppleMusicLyrics.SyncedLyricsLineView.self
        )
        #expect(rowViews.count == displayedLines.count, "panel built \(rowViews.count) rows for \(displayedLines.count) displayable lines")

        let target = displayedLines[min(2, displayedLines.count - 1)]
        lineIndexSubject.send(target.originalIndex)
        try await Task.sleep(seconds: 0.3)
        let highlightedRows = rowViews.filter(\.isHighlighted)
        #expect(highlightedRows.map(\.originalIndex) == [target.originalIndex])
    }

    // MARK: Helpers

    /// First sampled file that gives the display-level probes something worth
    /// showing: several lines, and word timing on at least one of them.
    private static func firstSubstantialFile() -> (URL, Lyrics)? {
        for url in LyricsLibrary.fileURLs() {
            guard let lyrics = LyricsLibrary.loadLyrics(from: url) else { continue }
            let displayedLines = LyricsLibrary.displayedLines(of: lyrics)
            let hasWordTiming = displayedLines.contains { !($0.line.wordTimingEntries ?? []).isEmpty }
            if displayedLines.count >= 8, hasWordTiming {
                return (url, lyrics)
            }
        }
        return nil
    }

    private static func longestWhitespaceRun(in text: String) -> Int {
        var longestRun = 0
        var currentRun = 0
        for character in text {
            if character.isWhitespace {
                currentRun += 1
                longestRun = max(longestRun, currentRun)
            } else {
                currentRun = 0
            }
        }
        return longestRun
    }

    private static func descendantViews<ViewType: NSView>(of root: NSView, as type: ViewType.Type) -> [ViewType] {
        var found: [ViewType] = []
        func walk(_ view: NSView) {
            if let match = view as? ViewType { found.append(match) }
            for subview in view.subviews {
                walk(subview)
            }
        }
        walk(root)
        return found
    }
}
