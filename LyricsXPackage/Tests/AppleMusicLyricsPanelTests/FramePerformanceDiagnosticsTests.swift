import Foundation
import Testing
@testable import AppleMusicLyricsPanel

struct FramePerformanceDiagnosticsTests {
    @Test func detailedPerFrameSignpostsAreOptIn() {
        #expect(
            !AppleMusicLyrics.FramePerformanceDiagnosticsPolicy
                .areDetailedFrameSignpostsEnabled(environment: [:])
        )
        #expect(
            AppleMusicLyrics.FramePerformanceDiagnosticsPolicy
                .areDetailedFrameSignpostsEnabled(environment: [
                    AppleMusicLyrics.FramePerformanceDiagnosticsPolicy
                        .detailedFrameSignpostEnvironmentKey: "1",
                ])
        )
        #expect(
            !AppleMusicLyrics.FramePerformanceDiagnosticsPolicy
                .areDetailedFrameSignpostsEnabled(environment: [
                    AppleMusicLyrics.FramePerformanceDiagnosticsPolicy
                        .detailedFrameSignpostEnvironmentKey: "true",
                ])
        )
    }

    @Test func reportsNominalAndMeasuredFrameRates() throws {
        var accumulator = AppleMusicLyrics.FrameTimingAccumulator(reportingInterval: 1)

        for frameIndex in 0 ... 4 {
            let timestamp = Double(frameIndex) * 0.25
            let report = accumulator.record(
                sourceTimestamp: timestamp,
                arrivalTimestamp: timestamp,
                targetTimestamp: timestamp,
                expectedFrameDuration: 0.25
            )
            if frameIndex < 4 {
                #expect(report == nil)
            } else {
                let report = try #require(report)
                #expect(report.sampledFrameCount == 5)
                #expect(report.nominalFramesPerSecond == 4)
                #expect(report.sourceFramesPerSecond == 4)
                #expect(report.arrivalFramesPerSecond == 4)
                #expect(report.maximumSourceGapMilliseconds == 250)
                #expect(report.maximumArrivalGapMilliseconds == 250)
                #expect(report.maximumDeliveryLatenessMilliseconds == 0)
                #expect(report.missedSourceFrameCount == 0)
                #expect(report.missedArrivalFrameCount == 0)
            }
        }
    }

    @Test func distinguishesSourceCadenceFromMainQueueDelivery() throws {
        var accumulator = AppleMusicLyrics.FrameTimingAccumulator(reportingInterval: 1.25)
        let sourceTimestamps: [TimeInterval] = [0, 0.25, 0.5, 0.75, 1]
        let arrivalTimestamps: [TimeInterval] = [0, 0.25, 0.5, 1, 1.25]
        var finalReport: AppleMusicLyrics.FrameTimingReport?

        for sampleIndex in sourceTimestamps.indices {
            finalReport = accumulator.record(
                sourceTimestamp: sourceTimestamps[sampleIndex],
                arrivalTimestamp: arrivalTimestamps[sampleIndex],
                targetTimestamp: sourceTimestamps[sampleIndex],
                expectedFrameDuration: 0.25
            ) ?? finalReport
        }

        let report = try #require(finalReport)
        #expect(report.sourceFramesPerSecond == 4)
        #expect(abs(report.arrivalFramesPerSecond - 3.2) < 0.0001)
        #expect(report.maximumSourceGapMilliseconds == 250)
        #expect(report.maximumArrivalGapMilliseconds == 500)
        #expect(report.maximumDeliveryLatenessMilliseconds == 250)
        #expect(report.missedSourceFrameCount == 0)
        #expect(report.missedArrivalFrameCount == 1)
    }

    @Test func reportsMissingSourceFrames() throws {
        var accumulator = AppleMusicLyrics.FrameTimingAccumulator(reportingInterval: 1)
        let timestamps: [TimeInterval] = [0, 0.25, 0.75, 1]
        var finalReport: AppleMusicLyrics.FrameTimingReport?

        for timestamp in timestamps {
            finalReport = accumulator.record(
                sourceTimestamp: timestamp,
                arrivalTimestamp: timestamp,
                targetTimestamp: timestamp,
                expectedFrameDuration: 0.25
            ) ?? finalReport
        }

        let report = try #require(finalReport)
        #expect(report.sourceFramesPerSecond == 3)
        #expect(report.maximumSourceGapMilliseconds == 500)
        #expect(report.missedSourceFrameCount == 1)
    }

    @Test func reportsAndResetsFrameWorkTiming() throws {
        var accumulator = AppleMusicLyrics.FrameWorkTimingAccumulator()
        accumulator.record(duration: 0.004, expectedFrameDuration: 0.010)
        accumulator.record(duration: 0.020, expectedFrameDuration: 0.010)

        let optionalReport = accumulator.takeReport()
        let report = try #require(optionalReport)
        #expect(report.sampledFrameCount == 2)
        #expect(abs(report.averageDurationMilliseconds - 12) < 0.0001)
        #expect(abs(report.maximumDurationMilliseconds - 20) < 0.0001)
        #expect(report.frameBudgetOverrunCount == 1)
        #expect(accumulator.takeReport() == nil)
    }

    @Test func reportsGradientFrameStageAveragesAndMaxima() throws {
        var accumulator = AppleMusicLyrics.GradientFrameStageTimingAccumulator()
        accumulator.record(
            .init(
                renderPassAcquisitionDuration: 0.010,
                drawableAcquisitionDuration: 0.002,
                commandBufferCreationDuration: 0.001,
                renderCommandEncoderCreationDuration: 0.003,
                commandEncodingDuration: 0.004,
                commandSubmissionDuration: 0.005,
                totalDuration: 0.025,
                wasOnMainThread: true
            ),
            expectedFrameDuration: 0.016
        )
        accumulator.record(
            .init(
                renderPassAcquisitionDuration: 0.004,
                drawableAcquisitionDuration: 0.001,
                commandBufferCreationDuration: 0.002,
                renderCommandEncoderCreationDuration: 0.001,
                commandEncodingDuration: 0.002,
                commandSubmissionDuration: 0.002,
                totalDuration: 0.012,
                wasOnMainThread: false
            ),
            expectedFrameDuration: 0.016
        )

        let optionalReport = accumulator.takeReport()
        let report = try #require(optionalReport)
        #expect(report.sampledFrameCount == 2)
        #expect(report.mainThreadFrameCount == 1)
        #expect(report.frameBudgetOverrunCount == 1)
        #expect(abs(report.averageRenderPassAcquisitionMilliseconds - 7) < 0.0001)
        #expect(abs(report.maximumRenderPassAcquisitionMilliseconds - 10) < 0.0001)
        #expect(abs(report.averageDrawableAcquisitionMilliseconds - 1.5) < 0.0001)
        #expect(abs(report.maximumDrawableAcquisitionMilliseconds - 2) < 0.0001)
        #expect(abs(report.averageCommandBufferCreationMilliseconds - 1.5) < 0.0001)
        #expect(abs(report.maximumCommandBufferCreationMilliseconds - 2) < 0.0001)
        #expect(abs(report.averageRenderCommandEncoderCreationMilliseconds - 2) < 0.0001)
        #expect(abs(report.maximumRenderCommandEncoderCreationMilliseconds - 3) < 0.0001)
        #expect(abs(report.averageCommandEncodingMilliseconds - 3) < 0.0001)
        #expect(abs(report.maximumCommandEncodingMilliseconds - 4) < 0.0001)
        #expect(abs(report.averageCommandSubmissionMilliseconds - 3.5) < 0.0001)
        #expect(abs(report.maximumCommandSubmissionMilliseconds - 5) < 0.0001)
        #expect(abs(report.averageTotalDurationMilliseconds - 18.5) < 0.0001)
        #expect(abs(report.maximumTotalDurationMilliseconds - 25) < 0.0001)
        #expect(accumulator.takeReport() == nil)
    }
}
