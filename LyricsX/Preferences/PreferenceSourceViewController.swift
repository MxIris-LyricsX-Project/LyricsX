import AppKit
import LyricsXFoundation

class PreferenceSourceViewController: PreferenceViewController {
    /// The three buttons are wired as one radio group through their shared
    /// action; each carries its `LyricsSourceOrderingMode` raw value as its tag.
    @IBOutlet var orderByQualityOnlyButton: NSButton!
    @IBOutlet var orderBySourceFirstButton: NSButton!
    @IBOutlet var orderByQualityFirstSourceTieBreakButton: NSButton!
    @IBOutlet var sourceTableView: NSTableView!

    private var availableSources: [String] = []
    private var sourcePriorityOrder: [String] = []
    private var sourceSwitches = LyricsSourceSwitches()

    /// Carries the dragged row. A type of its own, so that text dragged in
    /// from another app is not taken for a row.
    private static let sourceRowPasteboardType = NSPasteboard.PasteboardType("com.JH.LyricsX.lyrics-source-row")

    private static let priorityColumnIdentifier = NSUserInterfaceItemIdentifier("priority")
    private static let sourceColumnIdentifier = NSUserInterfaceItemIdentifier("source")
    /// The source column's cells are made in code, so they are reused under an
    /// identifier of their own rather than the column's.
    private static let sourceSwitchCellIdentifier = NSUserInterfaceItemIdentifier("sourceSwitch")

    private var orderingModeButtons: [NSButton] {
        [
            orderByQualityOnlyButton,
            orderBySourceFirstButton,
            orderByQualityFirstSourceTieBreakButton,
        ]
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        availableSources = LyricsProviders.ServiceID.allCases.map(\.displayName)

        sourcePriorityOrder = defaults[.lyricsSourcePriorityOrder] ?? availableSources
        for source in availableSources {
            if !sourcePriorityOrder.contains(source) {
                sourcePriorityOrder.append(source)
            }
        }
        sourcePriorityOrder = sourcePriorityOrder.filter { availableSources.contains($0) }
        sourceSwitches = LyricsSourceSwitches(disabledSourceIdentifiers: defaults[.disabledLyricsSources])

        sourceTableView.delegate = self
        sourceTableView.dataSource = self
        sourceTableView.registerForDraggedTypes([Self.sourceRowPasteboardType])

        updateUI()
    }

    @IBAction func chooseSourceOrderingMode(_ sender: NSButton) {
        let mode = LyricsSourceOrderingMode(storedRawValue: sender.tag)
        defaults[.lyricsSourceOrderingMode] = mode.rawValue
        // Keep the superseded checkbox key in step so downgrading to a build
        // that still reads it lands on the nearest equivalent. The new
        // tie-break mode has no legacy spelling; mapping it to "off" is the
        // closer of the two, since quality decides there as well.
        defaults[.lyricsSourcePriorityEnabled] = mode == .sourceFirst
        updateUI()
    }

    private func updateUI() {
        let mode = lyricsSourceOrderingMode
        for button in orderingModeButtons {
            button.state = button.tag == mode.rawValue ? .on : .off
        }
        // The table stays usable in every mode, because its checkboxes switch
        // sources on and off whatever the ordering. Only the order is out of
        // play in a mode that ignores it: the numbers are dimmed and rows
        // cannot be dragged.
        sourceTableView.reloadData()
    }

    private func savePriorityOrder() {
        defaults[.lyricsSourcePriorityOrder] = sourcePriorityOrder
    }

    @objc private func toggleSource(_ sender: NSButton) {
        let row = sourceTableView.row(for: sender)
        guard sourcePriorityOrder.indices.contains(row),
              let service = Self.service(displayedAs: sourcePriorityOrder[row])
        else {
            return
        }
        sourceSwitches.setEnabled(sender.state == .on, for: service)
        defaults[.disabledLyricsSources] = sourceSwitches.disabledSourceIdentifiers
        // Takes effect from the next search; lyrics on screen stay.
        Task { @MainActor in await AppController.shared.updateLyricsManager() }
    }

    /// The rows are display names, the form `LyricsSourcePriorityOrder` has
    /// always stored.
    private static func service(displayedAs displayName: String) -> LyricsProviders.ServiceID? {
        LyricsProviders.ServiceID.allCases.first { $0.displayName == displayName }
    }
}

// MARK: - NSTableViewDataSource

extension PreferenceSourceViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return sourcePriorityOrder.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard row < sourcePriorityOrder.count else { return nil }

        let source = sourcePriorityOrder[row]

        if tableColumn?.identifier == Self.priorityColumnIdentifier {
            return "\(row + 1)"
        } else if tableColumn?.identifier == Self.sourceColumnIdentifier {
            return source
        }

        return nil
    }

    func tableView(_ tableView: NSTableView, writeRowsWith rowIndexes: IndexSet, to pboard: NSPasteboard) -> Bool {
        // Reordering means nothing in a mode that ignores the order.
        guard lyricsSourceOrderingMode.usesSourcePriorityOrder, let row = rowIndexes.first else { return false }

        pboard.declareTypes([Self.sourceRowPasteboardType], owner: self)
        pboard.setString("\(row)", forType: Self.sourceRowPasteboardType)
        return true
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard dropOperation == .above, info.draggingSource as? NSTableView === tableView else {
            return []
        }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard info.draggingSource as? NSTableView === tableView,
              let data = info.draggingPasteboard.string(forType: Self.sourceRowPasteboardType),
              let sourceRow = Int(data),
              let reorderedSources = LyricsSourceOrderingPolicy.reorderedSources(
                  sourcePriorityOrder,
                  movingRowAt: sourceRow,
                  toDropRow: row
              )
        else {
            return false
        }
        sourcePriorityOrder = reorderedSources

        savePriorityOrder()
        tableView.reloadData()

        return true
    }
}

// MARK: - NSTableViewDelegate

extension PreferenceSourceViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < sourcePriorityOrder.count,
              let identifier = tableColumn?.identifier else { return nil }

        switch identifier {
        case Self.priorityColumnIdentifier:
            let cellView = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            cellView?.textField?.stringValue = "\(row + 1)"
            cellView?.textField?.textColor = lyricsSourceOrderingMode.usesSourcePriorityOrder
                ? .controlTextColor
                : .disabledControlTextColor
            return cellView

        case Self.sourceColumnIdentifier:
            let cellView = tableView.makeView(withIdentifier: Self.sourceSwitchCellIdentifier, owner: self) as? LyricsSourceSwitchCellView
                ?? makeSourceSwitchCellView()
            let sourceName = sourcePriorityOrder[row]
            let service = Self.service(displayedAs: sourceName)
            cellView.switchButton.title = sourceName
            let isEnabled = service.map { sourceSwitches.isEnabled($0) } ?? true
            cellView.switchButton.state = isEnabled ? .on : .off
            cellView.switchButton.isEnabled = service != nil
            return cellView

        default:
            return nil
        }
    }

    private func makeSourceSwitchCellView() -> LyricsSourceSwitchCellView {
        let cellView = LyricsSourceSwitchCellView(target: self, action: #selector(toggleSource(_:)))
        cellView.identifier = Self.sourceSwitchCellIdentifier
        return cellView
    }
}

// MARK: - LyricsSourceSwitchCellView

/// A source's row in the list: a checkbox titled with the source's name that
/// switches the source on and off.
private final class LyricsSourceSwitchCellView: NSTableCellView {
    let switchButton: NSButton

    init(target: AnyObject, action: Selector) {
        switchButton = NSButton(checkboxWithTitle: "", target: target, action: action)
        super.init(frame: .zero)

        switchButton.lineBreakMode = .byTruncatingTail
        switchButton.toolTip = NSLocalizedString(
            "Search for lyrics from this source",
            comment: "Tooltip of the checkbox before each lyrics source on the Source settings pane."
        )
        switchButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(switchButton)
        NSLayoutConstraint.activate([
            switchButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            switchButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            switchButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
