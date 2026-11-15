import Testing
import StatusItemProbeSupport

/// The menu bar line's karaoke progress, snapshotted the way the menu bar's
/// replicants are. `StatusItemKaraokeRendering` runs inside the probe host,
/// so this process never opens a window.
///
/// With progress the line is two copies cut at one pixel edge — the sung
/// drawing before it, the plain one after it — so it costs no more to draw
/// than the line without progress, and a line nobody has started singing is
/// the line without progress, pixel for pixel. The edge sits where the
/// characters are drawn, stops while playback is paused, and a long line
/// sung again starts its scroll over so its progress starts in view.
@Suite(.serialized)
struct StatusItemKaraokeProbes {
    @Test func karaokeProgressIsTheSungAndThePlainDrawingCutAtOneEdge() async throws {
        let report = try await StatusItemProbeHostLauncher.run(as: StatusItemKaraokeReport.self) { reportPath in
            .karaokeRendering(reportPath: reportPath)
        }
        let problems = report.compositionMismatches + report.unsungMismatches + report.indistinguishableSungLines
            + report.inkAlignmentErrors + report.clockMismatches
        print("[status item karaoke] \(report.comparedSnapshotCount) snapshots, \(problems.count) problems")
        for problem in problems.prefix(12) {
            print("[status item karaoke]   \(problem)")
        }
        #expect(report.comparedSnapshotCount == 36)
        #expect(report.compositionMismatches.isEmpty, "\(report.compositionMismatches.count) snapshots with progress are not the two drawings cut at the edge")
        #expect(report.unsungMismatches.isEmpty, "\(report.unsungMismatches.count) lines not yet sung differ from the line without progress")
        #expect(report.indistinguishableSungLines.isEmpty, "\(report.indistinguishableSungLines.count) sung lines look like the plain line")
        #expect(report.inkAlignmentErrors.isEmpty, "the measured characters miss the drawn ink")
        #expect(report.clockMismatches.isEmpty, "\(report.clockMismatches.count) pauses or resumes left the progress in the wrong place")
        #expect(report.restartedScrollPosition == 0, "a long line sung again kept its scroll position")
        #expect(report.reanchoredScrollPosition == report.expectedReanchoredScrollPosition, "re-anchoring the same line moved its scroll")
        #expect(report.newTextDroppedProgress, "new text kept the previous line's progress")
        // A right-to-left line laid its characters out against the edge: the
        // whole line started out sung and emptied from the left.
        #expect(report.rightToLeftLinesShowingProgress.isEmpty, "lines with right-to-left text show progress: \(report.rightToLeftLinesShowingProgress)")
        // Every app activation re-sends the line, switch off or on; each time
        // it stopped and restarted a scrolling line's display link.
        #expect(report.motionUpdatesForRepeatedAbsentProgress == 0, "telling a line without progress so again restarted its clocks \(report.motionUpdatesForRepeatedAbsentProgress) times")
        #expect(report.motionUpdatesForRepeatedConsistentProgress == 0, "re-sending a line's own timing at the time it shows restarted its clocks \(report.motionUpdatesForRepeatedConsistentProgress) times")
        #expect(report.jumpReanchoredProgress, "a jump in playback did not move the progress")
        // The Lab's colour well: a custom colour, and back to the accent colour.
        #expect(report.sungColorProblems.isEmpty, "\(report.sungColorProblems)")
    }
}
