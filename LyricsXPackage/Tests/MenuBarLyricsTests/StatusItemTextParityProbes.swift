import Testing
import StatusItemProbeSupport

/// `MenuBarMarqueeLabel` must look exactly like the MarqueeLabel text field it
/// replaces. The comparison itself — `StatusItemSnapshotParity` — runs inside
/// the probe host, so this process never opens a window: on macOS 27.2 a
/// test process that does, launched from a terminal, leaves a Dock icon
/// behind for every run.
///
/// Drawings that merely look close fail this: an `NSAttributedString` drawn
/// in the cell's title rect differed in about 1,500 pixels per line, and
/// pull request 198's white alpha mask filled with `labelColor` turned
/// colour emoji into flat silhouettes.
@Suite(.serialized)
struct StatusItemTextParityProbes {
    @Test func menuBarMarqueeLabelMatchesTheTextField() async throws {
        let report = try await StatusItemProbeHostLauncher.run(as: StatusItemParityReport.self) { reportPath in
            .snapshotParity(reportPath: reportPath)
        }
        let identicalCount = report.comparedSnapshotCount - report.snapshotMismatches.count
        print("[status item parity] MenuBarMarqueeLabel: \(identicalCount)/\(report.comparedSnapshotCount) snapshots identical to the text field")
        for mismatch in (report.fieldSizeMismatches + report.snapshotMismatches).prefix(8) {
            print("[status item parity]   \(mismatch)")
        }
        #expect(report.comparedSnapshotCount == 32)
        #expect(report.snapshotMismatches.isEmpty, "MenuBarMarqueeLabel differs from the text field in \(report.snapshotMismatches.count) snapshots")
        #expect(report.fieldSizeMismatches.isEmpty, "MenuBarMarqueeLabel sizes \(report.fieldSizeMismatches.count) lines differently from sizeToFit")
        // The scrolled comparisons only mean something if the view's own
        // timing really froze the line where the probe aimed.
        #expect(report.frozenScrollPosition == report.expectedFrozenScrollPosition)
    }
}
