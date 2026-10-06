import AppKit
import LyricsXFoundation
import QuartzCore
import StatusItemProbeSupport

/// Runs one status-item probe as a real, bundled app.
///
/// The probes cannot mount their status item inside the test process: on
/// macOS 27 an item belonging to a process without a bundle identifier stays
/// on the old in-process `NSStatusBarWindow`, while the item of a real app is
/// shown by the system menu bar from snapshots ("replicants") the app keeps
/// sending it — which is exactly where the CPU goes. `MenuBarLyricsTests`
/// wraps this executable in a throwaway `.app`, launches it with a
/// `StatusItemProbeRequest`, and reads back a `StatusItemProbeReport`.
@main
enum StatusItemProbeHost {
    static func main() {
        MainActor.assumeIsolated {
            let request: StatusItemProbeRequest
            do {
                request = try StatusItemProbeRequest(arguments: Array(CommandLine.arguments.dropFirst()))
            } catch {
                FileHandle.standardError.write(Data("StatusItemProbeHost: \(error)\n".utf8))
                exit(2)
            }
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            let delegate = StatusItemProbeHostDelegate(session: StatusItemProbeSession(request: request))
            StatusItemProbeHostDelegate.retainedInstance = delegate
            application.delegate = delegate
            application.run()
        }
    }
}

@MainActor
private final class StatusItemProbeHostDelegate: NSObject, NSApplicationDelegate {
    static var retainedInstance: StatusItemProbeHostDelegate?

    private let session: StatusItemProbeSession

    init(session: StatusItemProbeSession) {
        self.session = session
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        session.start()
    }
}

/// Runs `StatusItemSnapshotParity` and writes its report.
@MainActor
private enum SnapshotParityRun {
    static func runAndExit(reportPath: String) -> Never {
        do {
            guard #available(macOS 26, *) else {
                preconditionFailure("MenuBarMarqueeLabel exists only on macOS 26 and later")
            }
            let report = try StatusItemSnapshotParity.run()
            try JSONEncoder().encode(report).write(to: URL(fileURLWithPath: reportPath))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("StatusItemProbeHost: \(error)\n".utf8))
            exit(5)
        }
    }
}

/// Mounts the requested content, lets it settle, measures, writes the
/// report and exits.
@MainActor
private final class StatusItemProbeSession {
    private let request: StatusItemProbeRequest
    private let drawTally = DrawTally()
    private var liveStatusItem: LiveStatusItem?
    private var lyricsView: NSView?
    private var settleDrawCount = 0
    private var wallStart: CFTimeInterval = 0
    private var processCPUStart: Double = 0

    init(request: StatusItemProbeRequest) {
        self.request = request
    }

    func start() {
        if request.mode == .snapshotParity {
            SnapshotParityRun.runAndExit(reportPath: request.reportPath)
        }
        do {
            let views = request.content.makeViews(text: request.text, lineDisplayTime: ownTimingLineDisplayTime, drawTally: drawTally)
            lyricsView = views.lyrics
            if request.maximumScrollFramesPerSecond > 0, #available(macOS 26, *) {
                (views.lyrics as? MenuBarMarqueeLabel)?.maximumScrollFramesPerSecond = request.maximumScrollFramesPerSecond
            }
            liveStatusItem = try LiveStatusItem(content: views.content)
        } catch {
            FileHandle.standardError.write(Data("StatusItemProbeHost: \(error)\n".utf8))
            exit(3)
        }
        Timer.scheduledTimer(withTimeInterval: request.settleSeconds, repeats: false) { _ in
            MainActor.assumeIsolated { self.beginMeasuring() }
        }
    }

    private func beginMeasuring() {
        settleDrawCount = drawTally.totalDrawCount
        drawTally.reset()
        wallStart = CACurrentMediaTime()
        processCPUStart = ProcessCPUClock.seconds()
        startScrolling()
        Timer.scheduledTimer(withTimeInterval: request.measuredSeconds, repeats: false) { _ in
            MainActor.assumeIsolated { self.finish() }
        }
    }

    /// For a view that scrolls itself: a line whose resting part lasts
    /// exactly the settle time, so its moving part starts as measuring does.
    private var ownTimingLineDisplayTime: TimeInterval {
        let fieldWidth = marqueeFieldWidth(of: request.text)
        let overflowShare = fieldWidth > 0 ? max(0, fieldWidth - MenuBarLyricsGeometry.lyricsWidth) / fieldWidth : 0
        guard request.scrollDriving == .ownTiming, overflowShare > 0 else { return 5 }
        return 2 * request.settleSeconds / (1 - overflowShare)
    }

    /// Moves a line wider than the box from rest to its far end across the
    /// measured window, the way MarqueeLabel's animation does.
    private func startScrolling() {
        guard request.scrollDriving == .marqueeAnimation, let box = lyricsView as? MarqueeTextFieldBox else { return }
        let travel = max(0, box.textField.frame.width - box.bounds.width)
        guard travel > 0 else { return }
        var endFrame = box.textField.frame
        endFrame.origin.x = -travel
        NSAnimationContext.runAnimationGroup { context in
            context.duration = request.measuredSeconds
            context.timingFunction = CAMediaTimingFunction(name: .linear)
            box.textField.animator().frame = endFrame
        }
    }

    private func finish() {
        let processCPUSeconds = ProcessCPUClock.seconds() - processCPUStart
        let wallSeconds = CACurrentMediaTime() - wallStart
        let button = liveStatusItem?.statusItem.button
        let report = StatusItemProbeReport(
            content: request.content.description,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            wallSeconds: wallSeconds,
            processCPUSeconds: processCPUSeconds,
            drawCountsBySource: drawTally.drawCountsBySource,
            positionUpdates: drawTally.positionUpdates,
            settleDrawCount: settleDrawCount,
            statusBarWindowNumber: button?.window?.windowNumber ?? 0,
            statusBarWindowIsOnScreen: Self.isOnScreen(button?.window),
            buttonAppearanceName: button?.effectiveAppearance.name.rawValue ?? "none"
        )
        liveStatusItem?.remove()
        do {
            try JSONEncoder().encode(report).write(to: URL(fileURLWithPath: request.reportPath))
        } catch {
            FileHandle.standardError.write(Data("StatusItemProbeHost: \(error)\n".utf8))
            exit(4)
        }
        exit(0)
    }

    private static func isOnScreen(_ window: NSWindow?) -> Bool {
        guard let window, let windowIdentifier = CGWindowID(exactly: window.windowNumber),
              let windowInformation = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowIdentifier) as? [[String: Any]] else {
            return false
        }
        return windowInformation.first?[kCGWindowIsOnscreen as String] as? Bool ?? false
    }
}
