import CoreGraphics
import Foundation

/// How the lyric moves while the probe measures.
package enum ScrollDriving: Hashable, Sendable, CustomStringConvertible {
    /// It does not: the line sits still.
    case none
    /// MLMarqueeLabel's own motion: one linear `animator().frame` animation
    /// of the text field across the measured window.
    case marqueeAnimation
    /// The lyric view moves itself — `MenuBarMarqueeLabel` — given a line
    /// whose moving part starts as the measured window does.
    case ownTiming

    package var description: String {
        switch self {
        case .none:
            "none"
        case .marqueeAnimation:
            "marqueeAnimation"
        case .ownTiming:
            "ownTiming"
        }
    }

    package init?(description: String) {
        switch description {
        case "none":
            self = .none
        case "marqueeAnimation":
            self = .marqueeAnimation
        case "ownTiming":
            self = .ownTiming
        default:
            return nil
        }
    }
}

/// Which probe the host runs.
package enum StatusItemProbeMode: String, Sendable {
    /// Mount content in a real status item and measure it.
    case liveStatusItem
    /// Run `StatusItemSnapshotParity` offscreen and report.
    case snapshotParity
    /// Open a real menu with a `TitleAlignedMenuItemView` row and report
    /// where its label starts against the menu's titles.
    case menuTitleAlignment
}

/// One menu `MenuTitleAlignmentProbe` opens.
package struct MenuTitleAlignmentCase: Hashable, Sendable, Codable, CustomStringConvertible {
    /// Whether an item of the menu is checked, which gives it a state column.
    package var showsStateColumn: Bool
    /// `TitleAlignedMenuItemView.measuresMenuTitles`: off, the row is placed
    /// from the fallback table.
    package var measuresMenuTitles: Bool

    package init(showsStateColumn: Bool, measuresMenuTitles: Bool) {
        self.showsStateColumn = showsStateColumn
        self.measuresMenuTitles = measuresMenuTitles
    }

    package static let allCases: [MenuTitleAlignmentCase] = [
        MenuTitleAlignmentCase(showsStateColumn: true, measuresMenuTitles: true),
        MenuTitleAlignmentCase(showsStateColumn: false, measuresMenuTitles: true),
        MenuTitleAlignmentCase(showsStateColumn: true, measuresMenuTitles: false),
        MenuTitleAlignmentCase(showsStateColumn: false, measuresMenuTitles: false),
    ]

    package var description: String {
        "\(showsStateColumn ? "state column" : "no state column"), \(measuresMenuTitles ? "measured" : "fallback table")"
    }

    var argument: String {
        "stateColumn=\(showsStateColumn),measures=\(measuresMenuTitles)"
    }

    init?(argument: String) {
        switch argument {
        case "stateColumn=true,measures=true":
            self.init(showsStateColumn: true, measuresMenuTitles: true)
        case "stateColumn=false,measures=true":
            self.init(showsStateColumn: false, measuresMenuTitles: true)
        case "stateColumn=true,measures=false":
            self.init(showsStateColumn: true, measuresMenuTitles: false)
        case "stateColumn=false,measures=false":
            self.init(showsStateColumn: false, measuresMenuTitles: false)
        default:
            return nil
        }
    }
}

/// What the test asks `StatusItemProbeHost` to do, passed as command-line
/// arguments so the host can run as a real, separately launched app.
package struct StatusItemProbeRequest: Sendable {
    package var mode: StatusItemProbeMode
    package var content: StatusItemContent
    package var text: String
    package var scrollDriving: ScrollDriving
    /// A cap for `MenuBarMarqueeLabel.maximumScrollFramesPerSecond`; zero
    /// leaves the view's default.
    package var maximumScrollFramesPerSecond: Double
    package var settleSeconds: Double
    package var measuredSeconds: Double
    package var reportPath: String
    /// The menu a `.menuTitleAlignment` run opens.
    package var menuTitleAlignmentCase: MenuTitleAlignmentCase?

    package init(
        mode: StatusItemProbeMode = .liveStatusItem,
        content: StatusItemContent,
        text: String,
        scrollDriving: ScrollDriving = .none,
        maximumScrollFramesPerSecond: Double = 0,
        settleSeconds: Double,
        measuredSeconds: Double,
        reportPath: String,
        menuTitleAlignmentCase: MenuTitleAlignmentCase? = nil
    ) {
        self.mode = mode
        self.content = content
        self.text = text
        self.scrollDriving = scrollDriving
        self.maximumScrollFramesPerSecond = maximumScrollFramesPerSecond
        self.settleSeconds = settleSeconds
        self.measuredSeconds = measuredSeconds
        self.reportPath = reportPath
        self.menuTitleAlignmentCase = menuTitleAlignmentCase
    }

    /// A snapshot-parity run, which needs nothing but somewhere to report.
    package static func snapshotParity(reportPath: String) -> StatusItemProbeRequest {
        StatusItemProbeRequest(
            mode: .snapshotParity,
            content: StatusItemContent(lyrics: .menuBarMarqueeLabel, neighbors: .none),
            text: "",
            settleSeconds: 0,
            measuredSeconds: 0,
            reportPath: reportPath
        )
    }

    /// A menu-alignment run: opens one menu and reports on it.
    package static func menuTitleAlignment(_ menuCase: MenuTitleAlignmentCase, reportPath: String) -> StatusItemProbeRequest {
        StatusItemProbeRequest(
            mode: .menuTitleAlignment,
            content: StatusItemContent(lyrics: .menuBarMarqueeLabel, neighbors: .none),
            text: "",
            settleSeconds: 0,
            measuredSeconds: 0,
            reportPath: reportPath,
            menuTitleAlignmentCase: menuCase
        )
    }

    package var arguments: [String] {
        var arguments = [
            "--mode", mode.rawValue,
            "--content", content.description,
            "--text", text,
            "--scroll", scrollDriving.description,
            "--maximum-scroll-frames-per-second", String(maximumScrollFramesPerSecond),
            "--settle-seconds", String(settleSeconds),
            "--measured-seconds", String(measuredSeconds),
            "--report-path", reportPath,
        ]
        if let menuTitleAlignmentCase {
            arguments += ["--menu-title-alignment-case", menuTitleAlignmentCase.argument]
        }
        return arguments
    }

    package init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var argumentIndex = 0
        while argumentIndex + 1 < arguments.count {
            values[arguments[argumentIndex]] = arguments[argumentIndex + 1]
            argumentIndex += 2
        }
        guard let mode = values["--mode"].flatMap(StatusItemProbeMode.init(rawValue:)),
              let contentDescription = values["--content"],
              let content = StatusItemContent(description: contentDescription),
              let text = values["--text"],
              let scrollDriving = values["--scroll"].flatMap(ScrollDriving.init(description:)),
              let maximumScrollFramesPerSecond = values["--maximum-scroll-frames-per-second"].flatMap(Double.init),
              let settleSeconds = values["--settle-seconds"].flatMap(Double.init),
              let measuredSeconds = values["--measured-seconds"].flatMap(Double.init),
              let reportPath = values["--report-path"] else {
            throw StatusItemProbeProtocolError.malformedArguments(arguments)
        }
        let menuTitleAlignmentCase = values["--menu-title-alignment-case"].flatMap(MenuTitleAlignmentCase.init(argument:))
        if mode == .menuTitleAlignment, menuTitleAlignmentCase == nil {
            throw StatusItemProbeProtocolError.malformedArguments(arguments)
        }
        self.init(
            mode: mode,
            content: content,
            text: text,
            scrollDriving: scrollDriving,
            maximumScrollFramesPerSecond: maximumScrollFramesPerSecond,
            settleSeconds: settleSeconds,
            measuredSeconds: measuredSeconds,
            reportPath: reportPath,
            menuTitleAlignmentCase: menuTitleAlignmentCase
        )
    }
}

/// What the host measured, written as JSON to the request's report path.
package struct StatusItemProbeReport: Codable, Sendable {
    package var content: String
    package var bundleIdentifier: String?
    package var wallSeconds: Double
    package var processCPUSeconds: Double
    package var drawCountsBySource: [String: Int]
    package var positionUpdates: [CGFloat]
    package var settleDrawCount: Int
    package var statusBarWindowNumber: Int
    /// Whether the item's own `NSStatusBarWindow` is on screen, per the
    /// window server. For a real app on macOS 27 it is not: the system menu
    /// bar shows the item from snapshots instead.
    package var statusBarWindowIsOnScreen: Bool
    package var buttonAppearanceName: String

    package init(
        content: String,
        bundleIdentifier: String?,
        wallSeconds: Double,
        processCPUSeconds: Double,
        drawCountsBySource: [String: Int],
        positionUpdates: [CGFloat],
        settleDrawCount: Int,
        statusBarWindowNumber: Int,
        statusBarWindowIsOnScreen: Bool,
        buttonAppearanceName: String
    ) {
        self.content = content
        self.bundleIdentifier = bundleIdentifier
        self.wallSeconds = wallSeconds
        self.processCPUSeconds = processCPUSeconds
        self.drawCountsBySource = drawCountsBySource
        self.positionUpdates = positionUpdates
        self.settleDrawCount = settleDrawCount
        self.statusBarWindowNumber = statusBarWindowNumber
        self.statusBarWindowIsOnScreen = statusBarWindowIsOnScreen
        self.buttonAppearanceName = buttonAppearanceName
    }

    /// Share of one core — how Activity Monitor's %CPU column reads.
    package var shareOfOneCore: Double {
        processCPUSeconds / wallSeconds
    }

    package var drawsPerSecond: Double {
        Double(drawCountsBySource.values.reduce(0, +)) / wallSeconds
    }

    /// How many times a second the line actually moved.
    package var movesPerSecond: Double {
        Double(positionUpdates.count) / wallSeconds
    }

    /// The typical jump between two consecutive positions, in points.
    package var medianStep: CGFloat {
        let steps = zip(positionUpdates, positionUpdates.dropFirst()).map { abs($1 - $0) }.sorted()
        return steps.isEmpty ? 0 : steps[steps.count / 2]
    }
}

package enum StatusItemProbeProtocolError: Error {
    case malformedArguments([String])
}
