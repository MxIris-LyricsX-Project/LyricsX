import Foundation
import Testing
import StatusItemProbeSupport

/// The lyric line draws in a real status item without CoreGraphics
/// complaining.
///
/// It used to ask every context it drew into for its colour space through
/// `CGContext.colorSpace`, which is `CGBitmapContextGetColorSpace`. Of the
/// draws a status item makes per snapshot only the one into the snapshot
/// itself is a bitmap context; the others record into a display list, and
/// each of those logged "CGBitmapContextGetColorSpace: invalid context". With
/// the line moving that came to hundreds of lines a second — over a thousand
/// in this probe's two seconds — enough to keep Xcode busy rendering its
/// console long after the app had quit.
@Suite(.serialized)
struct StatusItemDrawingErrorProbes {
    @Test func lyricLineDrawsWithoutCoreGraphicsErrors() async throws {
        let report = try await StatusItemProbeHostLauncher.run { reportPath in
            StatusItemProbeRequest(
                content: StatusItemContent(lyrics: .menuBarMarqueeLabel, neighbors: .none),
                text: "Let It Go, let it go",
                scrollDriving: .karaoke,
                settleSeconds: 1,
                measuredSeconds: 2,
                reportPath: reportPath
            )
        }
        try #require(report.drawCountsBySource["menuBarMarqueeLabel", default: 0] > 0, "the lyric line never drew")
        let errorMessages = try #require(report.coreGraphicsErrorMessages, "the probe host could not read its own log")
        #expect(
            errorMessages.isEmpty,
            "CoreGraphics logged \(errorMessages.count) errors while the lyric line drew, the first: \(errorMessages.first ?? "")"
        )
    }
}
