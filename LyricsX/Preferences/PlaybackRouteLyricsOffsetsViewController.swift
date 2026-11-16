import AppKit
import Combine
import LyricsXFoundation
import SnapKit

/// The lyrics offsets set per player and output device, presented as a sheet
/// from the General pane's global offset.
///
/// The top row edits the offset of what plays now; the table lists every
/// offset set so far, including ones for devices that are not connected.
final class PlaybackRouteLyricsOffsetsViewController: NSViewController {
    private static let contentWidth: CGFloat = 520
    private static let contentInset: CGFloat = 20

    private let routeController = PlaybackRouteLyricsOffsetController.shared

    private let titleLabel = NSTextField(labelWithString: NSLocalizedString(
        "Lyrics Offset per Player & Output",
        comment: "Title of the sheet that lists the lyrics offsets set per player and output device."
    ))

    private lazy var explanationLabel = NSTextField(wrappingLabelWithString: NSLocalizedString(
        "Added to the global offset while that player plays through that output. A positive offset shows lyrics earlier; every AirPlay output counts as one.",
        comment: "Explanation at the top of the sheet of lyrics offsets per player and output device."
    ))

    private let currentPlayerIconView = NSImageView()

    private let currentRouteLabel = NSTextField(labelWithString: "")

    private let currentOffsetLabel = NSTextField(labelWithString: NSLocalizedString(
        "Offset (ms):",
        comment: "Label before the lyrics offset of the player and output device playing now."
    ))

    private let currentOffsetField = NSTextField()

    private let scrollView = NSScrollView()

    private let tableView = NSTableView()

    private lazy var removeButton = NSButton(
        image: NSImage(named: NSImage.removeTemplateName)!,
        target: self,
        action: #selector(removeSelectedOffsets(_:))
    )

    private lazy var doneButton = NSButton(
        title: NSLocalizedString("Done", comment: "Closes the sheet of lyrics offsets per player and output device."),
        target: self,
        action: #selector(done(_:))
    )

    private var entries: [PlaybackRouteLyricsOffsets.Entry] = []

    /// The route the top row was last filled in for, so a change elsewhere
    /// does not overwrite what is being typed there.
    private var displayedRoute: PlaybackRoute?

    private var cancelBag = Set<AnyCancellable>()

    private enum ColumnIdentifier {
        static let player = NSUserInterfaceItemIdentifier("Player")
        static let output = NSUserInterfaceItemIdentifier("Output")
        static let offset = NSUserInterfaceItemIdentifier("Offset")
    }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let currentRouteRow = NSStackView(views: [currentPlayerIconView, currentRouteLabel, currentOffsetLabel, currentOffsetField])
        currentRouteRow.orientation = .horizontal
        currentRouteRow.alignment = .centerY
        currentRouteRow.spacing = 8
        currentRouteRow.setCustomSpacing(16, after: currentRouteLabel)

        [titleLabel, explanationLabel, currentRouteRow, scrollView, removeButton, doneButton].forEach(view.addSubview)

        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        explanationLabel.textColor = .secondaryLabelColor
        explanationLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        explanationLabel.preferredMaxLayoutWidth = Self.contentWidth

        currentRouteLabel.lineBreakMode = .byTruncatingMiddle
        currentRouteLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        currentRouteLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        currentOffsetField.formatter = Self.makeOffsetFormatter()
        currentOffsetField.alignment = .center
        currentOffsetField.target = self
        currentOffsetField.action = #selector(currentOffsetEdited(_:))

        removeButton.isBordered = false
        removeButton.isEnabled = false
        removeButton.setAccessibilityLabel(NSLocalizedString(
            "Remove Selected Offsets",
            comment: "Accessibility label of the button that removes the selected lyrics offsets per player and output device."
        ))

        doneButton.keyEquivalent = "\r"

        configureTableView()

        titleLabel.snp.makeConstraints { make in
            make.top.equalToSuperview().inset(Self.contentInset)
            make.leading.trailing.equalToSuperview().inset(Self.contentInset)
        }
        explanationLabel.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom).offset(6)
            make.leading.trailing.equalToSuperview().inset(Self.contentInset)
        }
        currentPlayerIconView.snp.makeConstraints { make in
            make.size.equalTo(20)
        }
        currentOffsetField.snp.makeConstraints { make in
            make.width.equalTo(80)
        }
        currentRouteRow.snp.makeConstraints { make in
            make.top.equalTo(explanationLabel.snp.bottom).offset(16)
            make.leading.trailing.equalToSuperview().inset(Self.contentInset)
        }
        scrollView.snp.makeConstraints { make in
            make.top.equalTo(currentRouteRow.snp.bottom).offset(14)
            make.leading.trailing.equalToSuperview().inset(Self.contentInset)
            make.width.equalTo(Self.contentWidth)
            make.height.equalTo(180)
        }
        removeButton.snp.makeConstraints { make in
            make.top.equalTo(scrollView.snp.bottom).offset(6)
            make.leading.equalTo(scrollView)
            make.size.equalTo(22)
        }
        doneButton.snp.makeConstraints { make in
            make.top.equalTo(removeButton.snp.bottom).offset(10)
            make.trailing.bottom.equalToSuperview().inset(Self.contentInset)
            make.width.greaterThanOrEqualTo(80)
        }

        preferredContentSize = view.fittingSize

        // `@Published` sends before the property changes; the hop to the
        // main queue is always asynchronous, so the controller reads its new
        // state by the time `reloadContent` runs.
        Publishers.CombineLatest3(
            routeController.$currentPlayerBundleIdentifier,
            routeController.$currentOutputDevice,
            routeController.$offsets
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _, _, _ in
            self?.reloadContent()
        }
        .store(in: &cancelBag)
    }

    private func configureTableView() {
        let columns: [(NSUserInterfaceItemIdentifier, String, CGFloat)] = [
            (ColumnIdentifier.player, NSLocalizedString("Player", comment: "Column header in the sheet of lyrics offsets per player and output device."), 220),
            (ColumnIdentifier.output, NSLocalizedString("Output", comment: "Column header in the sheet of lyrics offsets per player and output device: the output device."), 180),
            (ColumnIdentifier.offset, NSLocalizedString("Offset (ms)", comment: "Column header in the sheet of lyrics offsets per player and output device."), 90),
        ]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            column.width = width
            column.minWidth = 60
            tableView.addTableColumn(column)
        }
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.rowHeight = 24
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
    }

    private func reloadContent() {
        let currentRoute = routeController.currentRoute
        if let currentPlayerBundleIdentifier = routeController.currentPlayerBundleIdentifier {
            let application = NowPlayingApplication(bundleIdentifier: currentPlayerBundleIdentifier)
            currentPlayerIconView.image = application.icon
            if let currentOutputDevice = routeController.currentOutputDevice {
                currentRouteLabel.stringValue = "\(application.name) → \(currentOutputDevice.name)"
            } else {
                currentRouteLabel.stringValue = NSLocalizedString(
                    "No output device found.",
                    comment: "Shown in the sheet of lyrics offsets per player and output device when Core Audio reports no output device."
                )
            }
        } else {
            currentPlayerIconView.image = nil
            currentRouteLabel.stringValue = NSLocalizedString(
                "No player is playing.",
                comment: "Shown in the sheet of lyrics offsets per player and output device when no player can be told."
            )
        }
        currentPlayerIconView.isHidden = currentPlayerIconView.image == nil
        currentOffsetField.isEnabled = currentRoute != nil
        if currentRoute != displayedRoute || currentOffsetField.currentEditor() == nil {
            currentOffsetField.integerValue = routeController.offsets.offset(for: currentRoute)
            displayedRoute = currentRoute
        }

        entries = routeController.offsets.entries
        tableView.reloadData()
        removeButton.isEnabled = !tableView.selectedRowIndexes.isEmpty
    }

    @objc private func currentOffsetEdited(_ sender: NSTextField) {
        guard let route = routeController.currentRoute, let outputDevice = routeController.currentOutputDevice else { return }
        let application = NowPlayingApplication(bundleIdentifier: route.playerBundleIdentifier)
        routeController.setOffset(sender.integerValue, for: route, playerName: application.name, outputDeviceName: outputDevice.name)
    }

    @objc private func tableOffsetEdited(_ sender: NSTextField) {
        let row = tableView.row(for: sender)
        guard entries.indices.contains(row) else { return }
        let entry = entries[row]
        routeController.setOffset(sender.integerValue, for: entry.route, playerName: entry.playerName, outputDeviceName: entry.outputDeviceName)
    }

    @objc private func removeSelectedOffsets(_ sender: NSButton) {
        let routes = tableView.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0].route : nil }
        routes.forEach(routeController.removeOffset(for:))
    }

    @objc private func done(_ sender: NSButton) {
        // Ends any edit in progress, which commits it through the field's action.
        view.window?.makeFirstResponder(nil)
        dismiss(nil)
    }

    private static func makeOffsetFormatter() -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.allowsFloats = false
        formatter.usesGroupingSeparator = false
        return formatter
    }

    /// The player's name as the system shows it, or the name stored with the
    /// offset when the app cannot be found.
    private static func playerName(of entry: PlaybackRouteLyricsOffsets.Entry) -> (name: String, icon: NSImage) {
        let application = NowPlayingApplication(bundleIdentifier: entry.route.playerBundleIdentifier)
        let isFound = application.name != entry.route.playerBundleIdentifier
        return (isFound ? application.name : entry.playerName, application.icon)
    }
}

extension PlaybackRouteLyricsOffsetsViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }
}

extension PlaybackRouteLyricsOffsetsViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier, entries.indices.contains(row) else { return nil }
        let entry = entries[row]
        let cellView = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? makeCellView(identifier: identifier)
        switch identifier {
        case ColumnIdentifier.player:
            let player = Self.playerName(of: entry)
            cellView.imageView?.image = player.icon
            cellView.textField?.stringValue = player.name
        case ColumnIdentifier.output:
            cellView.textField?.stringValue = entry.outputDeviceName
        default:
            cellView.textField?.integerValue = entry.offset
        }
        return cellView
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton.isEnabled = !tableView.selectedRowIndexes.isEmpty
    }

    private func makeCellView(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cellView = NSTableCellView()
        cellView.identifier = identifier

        let textField: NSTextField
        if identifier == ColumnIdentifier.offset {
            textField = NSTextField()
            textField.isBordered = false
            textField.drawsBackground = false
            textField.formatter = Self.makeOffsetFormatter()
            textField.alignment = .right
            textField.target = self
            textField.action = #selector(tableOffsetEdited(_:))
        } else {
            textField = NSTextField(labelWithString: "")
            textField.lineBreakMode = .byTruncatingTail
        }
        cellView.addSubview(textField)
        cellView.textField = textField

        if identifier == ColumnIdentifier.player {
            let imageView = NSImageView()
            cellView.addSubview(imageView)
            cellView.imageView = imageView
            imageView.snp.makeConstraints { make in
                make.leading.equalToSuperview().offset(2)
                make.centerY.equalToSuperview()
                make.size.equalTo(16)
            }
            textField.snp.makeConstraints { make in
                make.leading.equalTo(imageView.snp.trailing).offset(6)
                make.trailing.equalToSuperview().offset(-2)
                make.centerY.equalToSuperview()
            }
        } else {
            textField.snp.makeConstraints { make in
                make.leading.equalToSuperview().offset(2)
                make.trailing.equalToSuperview().offset(-4)
                make.centerY.equalToSuperview()
            }
        }
        return cellView
    }
}
