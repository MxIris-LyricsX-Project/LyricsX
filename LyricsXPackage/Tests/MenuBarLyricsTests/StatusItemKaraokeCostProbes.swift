import CoreGraphics
import Foundation
import Testing
import StatusItemProbeSupport

/// What the karaoke progress costs in a real status item of a real app.
///
/// Every step the progress takes is a replicant snapshot round trip of the
/// whole item, the same as every frame of a scrolling line, so it is held to
/// the scroll's terms: steps of one device pixel, never more often than the
/// scroll's frame cap, and only when the edge reaches the next pixel. A line
/// of about 110 pt sung over four seconds needs about 55 half-point steps a
/// second, just under the cap. The CPU it costs is a property of the
/// machine and is printed, not asserted — it is the number behind the
/// switch being off by default.
@Suite(.serialized)
struct StatusItemKaraokeCostProbes {
    private static let line = "Let It Go, let it go"
    private static let measuredSeconds: Double = 4

    @Test(arguments: [StatusItemNeighbors.none, .playbackButtons])
    func karaokeProgressMovesInDevicePixelsAtMostAtTheFrameCap(_ neighbors: StatusItemNeighbors) async throws {
        let content = StatusItemContent(lyrics: .menuBarMarqueeLabel, neighbors: neighbors)
        let report = try await StatusItemProbeHostLauncher.run { reportPath in
            StatusItemProbeRequest(
                content: content,
                text: Self.line,
                scrollDriving: .karaoke,
                settleSeconds: 1.5,
                measuredSeconds: Self.measuredSeconds,
                reportPath: reportPath
            )
        }
        let drawBreakdown = report.drawCountsBySource
            .sorted { $0.key < $1.key }
            .map { "\($0.key) \($0.value)" }
            .joined(separator: ", ")
        print("""
        [status item karaoke] \(content): \(String(format: "%.1f", report.shareOfOneCore * 100))% CPU, \
        \(String(format: "%.1f", report.movesPerSecond)) moves/s of \(String(format: "%.2f", report.medianStep)) pt, \
        \(String(format: "%.1f", report.drawsPerSecond)) draws/s [\(drawBreakdown)]
        """)
        #expect(report.positionUpdates.count > 0, "the karaoke progress never moved")
        // One device pixel: half a point on Retina, a point on a 1x display.
        #expect(report.medianStep <= 1, "the karaoke progress moved \(report.medianStep) pt a step, more than a device pixel")
        #expect(report.movesPerSecond <= 66, "the karaoke progress moved \(report.movesPerSecond) times a second, above the 60 fps cap")
    }
}
