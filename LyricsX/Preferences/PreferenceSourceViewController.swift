//
//  PreferenceSourceViewController.swift
//  LyricsX
//
//  Created by Gol3vka on 2025/9/29.
//  Copyright © 2025 ddddxxx. All rights reserved.
//

import Cocoa
import LyricsXFoundation

class PreferenceSourceViewController: PreferenceViewController {
    
    @IBOutlet weak var enableSourcePriorityButton: NSButton!
    @IBOutlet weak var sourceTableView: NSTableView!
    
    private var availableSources: [String] = []
    private var sourcePriorityOrder: [String] = []
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Match the source list defined in LyricsKit, alphabetically sorted
        // TODO: fetch from LyricsKit dynamically if possible
        availableSources = [
            "Kugou",
            "LRCLIB",
            "NetEase",
            "QQMusic",
            "Spotify"
        ]
        
        enableSourcePriorityButton.state = defaults[.lyricsSourcePriorityEnabled] ? .on : .off
        sourcePriorityOrder = defaults[.lyricsSourcePriorityOrder] ?? availableSources
        for source in availableSources {
            if !sourcePriorityOrder.contains(source) {
                sourcePriorityOrder.append(source)
            }
        }
        sourcePriorityOrder = sourcePriorityOrder.filter { availableSources.contains($0) }
        
        sourceTableView.delegate = self
        sourceTableView.dataSource = self
        sourceTableView.registerForDraggedTypes([.string])
        
        updateUI()
    }
    
    @IBAction func toggleSourcePriority(_ sender: NSButton) {
        let enabled = sender.state == .on
        defaults[.lyricsSourcePriorityEnabled] = enabled
        updateUI()
    }
    
    private func updateUI() {
        sourceTableView.isEnabled = defaults[.lyricsSourcePriorityEnabled]
        sourceTableView.alphaValue = defaults[.lyricsSourcePriorityEnabled] ? 1.0 : 0.5
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
        
        pboard.declareTypes([.string], owner: self)
        pboard.setString("\(row)", forType: .string)
        return true
    }
    
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        if dropOperation == .above {
            return .move
        }
        return []
    }
    
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let data = info.draggingPasteboard.string(forType: .string),
              let sourceRow = Int(data) else { return false }
        
        let targetRow = row > sourceRow ? row - 1 : row
        let movedItem = sourcePriorityOrder.remove(at: sourceRow)
        sourcePriorityOrder.insert(movedItem, at: targetRow)
        
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
