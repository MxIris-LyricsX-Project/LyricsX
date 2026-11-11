import Foundation
import Testing
import StatusItemProbeSupport

/// Reproduction loop for the idle CPU burn on macOS 26 and later: LyricsX
/// 1.9.0 sat at ~49% CPU on macOS 27.2 with nothing playing, and a sample put
/// nearly half of its main thread in `NSStatusItem` re-snapshotting the menu
/// bar item for its replicant — drawing MarqueeLabel's text field over and
/// over although the text never changed.
///
/// Each case runs the lyric line in a real status item of a real (bundled,
/// Launch Services–launched) app, lets it settle, then leaves it alone. A
/// line that is not changing must stop drawing.
///
/// The loop is intermittent: the same text field settles in some launches
/// and spins at ~300 snapshots a second in others. Each case therefore runs
/// several launches, and one spinning launch fails it. MarqueeLabel's text
/// field stays in as the reference that does spin, recorded as a known issue
/// of the platform rather than failing the suite.
@Suite(.serialized)
struct StatusItemIdleRedrawProbes {
    private static let launchesPerCase = 3

    @Test(arguments: LyricsRendering.allCases, StatusItemNeighbors.allCases)
    func lyricLineStaysIdleOnceSettled(_ lyrics: LyricsRendering, _ neighbors: StatusItemNeighbors) async throws {
        let content = StatusItemContent(lyrics: lyrics, neighbors: neighbors)
        var spinningLaunchCount = 0
        var launchSummaries: [String] = []
        for _ in 0 ..< Self.launchesPerCase {
            let report = try await StatusItemProbeHostLauncher.run { reportPath in
                StatusItemProbeRequest(
                    content: content,
                    text: "LyricsX",
                    settleSeconds: 1.5,
                    measuredSeconds: 2,
                    reportPath: reportPath
                )
            }
            if report.drawsPerSecond >= 1 || report.shareOfOneCore >= 0.05 {
                spinningLaunchCount += 1
            }
            launchSummaries.append("\(String(format: "%.1f", report.shareOfOneCore * 100))% \(String(format: "%.0f", report.drawsPerSecond))/s")
        }
        print("[status item idle] \(content): \(spinningLaunchCount)/\(Self.launchesPerCase) launches kept drawing — \(launchSummaries.joined(separator: " · "))")
        if lyrics == .marqueeTextField {
            withKnownIssue("An NSTextField in a status item makes macOS 26+ re-snapshot it forever", isIntermittent: true) {
                #expect(spinningLaunchCount == 0)
            }
        } else {
            #expect(spinningLaunchCount == 0, "\(content) kept drawing with nothing changing in \(spinningLaunchCount) of \(Self.launchesPerCase) launches")
        }
    }
}
