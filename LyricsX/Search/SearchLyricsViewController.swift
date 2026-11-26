import AppKit
import Combine
import LyricsXFoundation
import MusicPlayer
import UIFoundation

@Loggable(subsystem: "com.JH.LyricsX.SearchLyrics", category: "SearchLyricsViewController")
class SearchLyricsViewController: NSViewController, NSTableViewDelegate, NSTableViewDataSource, NSTextFieldDelegate, ScrollLyricsViewDelegate, StoryboardViewController {
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
    /// The selected result, laid out by its timing and following playback.
    @IBOutlet var lyricsPreviewView: ScrollLyricsView!

    @IBOutlet var hideLrcPreviewConstraint: NSLayoutConstraint?
    @IBOutlet var normalConstraint: NSLayoutConstraint!

    private let previewPlaceholderLabel = NSTextField(labelWithString: NSLocalizedString(
        "Select a result to preview it with the song.",
        comment: "Search Lyrics panel: shown where the selected result's lyrics play along, while no result is selected"
    ))
    /// The result the preview shows. Selection changes that land on the same
    /// result — ranking moved it to another row — leave the preview alone.
    private var previewedLyrics: Lyrics?
    /// False once the user scrolls the preview by hand; selecting a result or
    /// double-clicking a line turns it back on.
    private var isPreviewTracking = true
    /// Whether a line of the preview is marked as the one playing.
    private var isPreviewShowingProgress = false
    private var previewLineCheck: Cancellable?
    /// Held while the window is on screen: a closed panel neither follows
    /// the playing track nor wakes up for playback.
    private var visibleWindowObservations: Set<AnyCancellable> = []
    private var previewScrollObservation: AnyCancellable?

    override func viewDidLoad() {
        super.viewDidLoad()

        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        normalConstraint.isActive = false
        configurePreview()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reloadKeyword()
        observePlaybackWhileVisible()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        visibleWindowObservations.removeAll()
        previewLineCheck?.cancel()
        previewLineCheck = nil
    }

    func reloadKeyword() {
        guard let track = selectedPlayer.currentTrack else {
            searchTask?.cancel()
            searchedTrack = nil
            panelResults = LyricsSearchPanelResults(trackIdentifier: nil)
            searchArtist = ""
            searchTitle = ""
            artworkView.image = #imageLiteral(resourceName: "missing_artwork")
            tableView.reloadData()
            showSelectedResultInPreview()
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
        // Another track under the same name — another version of the song —
        // still needs its own search: the results belong to the track they
        // were found for.
        if (searchArtist, searchTitle) != (artist, title) || panelResults.needsNewSearch(whilePlaying: track.id) {
            (searchArtist, searchTitle) = (artist, title)
            search(for: track)
        }
    }

    @IBAction func searchAction(_ sender: Any?) {
        search(for: selectedPlayer.currentTrack)
    }

    /// Runs the search in the title and artist fields for `track`, which the
    /// results then belong to.
    private func search(for track: MusicTrack?) {
        searchTask?.cancel()
        artworkScoringTasks.forEach { $0.cancel() }
        artworkScoringTasks.removeAll()
        progressObservation?.invalidate()
        artworkView.image = #imageLiteral(resourceName: "missing_artwork")

        searchedTrack = track
        panelResults = LyricsSearchPanelResults(trackIdentifier: track?.id)
        let duration = track?.duration ?? 0
        let req = LyricsSearchRequest(searchTerm: .info(title: searchTitle, artist: searchArtist), duration: duration, limit: 8)
        searchRequest = req
        progressIndicator.startAnimation(nil)
        tableView.reloadData()
        showSelectedResultInPreview()
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
        let didPersist = performOnLyricsDisplayQueue {
            lrc.associateWithTrack(track)
            lrc.markAsUserPicked(origin: .searchPanel)
            lrc.metadata.needsPersist = true
            return lrc.persist()
        }
        rememberSelection(of: lrc, for: track, ifPersisted: didPersist)
    }

    /// A pick here is one more hand pick, so the table of hand picks hears
    /// of it like any other — otherwise an entry an earlier pick left there
    /// (from the next-candidate shortcut or the Local Lyrics menu) would bring
    /// that pick back on the next play.
    private func rememberSelection(of lrc: Lyrics, for track: MusicTrack, ifPersisted didPersist: Bool) {
        guard didPersist, let persistedURL = lrc.metadata.localURL else {
            return
        }
        AppController.shared.rememberLyricsSelection(.file(persistedURL), for: track)
    }

    private func apply(_ lrc: Lyrics, to track: MusicTrack) {
        clearRejection(of: track)
        // On the lyrics display queue, like every other change to the lyrics
        // on screen: a write from here would race one from there.
        let didPersist = performOnLyricsDisplayQueue {
            lrc.associateWithTrack(track)
            // The panel's Score column has usually scored it already; if not,
            // ranking the pool below would score it after it went on screen.
            lrc.cacheQualityBeforeDisplay()
            // Applying a result from this panel is the clearest statement of intent
            // there is, so the file records that a person chose it — the "ignore
            // saved lyrics" switch skips what LyricsX saved on its own, not this.
            lrc.markAsUserPicked(origin: .searchPanel)
            AppController.shared.currentLyrics = lrc
            // Written now rather than at the next track change: the mark is only
            // worth anything once it is on disk, and the choice is already made.
            lrc.metadata.needsPersist = true
            return lrc.persist()
        }
        // Hand the whole sorted list over, not just the pick: the
        // next-candidate shortcut should carry on from what the user chose
        // here instead of walking a pool built by the automatic search.
        AppController.shared.adoptLyricsCandidates(searchResult, selecting: lrc, for: track)
        rememberSelection(of: lrc, for: track, ifPersisted: didPersist)
        if defaults[.writeToiTunesAutomatically] {
            AppController.shared.writeToiTunes(overwrite: true)
        }
    }

    // MARK: - Following the playing track

    private func observePlaybackWhileVisible() {
        visibleWindowObservations.removeAll()
        // `currentTrackWillChange` publishes before the player's
        // `currentTrack` changes, so the track comes from the publisher, and
        // the hop to the main queue lets everything read afterwards see it.
        selectedPlayer.currentTrackWillChange
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] track in
                self?.playingTrackChanged(to: track)
            }
            .store(in: &visibleWindowObservations)
        selectedPlayer.playbackStateWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshPreviewProgress(animated: false)
            }
            .store(in: &visibleWindowObservations)
        // The preview shows the lyrics as applying them would, so it moves
        // with every offset `adjustedTimeDelay` adds up.
        defaults.publisher(for: [.globalLyricsOffset])
            .signal()
            .merge(with: PlaybackRouteLyricsOffsetController.shared.currentRouteOffsetDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.refreshPreviewProgress(animated: false)
            }
            .store(in: &visibleWindowObservations)
        // A narrower window wraps lines anew, which moves the playing line.
        NotificationCenter.default.publisher(for: NSWindow.didResizeNotification, object: view.window)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshPreviewProgress(animated: false)
            }
            .store(in: &visibleWindowObservations)
    }

    private func playingTrackChanged(to track: MusicTrack?) {
        guard let track, panelResults.needsNewSearch(whilePlaying: track.id) else {
            // The same track, or nothing playing: the results stay, and the
            // preview follows playback only while their track plays.
            refreshPreviewProgress(animated: false)
            return
        }
        // Whatever is being typed was for the track that stopped; ending the
        // edit first keeps the field editor from writing it back over the
        // new track's name.
        view.window?.endEditing(for: nil)
        // The player's own names: the name a search plugin recovered comes
        // from the lyrics on screen, which may still be the previous track's
        // until the lyrics queue has caught up with the change.
        (searchArtist, searchTitle) = (track.artist ?? "", track.title ?? "")
        search(for: track)
    }

    // MARK: - Preview

    private func configurePreview() {
        lyricsPreviewView.lyricsViewDelegate = self
        lyricsPreviewView.fixedFont = .systemFont(ofSize: NSFont.systemFontSize)
        lyricsPreviewView.textColor = .secondaryLabelColor
        // The playing line stands out in the label colour, and on lyrics with
        // inline time tags each character turns to the accent colour as its
        // tag says it starts being sung: the tags can be checked against the
        // song character by character. Lines without tags turn to the accent
        // colour whole.
        lyricsPreviewView.highlightColor = .controlAccentColor
        lyricsPreviewView.karaokeUnsungTextColor = .labelColor
        lyricsPreviewView.setupTextContents(lyrics: nil)
        // The scroll wheel reports only scrolls with momentum; a slow drag on
        // the trackpad starts a live scroll without one.
        previewScrollObservation = NotificationCenter.default
            .publisher(for: NSScrollView.willStartLiveScrollNotification, object: lyricsPreviewView)
            .sink { [weak self] _ in
                self?.isPreviewTracking = false
            }

        previewPlaceholderLabel.textColor = .tertiaryLabelColor
        previewPlaceholderLabel.alignment = .center
        previewPlaceholderLabel.lineBreakMode = .byWordWrapping
        previewPlaceholderLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(previewPlaceholderLabel)
        NSLayoutConstraint.activate([
            previewPlaceholderLabel.centerXAnchor.constraint(equalTo: lyricsPreviewView.centerXAnchor),
            previewPlaceholderLabel.centerYAnchor.constraint(equalTo: lyricsPreviewView.centerYAnchor),
            previewPlaceholderLabel.leadingAnchor.constraint(greaterThanOrEqualTo: lyricsPreviewView.leadingAnchor, constant: 20),
        ])
    }

    /// Puts the selected result in the preview, if it is not there already.
    private func showSelectedResultInPreview() {
        let selectedLyrics = panelResults.selectedResult
        guard selectedLyrics !== previewedLyrics else {
            return
        }
        previewedLyrics = selectedLyrics
        isPreviewTracking = true
        isPreviewShowingProgress = false
        lyricsPreviewView.setupTextContents(lyrics: selectedLyrics)
        previewPlaceholderLabel.isHidden = selectedLyrics != nil
        refreshPreviewProgress(animated: false)
    }

    /// Marks the line playing now and the characters of it sung so far,
    /// scrolls it to the middle unless the user scrolled away, and comes back
    /// when the next line or character starts.
    private func refreshPreviewProgress(animated: Bool) {
        previewLineCheck?.cancel()
        previewLineCheck = nil
        guard let lyrics = previewedLyrics,
              panelResults.previewFollowsPlayback(whilePlaying: selectedPlayer.currentTrack?.id) else {
            if isPreviewShowingProgress {
                // Laying the lyrics out again is what unmarks the last line.
                isPreviewShowingProgress = false
                lyricsPreviewView.setupTextContents(lyrics: previewedLyrics)
            }
            return
        }
        let playbackState = selectedPlayer.playbackState
        let playbackTime = playbackState.lyricsDisplayTime(trackDuration: selectedPlayer.currentTrack?.duration)
        // The same delay the lyrics would get once applied: their own offset,
        // the global one, and the one for this player and output device.
        let position = playbackTime + lyrics.adjustedTimeDelay
        let marksAnotherLine = lyricsPreviewView.highlight(position: position)
        isPreviewShowingProgress = true
        // A timed refresh within the same line only moves the karaoke
        // progress; every other refresh puts the line back in the middle.
        if isPreviewTracking, marksAnotherLine || !animated {
            scrollPreview(to: position, animated: animated)
        }
        guard playbackState.isPlaying else {
            return
        }
        // Past the last line, check every second, as `AppController` does,
        // for a repeat that starts the track over without a state change.
        let delayUntilNextCheck = lyricsPreviewView.nextHighlightChange(after: position)
            .map { max(0, $0 - position) } ?? 1
        let queue = DispatchQueue.main
        previewLineCheck = queue.schedule(
            after: queue.now.advanced(by: .seconds(delayUntilNextCheck)),
            interval: .seconds(42),
            tolerance: .milliseconds(20)
        ) { [weak self] in
            self?.refreshPreviewProgress(animated: true)
        }
    }

    private func scrollPreview(to position: TimeInterval, animated: Bool) {
        guard animated else {
            lyricsPreviewView.scroll(position: position)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.allowsImplicitAnimation = true
            context.timingFunction = .swiftOut
            lyricsPreviewView.scroll(position: position)
        }
    }

    // MARK: - ScrollLyricsViewDelegate

    func doubleClickLyricsLine(at position: TimeInterval) {
        guard let lyrics = previewedLyrics,
              panelResults.previewFollowsPlayback(whilePlaying: selectedPlayer.currentTrack?.id) else {
            return
        }
        selectedPlayer.playbackTime = position - lyrics.adjustedTimeDelay
        isPreviewTracking = true
        // Marked at once; the player's next state report confirms it and
        // schedules the line after.
        lyricsPreviewView.highlight(position: position)
        scrollPreview(to: position, animated: true)
    }

    func lyricsViewContextMenu() -> NSMenu {
        // An empty menu is no menu: the preview has nothing to offer there.
        NSMenu()
    }

    func scrollWheelDidStartScroll() {
        isPreviewTracking = false
    }

    func scrollWheelDidEndScroll() {}

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
        // On the lyrics display queue: a result already applied is the lyrics
        // on screen, and the bonus is kept in its metadata, which that queue
        // reads.
        performOnLyricsDisplayQueue {
            lyrics.artworkMatchBonus = ArtworkSimilarityScorer.matchBonus
        }
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
        showSelectedResultInPreview()
        guard index >= 0 else {
            return
        }
        if hideLrcPreviewConstraint?.isActive == true {
            expandPreview()
        }
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
            // The preview was laid out below the window until now; put the
            // playing line in the middle of where it ended up.
            self.refreshPreviewProgress(animated: false)
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
