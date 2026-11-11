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

    /// Carries the dragged row. A type of its own, so that text dragged in
    /// from another app is not taken for a row.
    private static let sourceRowPasteboardType = NSPasteboard.PasteboardType("com.JH.LyricsX.lyrics-source-row")

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
        sourceTableView.isEnabled = mode.usesSourcePriorityOrder
        sourceTableView.alphaValue = mode.usesSourcePriorityOrder ? 1.0 : 0.5
    }

    private func savePriorityOrder() {
        defaults[.lyricsSourcePriorityOrder] = sourcePriorityOrder
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

        if tableColumn?.identifier.rawValue == "priority" {
            return "\(row + 1)"
        } else if tableColumn?.identifier.rawValue == "source" {
            return source
        }

        return nil
    }

    func tableView(_ tableView: NSTableView, writeRowsWith rowIndexes: IndexSet, to pboard: NSPasteboard) -> Bool {
        guard let row = rowIndexes.first else { return false }

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

        let cellView = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView

        if identifier.rawValue == "priority" {
            cellView?.textField?.stringValue = "\(row + 1)"
        } else if identifier.rawValue == "source" {
            cellView?.textField?.stringValue = sourcePriorityOrder[row]
        }

        return cellView
    }
}
