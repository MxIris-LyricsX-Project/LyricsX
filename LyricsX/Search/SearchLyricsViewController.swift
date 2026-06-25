import AppKit
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
    var searchTask: Task<Void, Never>?
    var searchResult: [Lyrics] = []
    var artworkScoringTasks: [Task<Void, Never>] = []
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
            searchTask?.cancel()
            searchResult = []
            searchArtist = ""
            searchTitle = ""
            artworkView.image = #imageLiteral(resourceName: "missing_artwork")
            lyricsPreviewTextView.string = " "
            tableView.reloadData()
            return
        }
        var artist = track.artist ?? ""
        var title = track.title ?? ""
        // Prefer the native-script name a search plugin recovered for this
        // track over the localized title/artist the player reports.
        if case let .info(recoveredTitle, recoveredArtist)? = AppController.shared.currentLyrics?.searchPluginTerm {
            title = recoveredTitle
            artist = recoveredArtist
        }
        if (searchArtist, searchTitle) != (artist, title) {
            (searchArtist, searchTitle) = (artist, title)
            searchAction(nil)
        }
    }

    @IBAction func searchAction(_ sender: Any?) {
        searchTask?.cancel()
        artworkScoringTasks.forEach { $0.cancel() }
        artworkScoringTasks.removeAll()
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
        searchTask = Task { @MainActor in
            do {
                for try await lyrics in lyricsManager.lyrics(for: req) {
                    lyricsReceived(lyrics: lyrics)
                }
                progressIndicator.stopAnimation(nil)
            } catch is CancellationError {
                // Search was cancelled
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

    @MainActor
    func lyricsReceived(lyrics: Lyrics) {
        // Match by session id so plugin-expanded requests still belong.
        guard lyrics.metadata.request?.id == searchRequest?.id else {
            return
        }
        lyrics.filtrate()
        lyrics.recognizeLanguage()
        lyrics.metadata.needsPersist = true
        if let idx = searchResult.firstIndex(where: { lyricsHasHigherPriority(lyrics, over: $0) }) {
            searchResult.insert(lyrics, at: idx)
        } else {
            searchResult.append(lyrics)
        }
        scheduleArtworkScoring(for: lyrics)
        tableView.reloadData()
    }

    private func scheduleArtworkScoring(for lyrics: Lyrics) {
        guard defaults[.artworkSimilarityBoostEnabled],
              let url = lyrics.metadata.artworkURL else { return }
        let task = Task.detached {
            let matched = await ArtworkSimilarityScorer.shared.matches(artworkURL: url)
            guard matched, !Task.isCancelled else { return }
            await MainActor.run { [weak self] in 
                guard let self else { return }
                self.applyArtworkBonus(to: lyrics)
            }
        }
        artworkScoringTasks.append(task)
    }

    @MainActor
    private func applyArtworkBonus(to lyrics: Lyrics) {
        // The lyrics object may belong to a previous search whose results
        // have already been cleared; identity-check before mutating.
        guard searchResult.contains(where: { $0 === lyrics }) else { return }
        lyrics.artworkMatchBonus = ArtworkSimilarityScorer.matchBonus
        resortAfterArtworkScoring()
    }

    @MainActor
    private func resortAfterArtworkScoring() {
        let selectedLyrics: Lyrics?
        let selectedRow = tableView.selectedRow
        if selectedRow >= 0, selectedRow < searchResult.count {
            selectedLyrics = searchResult[selectedRow]
        } else {
            selectedLyrics = nil
        }

        // Replay the insertion-order semantics of `lyricsReceived` so that
        // results with equal effective quality keep their relative order.
        var reordered: [Lyrics] = []
        for lyrics in searchResult {
            if let idx = reordered.firstIndex(where: { lyricsHasHigherPriority(lyrics, over: $0) }) {
                reordered.insert(lyrics, at: idx)
            } else {
                reordered.append(lyrics)
            }
        }
        searchResult = reordered
        tableView.reloadData()

        if let selectedLyrics, let newIndex = searchResult.firstIndex(where: { $0 === selectedLyrics }) {
            tableView.selectRowIndexes(IndexSet(integer: newIndex), byExtendingSelection: false)
        }
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
        let lyrics = searchResult[index]
        guard let url = lyrics.metadata.artworkURL else {
            NSLog("[SearchArtwork] index=%d, service=%@, artworkURL=nil", index, lyrics.metadata.service ?? "unknown")
            artworkView.image = #imageLiteral(resourceName: "missing_artwork")
            return
        }

        NSLog("[SearchArtwork] index=%d, service=%@, url=%@", index, lyrics.metadata.service ?? "unknown", url.absoluteString)

        if let cacheImage = imageCache.object(forKey: url as NSURL) {
            artworkView.image = cacheImage
            return
        }

        artworkView.image = #imageLiteral(resourceName: "missing_artwork")

        URLSession.shared.dataTask(with: url) { data, response, error in
            guard let data = data, error == nil else {
                NSLog("[SearchArtwork] download FAILED: %@", error?.localizedDescription ?? "unknown")
                return
            }

            let httpResponse = response as? HTTPURLResponse
            NSLog("[SearchArtwork] download OK: %d bytes, HTTP %d, contentType=%@", data.count, httpResponse?.statusCode ?? 0, httpResponse?.value(forHTTPHeaderField: "Content-Type") ?? "unknown")

            guard let image = NSImage(data: data) else {
                let preview = String(data: data.prefix(200), encoding: .utf8) ?? "(binary)"
                NSLog("[SearchArtwork] NSImage init FAILED, data preview: %@", preview)
                return
            }

            self.imageCache.setObject(image, forKey: url as NSURL)
            DispatchQueue.main.async {
                self.updateImage()
            }
        }.resume()
    }
}
