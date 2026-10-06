import AppKit
import Darwin
import QuartzCore

/// Process CPU time, readable at any point.
package enum ProcessCPUClock {
    package static func seconds() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)) / 1_000_000_000
    }
}

/// Counts how often views drew, by which kind of view drew.
@MainActor
package final class DrawTally {
    package private(set) var drawCountsBySource: [String: Int] = [:]

    package init() {}

    package var totalDrawCount: Int {
        drawCountsBySource.values.reduce(0, +)
    }

    /// Where the lyric line's text has been, one entry per move.
    package private(set) var positionUpdates: [CGFloat] = []

    package func recordDraw(source: String) {
        drawCountsBySource[source, default: 0] += 1
    }

    package func recordPosition(_ position: CGFloat) {
        positionUpdates.append(position)
    }

    package func reset() {
        drawCountsBySource = [:]
        positionUpdates = []
    }
}

/// A real status item in the system menu bar, hosting `content` the way
/// `MenuBarLyricsController.layoutLyricStatusItemContents()` hosts its stack
/// view: a variable-length item whose button is sized to the content's
/// fitting width, with the content pinned to the button's edges.
@MainActor
package final class LiveStatusItem {
    package let statusItem: NSStatusItem
    package let content: NSView

    package init(content: NSView) throws {
        self.content = content
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else {
            NSStatusBar.system.removeStatusItem(statusItem)
            throw LiveStatusItemError.missingButton
        }
        button.title = ""
        button.image = nil
        content.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            content.topAnchor.constraint(equalTo: button.topAnchor),
            content.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])
        content.layoutSubtreeIfNeeded()
        button.frame = CGRect(
            x: 0,
            y: 0,
            width: content.fittingSize.width,
            height: NSStatusBar.system.thickness
        )
    }

    package func remove() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}

package enum LiveStatusItemError: Error {
    case missingButton
}
