import CoreGraphics
import Foundation
import Testing
import StatusItemProbeSupport

/// A long line must scroll as smoothly as MarqueeLabel's, for less CPU,
/// measured in a real status item of a real app.
///
/// The reference is MarqueeLabel's own motion: a display-rate
/// `animator().frame` animation that moves its field one whole point per
/// frame on a 60 Hz display. `MenuBarMarqueeLabel` moves at up to 60 frames a
/// second in whole device pixels; an earlier 30 fps cap was rejected as
/// visibly choppy, which is what the smoothness half of the assertion guards.
///
/// Every frame the line moves costs AppKit a snapshot for each of the item's
/// replicants (two on a one-display, two-Space Mac), and each snapshot forces
/// every view in the item to draw again. The fixed part of that round trip
/// is most of the cost and is the same for both, so the margin comes from
/// what each frame draws: a copied bitmap here, a laid-out text field there.
/// The lyric line is measured alone so the playback buttons — which pay the
/// same per-frame redraws beside either one — do not drown the difference;
/// `reportsTheCostBesideThePlaybackButtons` prints the shipped configuration.
/// Absolute CPU is a property of the machine, so the assertions are relative.
@Suite(.serialized)
struct StatusItemScrollCostProbes {
    private static let longLine = "终于做了这个决定，别人怎么说我不理，要随着我的心，大步踏出去"

    @Test func scrollsAsSmoothlyAsTheTextFieldForLessCPU() async throws {
        var textFieldReports: [StatusItemProbeReport] = []
        var marqueeLabelReports: [StatusItemProbeReport] = []
        for _ in 0 ..< Self.launchesPerRendering {
            try textFieldReports.append(await Self.measure(.marqueeTextField, scrollDriving: .marqueeAnimation, neighbors: .none))
            try marqueeLabelReports.append(await Self.measure(.menuBarMarqueeLabel, scrollDriving: .ownTiming, neighbors: .none))
        }
        let textField = Self.median(of: textFieldReports)
        let marqueeLabel = Self.median(of: marqueeLabelReports)
        print("""
        [status item scroll] medians of \(Self.launchesPerRendering): text field \(String(format: "%.1f", textField.cpuShare * 100))% CPU, \
        MenuBarMarqueeLabel \(String(format: "%.1f", marqueeLabel.cpuShare * 100))% CPU
        """)
        #expect(
            marqueeLabel.movesPerSecond >= textField.movesPerSecond * 0.9,
            "MenuBarMarqueeLabel moved \(marqueeLabel.movesPerSecond) times a second, the text field \(textField.movesPerSecond)"
        )
        #expect(
            marqueeLabel.medianStep <= textField.medianStep + 0.5,
            "MenuBarMarqueeLabel moved \(marqueeLabel.medianStep) pt a frame, the text field \(textField.medianStep) pt"
        )
        #expect(
            marqueeLabel.drawsPerMove <= textField.drawsPerMove,
            "MenuBarMarqueeLabel drew \(marqueeLabel.drawsPerMove) times per move, the text field \(textField.drawsPerMove)"
        )
        #expect(
            marqueeLabel.cpuShare < textField.cpuShare,
            "MenuBarMarqueeLabel cost \(marqueeLabel.cpuShare * 100)% CPU scrolling, the text field \(textField.cpuShare * 100)%"
        )
    }

    /// The item as shipped, with the three playback buttons. Printed only.
    @Test func reportsTheCostBesideThePlaybackButtons() async throws {
        _ = try await Self.measure(.marqueeTextField, scrollDriving: .marqueeAnimation, neighbors: .playbackButtons)
        _ = try await Self.measure(.menuBarMarqueeLabel, scrollDriving: .ownTiming, neighbors: .playbackButtons)
    }

    /// A single launch's CPU share swings by about five points either way —
    /// as much as the margin being measured — so the comparison takes the
    /// median of a few.
    private static let launchesPerRendering = 3

    private struct MedianMeasurement {
        let cpuShare: Double
        let movesPerSecond: Double
        let medianStep: CGFloat
        let drawsPerMove: Double
    }

    private static func median(of reports: [StatusItemProbeReport]) -> MedianMeasurement {
        func middle<Value: Comparable>(_ values: [Value]) -> Value {
            values.sorted()[values.count / 2]
        }
        return MedianMeasurement(
            cpuShare: middle(reports.map(\.shareOfOneCore)),
            movesPerSecond: middle(reports.map(\.movesPerSecond)),
            medianStep: middle(reports.map(\.medianStep)),
            drawsPerMove: middle(reports.map { Double($0.drawCountsBySource.values.reduce(0, +)) / Double(max(1, $0.positionUpdates.count)) })
        )
    }

    private static func measure(
        _ lyrics: LyricsRendering,
        scrollDriving: ScrollDriving,
        neighbors: StatusItemNeighbors
    ) async throws -> StatusItemProbeReport {
        let content = StatusItemContent(lyrics: lyrics, neighbors: neighbors)
        let report = try await StatusItemProbeHostLauncher.run { reportPath in
            StatusItemProbeRequest(
                content: content,
                text: longLine,
                scrollDriving: scrollDriving,
                settleSeconds: 1.5,
                measuredSeconds: 4,
                reportPath: reportPath
            )
        }
        let drawBreakdown = report.drawCountsBySource
            .sorted { $0.key < $1.key }
            .map { "\($0.key) \($0.value)" }
            .joined(separator: ", ")
        print("""
        [status item scroll] \(content) \(scrollDriving): \(String(format: "%.1f", report.shareOfOneCore * 100))% CPU, \
        \(String(format: "%.1f", report.movesPerSecond)) moves/s of \(String(format: "%.2f", report.medianStep)) pt, \
        \(String(format: "%.1f", report.drawsPerSecond)) draws/s [\(drawBreakdown)]
        """)
        return report
    }
}
