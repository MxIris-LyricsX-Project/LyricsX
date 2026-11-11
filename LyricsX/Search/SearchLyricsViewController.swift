import AppKit
import LyricsXFoundation
import MusicPlayer
import UIFoundation

@Loggable(subsystem: "com.JH.LyricsX.SearchLyrics", category: "SearchLyricsViewController")
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
    /// The track the current search ran for, which a result the user applies
    /// belongs to even once another track plays.
    private var searchedTrack: MusicTrack?
    private var panelResults = LyricsSearchPanelResults<Lyrics>(trackIdentifier: nil)
    private var searchResult: [Lyrics] { panelResults.results }
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
            searchedTrack = nil
            panelResults = LyricsSearchPanelResults(trackIdentifier: nil)
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
        artworkView.image = #imageLiteral(resourceName: "missing_artwork")
        lyricsPreviewTextView.string = " "

        let track = selectedPlayer.currentTrack
        searchedTrack = track
        panelResults = LyricsSearchPanelResults(trackIdentifier: track?.id)
        let duration = track?.duration ?? 0
        let req = LyricsSearchRequest(searchTerm: .info(title: searchTitle, artist: searchArtist), duration: duration, limit: 8)
        searchRequest = req
        progressIndicator.startAnimation(nil)
        tableView.reloadData()
        searchTask = Task { @MainActor in
            do {
                let completion = try await LyricsSearchCompletion.consume(lyricsManager.lyrics(for: req)) { lyrics in
                    lyricsReceived(lyrics: lyrics)
                }
                // Cancelled by the search that replaced it, whose progress
                // the indicator now shows.
                guard completion == .finished else { return }
                progressIndicator.stopAnimation(nil)
            } catch {
                #log(.error, "Lyrics search failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @IBAction func useLyricsAction(_ sender: Any) {
        guard let lrc = panelResults.selectedResult else {
            return
        }
        switch panelResults.application(whilePlaying: selectedPlayer.currentTrack?.id) {
        case .currentTrack:
            guard let track = selectedPlayer.currentTrack else {
                return
            }
            apply(lrc, to: track)
        case .originalTrackOnly:
            guard let searchedTrack else {
                return
            }
            save(lrc, forTrackNoLongerPlaying: searchedTrack)
        }
    }

    /// Clears an earlier "wrong lyrics" or "don't search this album" verdict:
    /// picking lyrics by hand contradicts it.
    private func clearRejection(of track: MusicTrack) {
        if let index = defaults[.noSearchingTrackIds].firstIndex(of: track.id) {
            defaults[.noSearchingTrackIds].remove(at: index)
        }
        if let index = defaults[.noSearchingAlbumNames].firstIndex(of: track.album ?? "") {
            defaults[.noSearchingAlbumNames].remove(at: index)
        }
    }

    /// The search ran for a track that has stopped playing since, so the
    /// pick is saved for that track — the next time it plays it gets these
    /// lyrics — and the lyrics on screen, another track's, are left alone.
    private func save(_ lrc: Lyrics, forTrackNoLongerPlaying track: MusicTrack) {
        clearRejection(of: track)
        performOnLyricsDisplayQueue {
            lrc.associateWithTrack(track)
            lrc.markAsUserPicked(origin: .searchPanel)
            lrc.metadata.needsPersist = true
            lrc.persist()
        }
    }

    private func apply(_ lrc: Lyrics, to track: MusicTrack) {
        clearRejection(of: track)
        // On the lyrics display queue, like every other change to the lyrics
        // on screen: a write from here would race one from there.
        performOnLyricsDisplayQueue {
            lrc.associateWithTrack(track)
            // Applying a result from this panel is the clearest statement of intent
            // there is, so the file records that a person chose it — the "ignore
            // saved lyrics" switch skips what LyricsX saved on its own, not this.
            lrc.markAsUserPicked(origin: .searchPanel)
            AppController.shared.currentLyrics = lrc
            // Written now rather than at the next track change: the mark is only
            // worth anything once it is on disk, and the choice is already made.
            lrc.metadata.needsPersist = true
            lrc.persist()
        }
        // Hand the whole sorted list over, not just the pick: the
        // next-candidate shortcut should carry on from what the user chose
        // here instead of walking a pool built by the automatic search.
        AppController.shared.adoptLyricsCandidates(searchResult, selecting: lrc, for: track)
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
        panelResults.insert(lyrics, outranks: { lyricsHasHigherPriority($0, over: $1) })
        scheduleArtworkScoring(for: lyrics)
        reloadResultsKeepingSelection()
    }

    /// Reloads the table and puts the selection back on the selected result,
    /// which ranking may have moved to another row.
    private func reloadResultsKeepingSelection() {
        tableView.reloadData()
        if let selectedIndex = panelResults.selectedIndex, selectedIndex != tableView.selectedRow {
            tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        }
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
        panelResults.rerank(outranks: { lyricsHasHigherPriority($0, over: $1) })
        reloadResultsKeepingSelection()
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
        case .searchResultColumnQuality:
            return qualityDisplayText(for: searchResult[row])
        default:
            return nil
        }
    }

    // The score the row was ranked by, plus — when the artwork-similarity boost
    // actually moved it — the part of that score the boost contributed. Without
    // the second half a boosted row just looks inexplicably good.
    private func qualityDisplayText(for lyrics: Lyrics) -> String {
        let total = String(format: "%.2f", effectiveQuality(lyrics))
        let artworkBonus = effectiveArtworkBonus(lyrics)
        guard artworkBonus != 0 else {
            return total
        }
        return total + String(format: " (%+.2f)", artworkBonus)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let index = tableView.selectedRow
        panelResults.select(at: index >= 0 ? index : nil)
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
