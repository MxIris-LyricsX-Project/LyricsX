import AppKit
import LyricsXFoundation

/// The outcome of `StatusItemSnapshotParity.run()`, written by the probe host.
package struct StatusItemParityReport: Codable, Sendable {
    package var comparedSnapshotCount: Int
    package var snapshotMismatches: [String]
    package var fieldSizeMismatches: [String]
    package var frozenScrollPosition: Double
    package var expectedFrozenScrollPosition: Double
}

/// `MenuBarMarqueeLabel` against the MarqueeLabel text field it replaces,
/// snapshot for snapshot.
///
/// On macOS 26 and later the menu bar never shows the status item's own
/// window: it shows the snapshots the app hands it, taken with
/// `cacheDisplay(in:to:)`. Two drawings that produce the same snapshot bytes
/// therefore look the same in the menu bar. Both are snapshotted that way
/// under the menu bar's own vibrant appearances and the plain ones, for short
/// lines (centred) and a long line at rest and mid-scroll — the view placed
/// by its own scroll timing, frozen by pausing at the moment it reaches each
/// sampled position, and the text field put where the view says it is.
///
/// It runs inside the probe host rather than the test process: on macOS
/// 27.2 a test process that opens windows from a terminal leaves a Dock icon
/// behind for every run.
@available(macOS 26, *)
@MainActor
package enum StatusItemSnapshotParity {
    private static let appearanceNames: [NSAppearance.Name] = [.vibrantDark, .vibrantLight, .darkAqua, .aqua]
    private static let shortLines = ["LyricsX", "终于做了这个决定", "Let It Go, let it go", "君の名は。", "Señorita 🎵"]
    private static let longLine = "终于做了这个决定，别人怎么说我不理，要随着我的心，大步踏出去"
    private static let longLineScrollPositions: [CGFloat] = [0, -37, -120]
    private static let lineDisplayTime: TimeInterval = 10

    package static func run() throws -> StatusItemParityReport {
        let snapshotter = ReplicantSnapshotter()
        var snapshotMismatches: [String] = []
        var comparedSnapshotCount = 0
        for appearanceName in appearanceNames {
            guard let appearance = NSAppearance(named: appearanceName) else {
                throw StatusItemSnapshotParityError.missingAppearance(appearanceName.rawValue)
            }
            var cases: [(text: String, scrollPosition: CGFloat)] = shortLines.map { ($0, 0) }
            cases += longLineScrollPositions.map { (longLine, $0) }
            for (text, targetPosition) in cases {
                let marqueeLabel = marqueeLabel(showing: text, frozenAt: targetPosition)
                let reference = MarqueeTextFieldBox(text: text, drawTally: nil)
                reference.scrollPosition = marqueeLabel.scrollPosition
                let difference = try PixelDifference(
                    reference: snapshotter.snapshot(of: reference, appearance: appearance),
                    candidate: snapshotter.snapshot(of: marqueeLabel, appearance: appearance)
                )
                comparedSnapshotCount += 1
                if difference.differingPixelCount > 0 {
                    snapshotMismatches.append("\(appearanceName.rawValue) “\(text)” @\(marqueeLabel.scrollPosition): \(difference)")
                }
            }
        }

        var fieldSizeMismatches: [String] = []
        for text in shortLines + [longLine] {
            let referenceField = makeMarqueeStyledTextField(drawTally: nil)
            referenceField.stringValue = text
            referenceField.sizeToFit()
            let marqueeLabel = MenuBarMarqueeLabel(frame: .zero)
            marqueeLabel.setStringValue(text, lineDisplayTime: lineDisplayTime)
            if marqueeLabel.fieldSize != referenceField.frame.size {
                fieldSizeMismatches.append("“\(text)”: \(marqueeLabel.fieldSize) vs \(referenceField.frame.size)")
            }
        }

        let expectedFrozenScrollPosition: CGFloat = -120
        return StatusItemParityReport(
            comparedSnapshotCount: comparedSnapshotCount,
            snapshotMismatches: snapshotMismatches,
            fieldSizeMismatches: fieldSizeMismatches,
            frozenScrollPosition: Double(marqueeLabel(showing: longLine, frozenAt: expectedFrozenScrollPosition).scrollPosition),
            expectedFrozenScrollPosition: Double(expectedFrozenScrollPosition)
        )
    }

    /// A view showing `text`, its clock moved to the moment a long line's
    /// scroll reaches `targetPosition`, then paused there.
    private static func marqueeLabel(showing text: String, frozenAt targetPosition: CGFloat) -> MenuBarMarqueeLabel {
        var currentTime: CFTimeInterval = 0
        let marqueeLabel = MenuBarMarqueeLabel(frame: NSRect(x: 0, y: 0, width: MenuBarLyricsGeometry.lyricsWidth, height: MenuBarLyricsGeometry.lyricsHeight))
        marqueeLabel.clock = { currentTime }
        marqueeLabel.setStringValue(text, lineDisplayTime: lineDisplayTime)
        let fieldWidth = marqueeFieldWidth(of: text)
        let travel = fieldWidth - MenuBarLyricsGeometry.lyricsWidth
        if travel > 0 {
            let movingDuration = lineDisplayTime * Double(travel / fieldWidth)
            let restDuration = (lineDisplayTime - movingDuration) / 2
            currentTime = restDuration + movingDuration * Double(-targetPosition / travel)
        }
        marqueeLabel.setPlaybackPaused(true)
        return marqueeLabel
    }
}

package enum StatusItemSnapshotParityError: Error {
    case missingAppearance(String)
    case snapshotUnavailable
    case incomparableSnapshots
}

/// Snapshots a view the way the status item's replicant does —
/// `cacheDisplay(in:to:)` at the window's backing scale — inside an
/// offscreen window on the main screen.
@MainActor
struct ReplicantSnapshotter {
    private let window: NSWindow

    init() {
        self.window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: MenuBarLyricsGeometry.lyricsWidth, height: MenuBarLyricsGeometry.lyricsHeight),
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: NSScreen.main
        )
        window.isReleasedWhenClosed = false
    }

    func snapshot(of view: NSView, appearance: NSAppearance) throws -> NSBitmapImageRep {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: MenuBarLyricsGeometry.lyricsWidth, height: MenuBarLyricsGeometry.lyricsHeight))
        container.appearance = appearance
        view.frame = container.bounds
        container.addSubview(view)
        window.contentView = container
        container.layoutSubtreeIfNeeded()
        guard let bitmap = container.bitmapImageRepForCachingDisplay(in: container.bounds) else {
            throw StatusItemSnapshotParityError.snapshotUnavailable
        }
        container.cacheDisplay(in: container.bounds, to: bitmap)
        return bitmap
    }
}

/// How far apart two snapshots of the same size are, byte by byte.
struct PixelDifference: CustomStringConvertible {
    let differingPixelCount: Int
    let largestChannelDifference: Int
    let referenceInk: Int
    let candidateInk: Int

    init(reference: NSBitmapImageRep, candidate: NSBitmapImageRep) throws {
        guard reference.pixelsWide == candidate.pixelsWide, reference.pixelsHigh == candidate.pixelsHigh,
              reference.bitsPerPixel == 32, candidate.bitsPerPixel == 32,
              let referenceBytes = reference.bitmapData, let candidateBytes = candidate.bitmapData else {
            throw StatusItemSnapshotParityError.incomparableSnapshots
        }
        var differingPixelCount = 0
        var largestChannelDifference = 0
        var referenceInk = 0
        var candidateInk = 0
        for row in 0 ..< reference.pixelsHigh {
            for column in 0 ..< reference.pixelsWide {
                var pixelDiffers = false
                for channel in 0 ..< 4 {
                    let referenceValue = Int(referenceBytes[row * reference.bytesPerRow + column * 4 + channel])
                    let candidateValue = Int(candidateBytes[row * candidate.bytesPerRow + column * 4 + channel])
                    if channel == 3 {
                        referenceInk += referenceValue
                        candidateInk += candidateValue
                    }
                    let channelDifference = abs(referenceValue - candidateValue)
                    if channelDifference > 0 {
                        pixelDiffers = true
                        largestChannelDifference = max(largestChannelDifference, channelDifference)
                    }
                }
                if pixelDiffers {
                    differingPixelCount += 1
                }
            }
        }
        self.differingPixelCount = differingPixelCount
        self.largestChannelDifference = largestChannelDifference
        self.referenceInk = referenceInk
        self.candidateInk = candidateInk
    }

    var description: String {
        "\(differingPixelCount) px differ, largest channel difference \(largestChannelDifference), ink \(candidateInk) vs \(referenceInk)"
    }
}
