import Foundation

extension AppleMusicLyrics {
    enum FramePerformanceDiagnosticsPolicy {
        static let detailedFrameSignpostEnvironmentKey = "LYRICSX_DETAILED_FRAME_SIGNPOSTS"
        static let detailedFrameSignpostingIsEnabled =
            areDetailedFrameSignpostsEnabled()

        static func areDetailedFrameSignpostsEnabled(
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> Bool {
            environment[detailedFrameSignpostEnvironmentKey] == "1"
        }
    }

    struct FrameTimingReport: Equatable, Sendable {
        let sampledFrameCount: Int
        let nominalFramesPerSecond: Double
        let sourceFramesPerSecond: Double
        let arrivalFramesPerSecond: Double
        let maximumSourceGapMilliseconds: Double
        let maximumArrivalGapMilliseconds: Double
        let maximumDeliveryLatenessMilliseconds: Double
        let missedSourceFrameCount: Int
        let missedArrivalFrameCount: Int
    }

    struct FrameTimingAccumulator {
        private let reportingInterval: TimeInterval
        private var firstSourceTimestamp: TimeInterval?
        private var firstArrivalTimestamp: TimeInterval?
        private var previousSourceTimestamp: TimeInterval?
        private var previousArrivalTimestamp: TimeInterval?
        private var sampledFrameCount = 0
        private var expectedFrameDurationTotal: TimeInterval = 0
        private var maximumSourceGap: TimeInterval = 0
        private var maximumArrivalGap: TimeInterval = 0
        private var maximumDeliveryLateness: TimeInterval = 0
        private var missedSourceFrameCount = 0
        private var missedArrivalFrameCount = 0

        init(reportingInterval: TimeInterval = 2) {
            precondition(reportingInterval > 0)
            self.reportingInterval = reportingInterval
        }

        mutating func record(
            sourceTimestamp: TimeInterval,
            arrivalTimestamp: TimeInterval,
            targetTimestamp: TimeInterval,
            expectedFrameDuration: TimeInterval
        ) -> FrameTimingReport? {
            guard sourceTimestamp.isFinite,
                  arrivalTimestamp.isFinite,
                  targetTimestamp.isFinite,
                  expectedFrameDuration.isFinite,
                  expectedFrameDuration > 0
            else {
                return nil
            }

            if firstSourceTimestamp == nil {
                beginWindow(
                    sourceTimestamp: sourceTimestamp,
                    arrivalTimestamp: arrivalTimestamp,
                    targetTimestamp: targetTimestamp,
                    expectedFrameDuration: expectedFrameDuration
                )
                return nil
            }

            if let previousSourceTimestamp {
                let sourceGap = max(0, sourceTimestamp - previousSourceTimestamp)
                maximumSourceGap = max(maximumSourceGap, sourceGap)
                missedSourceFrameCount += Self.missedFrameCount(
                    forGap: sourceGap,
                    expectedFrameDuration: expectedFrameDuration
                )
            }
            if let previousArrivalTimestamp {
                let arrivalGap = max(0, arrivalTimestamp - previousArrivalTimestamp)
                maximumArrivalGap = max(maximumArrivalGap, arrivalGap)
                missedArrivalFrameCount += Self.missedFrameCount(
                    forGap: arrivalGap,
                    expectedFrameDuration: expectedFrameDuration
                )
            }

            previousSourceTimestamp = sourceTimestamp
            previousArrivalTimestamp = arrivalTimestamp
            sampledFrameCount += 1
            expectedFrameDurationTotal += expectedFrameDuration
            maximumDeliveryLateness = max(
                maximumDeliveryLateness,
                max(0, arrivalTimestamp - targetTimestamp)
            )

            guard let firstSourceTimestamp,
                  let firstArrivalTimestamp,
                  arrivalTimestamp - firstArrivalTimestamp >= reportingInterval
            else {
                return nil
            }

            let sourceElapsedDuration = max(0, sourceTimestamp - firstSourceTimestamp)
            let arrivalElapsedDuration = max(0, arrivalTimestamp - firstArrivalTimestamp)
            let measuredIntervalCount = max(0, sampledFrameCount - 1)
            let report = FrameTimingReport(
                sampledFrameCount: sampledFrameCount,
                nominalFramesPerSecond: Double(sampledFrameCount) / expectedFrameDurationTotal,
                sourceFramesPerSecond: Self.framesPerSecond(
                    measuredIntervalCount: measuredIntervalCount,
                    elapsedDuration: sourceElapsedDuration
                ),
                arrivalFramesPerSecond: Self.framesPerSecond(
                    measuredIntervalCount: measuredIntervalCount,
                    elapsedDuration: arrivalElapsedDuration
                ),
                maximumSourceGapMilliseconds: maximumSourceGap * 1_000,
                maximumArrivalGapMilliseconds: maximumArrivalGap * 1_000,
                maximumDeliveryLatenessMilliseconds: maximumDeliveryLateness * 1_000,
                missedSourceFrameCount: missedSourceFrameCount,
                missedArrivalFrameCount: missedArrivalFrameCount
            )

            beginWindow(
                sourceTimestamp: sourceTimestamp,
                arrivalTimestamp: arrivalTimestamp,
                targetTimestamp: targetTimestamp,
                expectedFrameDuration: expectedFrameDuration
            )
            return report
        }

        private mutating func beginWindow(
            sourceTimestamp: TimeInterval,
            arrivalTimestamp: TimeInterval,
            targetTimestamp: TimeInterval,
            expectedFrameDuration: TimeInterval
        ) {
            firstSourceTimestamp = sourceTimestamp
            firstArrivalTimestamp = arrivalTimestamp
            previousSourceTimestamp = sourceTimestamp
            previousArrivalTimestamp = arrivalTimestamp
            sampledFrameCount = 1
            expectedFrameDurationTotal = expectedFrameDuration
            maximumSourceGap = 0
            maximumArrivalGap = 0
            maximumDeliveryLateness = max(0, arrivalTimestamp - targetTimestamp)
            missedSourceFrameCount = 0
            missedArrivalFrameCount = 0
        }

        private static func framesPerSecond(
            measuredIntervalCount: Int,
            elapsedDuration: TimeInterval
        ) -> Double {
            guard elapsedDuration > 0 else { return 0 }
            return Double(measuredIntervalCount) / elapsedDuration
        }

        private static func missedFrameCount(
            forGap gap: TimeInterval,
            expectedFrameDuration: TimeInterval
        ) -> Int {
            guard gap > 0 else { return 0 }
            let representedFrameCount = Int((gap / expectedFrameDuration).rounded())
            return max(0, representedFrameCount - 1)
        }
    }

    struct FrameWorkTimingReport: Equatable, Sendable {
        let sampledFrameCount: Int
        let averageDurationMilliseconds: Double
        let maximumDurationMilliseconds: Double
        let frameBudgetOverrunCount: Int
    }

    struct FrameWorkTimingAccumulator {
        private var sampledFrameCount = 0
        private var durationTotal: TimeInterval = 0
        private var maximumDuration: TimeInterval = 0
        private var frameBudgetOverrunCount = 0

        mutating func record(
            duration: TimeInterval,
            expectedFrameDuration: TimeInterval
        ) {
            guard duration.isFinite,
                  duration >= 0,
                  expectedFrameDuration.isFinite,
                  expectedFrameDuration > 0
            else {
                return
            }

            sampledFrameCount += 1
            durationTotal += duration
            maximumDuration = max(maximumDuration, duration)
            if duration > expectedFrameDuration {
                frameBudgetOverrunCount += 1
            }
        }

        mutating func takeReport() -> FrameWorkTimingReport? {
            guard sampledFrameCount > 0 else { return nil }

            let report = FrameWorkTimingReport(
                sampledFrameCount: sampledFrameCount,
                averageDurationMilliseconds: durationTotal / Double(sampledFrameCount) * 1_000,
                maximumDurationMilliseconds: maximumDuration * 1_000,
                frameBudgetOverrunCount: frameBudgetOverrunCount
            )
            self = FrameWorkTimingAccumulator()
            return report
        }
    }

    struct GradientFrameStageTimingSample: Equatable, Sendable {
        let renderPassAcquisitionDuration: TimeInterval
        let drawableAcquisitionDuration: TimeInterval
        let commandBufferCreationDuration: TimeInterval
        let renderCommandEncoderCreationDuration: TimeInterval
        let commandEncodingDuration: TimeInterval
        let commandSubmissionDuration: TimeInterval
        let totalDuration: TimeInterval
        let wasOnMainThread: Bool

        fileprivate var isValid: Bool {
            renderPassAcquisitionDuration.isFinite
                && renderPassAcquisitionDuration >= 0
                && drawableAcquisitionDuration.isFinite
                && drawableAcquisitionDuration >= 0
                && commandBufferCreationDuration.isFinite
                && commandBufferCreationDuration >= 0
                && renderCommandEncoderCreationDuration.isFinite
                && renderCommandEncoderCreationDuration >= 0
                && commandEncodingDuration.isFinite
                && commandEncodingDuration >= 0
                && commandSubmissionDuration.isFinite
                && commandSubmissionDuration >= 0
                && totalDuration.isFinite
                && totalDuration >= 0
        }
    }

    struct GradientFrameStageTimingReport: Equatable, Sendable {
        let sampledFrameCount: Int
        let mainThreadFrameCount: Int
        let frameBudgetOverrunCount: Int
        let averageRenderPassAcquisitionMilliseconds: Double
        let maximumRenderPassAcquisitionMilliseconds: Double
        let averageDrawableAcquisitionMilliseconds: Double
        let maximumDrawableAcquisitionMilliseconds: Double
        let averageCommandBufferCreationMilliseconds: Double
        let maximumCommandBufferCreationMilliseconds: Double
        let averageRenderCommandEncoderCreationMilliseconds: Double
        let maximumRenderCommandEncoderCreationMilliseconds: Double
        let averageCommandEncodingMilliseconds: Double
        let maximumCommandEncodingMilliseconds: Double
        let averageCommandSubmissionMilliseconds: Double
        let maximumCommandSubmissionMilliseconds: Double
        let averageTotalDurationMilliseconds: Double
        let maximumTotalDurationMilliseconds: Double
    }

    struct GradientFrameStageTimingAccumulator {
        private var sampledFrameCount = 0
        private var mainThreadFrameCount = 0
        private var frameBudgetOverrunCount = 0
        private var renderPassAcquisitionDurationTotal: TimeInterval = 0
        private var maximumRenderPassAcquisitionDuration: TimeInterval = 0
        private var drawableAcquisitionDurationTotal: TimeInterval = 0
        private var maximumDrawableAcquisitionDuration: TimeInterval = 0
        private var commandBufferCreationDurationTotal: TimeInterval = 0
        private var maximumCommandBufferCreationDuration: TimeInterval = 0
        private var renderCommandEncoderCreationDurationTotal: TimeInterval = 0
        private var maximumRenderCommandEncoderCreationDuration: TimeInterval = 0
        private var commandEncodingDurationTotal: TimeInterval = 0
        private var maximumCommandEncodingDuration: TimeInterval = 0
        private var commandSubmissionDurationTotal: TimeInterval = 0
        private var maximumCommandSubmissionDuration: TimeInterval = 0
        private var totalDuration: TimeInterval = 0
        private var maximumTotalDuration: TimeInterval = 0

        mutating func record(
            _ sample: GradientFrameStageTimingSample,
            expectedFrameDuration: TimeInterval
        ) {
            guard sample.isValid,
                  expectedFrameDuration.isFinite,
                  expectedFrameDuration > 0
            else {
                return
            }

            sampledFrameCount += 1
            if sample.wasOnMainThread {
                mainThreadFrameCount += 1
            }
            if sample.totalDuration > expectedFrameDuration {
                frameBudgetOverrunCount += 1
            }

            renderPassAcquisitionDurationTotal += sample.renderPassAcquisitionDuration
            maximumRenderPassAcquisitionDuration = max(
                maximumRenderPassAcquisitionDuration,
                sample.renderPassAcquisitionDuration
            )
            drawableAcquisitionDurationTotal += sample.drawableAcquisitionDuration
            maximumDrawableAcquisitionDuration = max(
                maximumDrawableAcquisitionDuration,
                sample.drawableAcquisitionDuration
            )
            commandBufferCreationDurationTotal += sample.commandBufferCreationDuration
            maximumCommandBufferCreationDuration = max(
                maximumCommandBufferCreationDuration,
                sample.commandBufferCreationDuration
            )
            renderCommandEncoderCreationDurationTotal += sample.renderCommandEncoderCreationDuration
            maximumRenderCommandEncoderCreationDuration = max(
                maximumRenderCommandEncoderCreationDuration,
                sample.renderCommandEncoderCreationDuration
            )
            commandEncodingDurationTotal += sample.commandEncodingDuration
            maximumCommandEncodingDuration = max(
                maximumCommandEncodingDuration,
                sample.commandEncodingDuration
            )
            commandSubmissionDurationTotal += sample.commandSubmissionDuration
            maximumCommandSubmissionDuration = max(
                maximumCommandSubmissionDuration,
                sample.commandSubmissionDuration
            )
            totalDuration += sample.totalDuration
            maximumTotalDuration = max(maximumTotalDuration, sample.totalDuration)
        }

        mutating func takeReport() -> GradientFrameStageTimingReport? {
            guard sampledFrameCount > 0 else { return nil }

            let sampleCount = Double(sampledFrameCount)
            let report = GradientFrameStageTimingReport(
                sampledFrameCount: sampledFrameCount,
                mainThreadFrameCount: mainThreadFrameCount,
                frameBudgetOverrunCount: frameBudgetOverrunCount,
                averageRenderPassAcquisitionMilliseconds: renderPassAcquisitionDurationTotal / sampleCount * 1_000,
                maximumRenderPassAcquisitionMilliseconds: maximumRenderPassAcquisitionDuration * 1_000,
                averageDrawableAcquisitionMilliseconds: drawableAcquisitionDurationTotal / sampleCount * 1_000,
                maximumDrawableAcquisitionMilliseconds: maximumDrawableAcquisitionDuration * 1_000,
                averageCommandBufferCreationMilliseconds: commandBufferCreationDurationTotal / sampleCount * 1_000,
                maximumCommandBufferCreationMilliseconds: maximumCommandBufferCreationDuration * 1_000,
                averageRenderCommandEncoderCreationMilliseconds: renderCommandEncoderCreationDurationTotal / sampleCount * 1_000,
                maximumRenderCommandEncoderCreationMilliseconds: maximumRenderCommandEncoderCreationDuration * 1_000,
                averageCommandEncodingMilliseconds: commandEncodingDurationTotal / sampleCount * 1_000,
                maximumCommandEncodingMilliseconds: maximumCommandEncodingDuration * 1_000,
                averageCommandSubmissionMilliseconds: commandSubmissionDurationTotal / sampleCount * 1_000,
                maximumCommandSubmissionMilliseconds: maximumCommandSubmissionDuration * 1_000,
                averageTotalDurationMilliseconds: totalDuration / sampleCount * 1_000,
                maximumTotalDurationMilliseconds: maximumTotalDuration * 1_000
            )
            self = GradientFrameStageTimingAccumulator()
            return report
        }
    }
}
