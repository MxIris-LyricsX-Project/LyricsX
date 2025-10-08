import AppKit
import Combine
import LyricsXFoundation
import MusicPlayer
import UIFoundation

class SearchLyricsViewController: NSViewController, NSTableViewDelegate, NSTableViewDataSource, NSTextFieldDelegate, StoryboardViewController {
    var imageCache = NSCache<NSURL, NSImage>()

    @objc dynamic var searchArtist = ""
    @objc dynamic var searchTitle = "" {
        didSet {
            searchButton.isEnabled = !searchTitle.isEmpty
        }
    }

    var lyricsManager: LyricsProvider { AppController.shared.lyricsManager }
    var searchRequest: LyricsSearchRequest?
    var searchCanceller: Cancellable?
    var searchResult: [Lyrics] = []
    var progressObservation: NSKeyValueObservation?

    @IBOutlet var artworkView: NSImageView!
    @IBOutlet var tableView: NSTableView!
    @IBOutlet var searchButton: NSButton!
    @IBOutlet var progressIndicator: NSProgressIndicator!
    // NSTextView doesn't support weak references
    @IBOutlet var lyricsPreviewTextView: NSTextView!

    @IBOutlet var hideLrcPreviewConstraint: NSLayoutConstraint?
    @IBOutlet var normalConstraint: NSLayoutConstraint!

    override func viewDidLoad() {
        super.viewDidLoad()

        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        normalConstraint.isActive = false
    }

    override func viewWillAppear() {
        reloadKeyword()
    }

    func reloadKeyword() {
        guard let track = selectedPlayer.currentTrack else {
            searchCanceller?.cancel()
            searchResult = []
            searchArtist = ""
            searchTitle = ""
            artworkView.image = #imageLiteral(resourceName: "missing_artwork")
            lyricsPreviewTextView.string = " "
            tableView.reloadData()
            return
        }
        let artist = track.artist ?? ""
        let title = track.title ?? ""
        if (searchArtist, searchTitle) != (artist, title) {
            (searchArtist, searchTitle) = (artist, title)
            searchAction(nil)
        }
    }

    @IBAction func searchAction(_ sender: Any?) {
        searchCanceller?.cancel()
        progressObservation?.invalidate()
        searchResult = []
        artworkView.image = #imageLiteral(resourceName: "missing_artwork")
        lyricsPreviewTextView.string = " "

        let track = selectedPlayer.currentTrack
        let duration = track?.duration ?? 0
        let req = LyricsSearchRequest(searchTerm: .info(title: searchTitle, artist: searchArtist), duration: duration, limit: 8)
        searchRequest = req
        progressIndicator.startAnimation(nil)
        tableView.reloadData()
        Task {
            do {
                for try await lyrics in lyricsManager.lyrics(for: req) {
                    lyricsReceived(lyrics: lyrics)
                }
                progressIndicator.stopAnimation(nil)
            } catch {
                print(error)
            }
        }
    }

    @IBAction func useLyricsAction(_ sender: Any) {
        guard let index = tableView.selectedRowIndexes.first else {
            return
        }

        guard let track = selectedPlayer.currentTrack else {
            return
        }
        if let index = defaults[.noSearchingTrackIds].firstIndex(of: track.id) {
            defaults[.noSearchingTrackIds].remove(at: index)
        }
        if let index = defaults[.noSearchingAlbumNames].firstIndex(of: track.album ?? "") {
            defaults[.noSearchingAlbumNames].remove(at: index)
        }

        let lrc = searchResult[index]
        lrc.associateWithTrack(track)
        AppController.shared.currentLyrics = lrc
        if defaults[.writeToiTunesAutomatically] {
            AppController.shared.writeToiTunes(overwrite: true)
        }
    }

    // MARK: - LyricsSourceDelegate

    func lyricsReceived(lyrics: Lyrics) {
        guard lyrics.metadata.request == searchRequest else {
            return
        }
        lyrics.filtrate()
        lyrics.recognizeLanguage()
        lyrics.metadata.needsPersist = true
        if let idx = searchResult.firstIndex(where: { shouldInsertBefore(lyrics, $0) }) {
            searchResult.insert(lyrics, at: idx)
        } else {
            searchResult.append(lyrics)
        }
        DispatchQueue.main.async {
            self.tableView.reloadData()
        }
    }

    // Same as AppController.swift
    private func shouldInsertBefore(_ newLyrics: Lyrics, _ existingLyrics: Lyrics) -> Bool {
        if defaults[.lyricsSourcePriorityEnabled] {
            let sourceOrder = defaults[.lyricsSourcePriorityOrder] ?? []
            let newSource = newLyrics.metadata.service ?? ""
            let existingSource = existingLyrics.metadata.service ?? ""

            let newSourceIndex = sourceOrder.firstIndex(of: newSource) ?? Int.max
            let existingSourceIndex = sourceOrder.firstIndex(of: existingSource) ?? Int.max

            if newSourceIndex != existingSourceIndex {
                return newSourceIndex < existingSourceIndex
            }
        }

        return newLyrics.quality > existingLyrics.quality
    }

    // MARK: - TableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        return searchResult.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard let ident = tableColumn?.identifier else {
            return nil
        }

        switch ident {
        case .searchResultColumnTitle:
            return searchResult[row].idTags[.title] ?? "[lacking]"
        case .searchResultColumnArtist:
            return searchResult[row].idTags[.artist] ?? "[lacking]"
        case .searchResultColumnSource:
            return searchResult[row].metadata.service ?? "[lacking]"
        default:
            return nil
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let index = tableView.selectedRow
        guard index >= 0 else {
            return
        }
        if hideLrcPreviewConstraint?.isActive == true {
            expandPreview()
        }
        lyricsPreviewTextView.string = searchResult[index].description
        updateImage()
    }

    func tableView(_ tableView: NSTableView, writeRowsWith rowIndexes: IndexSet, to pboard: NSPasteboard) -> Bool {
        let lrcContent = searchResult[rowIndexes.first!].description
        pboard.declareTypes([.string, .filePromise], owner: self)
        pboard.setString(lrcContent, forType: .string)
        pboard.setPropertyList(["lrc"], forType: .filePromise)
        return true
    }

    func tableView(_ tableView: NSTableView, namesOfPromisedFilesDroppedAtDestination dropDestination: URL, forDraggedRowsWith indexSet: IndexSet) -> [String] {
        return indexSet.compactMap { index -> String? in
            let fileName = searchResult[index].fileName ?? "Unknown"

            let destURL = dropDestination.appendingPathComponent(fileName)
            let lrcStr = searchResult[index].description

            do {
                try lrcStr.write(to: destURL, atomically: true, encoding: .utf8)
            } catch {
                log(error.localizedDescription)
                return nil
            }

            return fileName
        }
    }

    // MARK: - NSTextFieldDelegate

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            searchAction(nil)
            return true
        }
        return false
    }

    private func expandPreview() {
        let expandingHeight = -view.subviews.reduce(0) { min($0, $1.frame.minY) }
        let windowFrame = view.window!.frame.with {
            $0.size.height += expandingHeight
            $0.origin.y -= expandingHeight
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.33
            context.allowsImplicitAnimation = true
            context.timingFunction = .swiftOut
            hideLrcPreviewConstraint?.animator().isActive = false
            view.window?.setFrame(windowFrame, display: false, animate: true)
            view.needsUpdateConstraints = true
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
        }, completionHandler: {
            self.normalConstraint.isActive = true
        })
    }

    private func updateImage() {
        let index = tableView.selectedRow
        guard index >= 0 else {
            return
        }
        guard let url = searchResult[index].metadata.artworkURL else {
            artworkView.image = #imageLiteral(resourceName: "missing_artwork")
            return
        }

        if let cacheImage = imageCache.object(forKey: url as NSURL) {
            artworkView.image = cacheImage
            return
        }

        artworkView.image = #imageLiteral(resourceName: "missing_artwork")
//        DispatchQueue.global().async {
//            guard let image = NSImage(contentsOf: url) else {
//                return
//            }
//            self.imageCache.setObject(image, forKey: url as NSURL)
//            DispatchQueue.main.async {
//                self.updateImage()
//            }
//        }

        // Use URLSession for asynchronous network requests to avoid blocking threads.
        // This is the recommended way to fetch remote data.
        URLSession.shared.dataTask(with: url) { data, response, error in
            // This completion handler is executed on a background thread
            // once the network request is complete.

            // 1. Check for errors and ensure we received valid data.
            guard let data = data, error == nil else {
                print("Failed to download image data: \(error?.localizedDescription ?? "Unknown error")")
                return
            }

            // 2. Create the image from the downloaded data.
            // This is now very fast because the data is already in memory.
            guard let image = NSImage(data: data) else {
                print("Failed to create image from data.")
                return
            }

            // 3. The completion handler is already on a background thread,
            // so it's safe to update the cache here.
            self.imageCache.setObject(image, forKey: url as NSURL)

            // 4. Switch back to the main thread to perform any UI updates.
            DispatchQueue.main.async {
                self.updateImage()
            }

        }.resume() // IMPORTANT: Don't forget to start the task!
    }
}
