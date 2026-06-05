import AppKit
import Combine
import Regex
import OpenCC
import MusicPlayer
import LyricsXFoundation
import WidgetKit
import LyricsXWidgetShared

@Loggable(subsystem: "com.JH.LyricsX.AppController", category: "AppController")
final class AppController: NSObject {
    static let shared = AppController()

    var lyricsManager: LyricsProvider

    @Published var currentLyrics: Lyrics? {
        willSet {
            willChangeValue(forKey: "lyricsOffset")
            currentLineIndex = nil
        }
        didSet {
            didChangeValue(forKey: "lyricsOffset")
            scheduleCurrentLineCheck()
        }
    }

    @Published var currentLineIndex: Int?

    var searchRequest: LyricsSearchRequest?
    var searchTask: Task<Void, Never>?

    private var cancelBag = Set<AnyCancellable>()

    private let widgetDataStore = WidgetDataStore(groupIdentifier: lyricsXGroupIdentifier)

    @objc dynamic var lyricsOffset: Int {
        get {
            return currentLyrics?.offset ?? 0
        }
        set {
            currentLyrics?.offset = newValue
            currentLyrics?.metadata.needsPersist = true
            scheduleCurrentLineCheck()
        }
    }

    private override init() {
        self.lyricsManager = LyricsProviders.Group()
        super.init()
        // Dedup by track id (MusicTrack.Equatable compares ids) so that
        // SystemMedia's artwork-only updates within the same song do not
        // re-trigger lyrics search.
        selectedPlayer.currentTrackWillChange
            .removeDuplicates()
            .signal()
            .receive(on: DispatchQueue.lyricsDisplay)
            .invoke(AppController.currentTrackChanged, weaklyOn: self)
            .store(in: &cancelBag)
        selectedPlayer.playbackStateWillChange
            .receive(on: DispatchQueue.lyricsDisplay)
            .invoke(AppController.playbackStateChanged, weaklyOn: self)
            .store(in: &cancelBag)
        // `lyrics.adjustedTimeDelay` reads `globalLyricsOffset` dynamically, so a
        // change must reschedule `currentLineIndex`. Per-track offset is handled
        // by the `lyricsOffset` setter; the global key has no setter path here.
        defaults.publisher(for: [.globalLyricsOffset])
            .signal()
            .receive(on: DispatchQueue.lyricsDisplay)
            .sink { [weak self] in
                self?.scheduleCurrentLineCheck()
            }
            .store(in: &cancelBag)

        // Rebuild the provider group when something that gates the Apple Music
        // name-recovery plugin changes. The plugin is mounted only when the
        // user toggle is on AND the active player is Apple Music, so we have
        // to react to both the preference and any change in the active player:
        //
        // - the recovery toggle itself;
        // - preferred-player switch in General settings;
        // - NowPlaying / SystemMedia routing to a different app's track
        //   (e.g. user starts playing in Apple Music while another player
        //   was previously the active source).
        Publishers.MergeMany(
            defaults.publisher(for: [.appleMusicNameRecoveryEnabled]).signal().eraseToAnyPublisher(),
            defaults.publisher(for: [.preferredPlayerIndex, .useSystemWideNowPlaying, .systemWideNowPlayingAppList]).signal().eraseToAnyPublisher(),
            selectedPlayer.currentTrackWillChange.signal().eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)
        .map { (defaults[.appleMusicNameRecoveryEnabled], selectedPlayer.name) }
        .removeDuplicates(by: ==)
        .sink { [weak self] _ in
            Task { @MainActor in self?.updateLyricsManager() }
        }
        .store(in: &cancelBag)

        workspaceNC.publisher(for: NSWorkspace.didTerminateApplicationNotification, object: nil)
            .sink { notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let bundleID = application.bundleIdentifier
                if defaults[.launchAndQuitWithPlayer], (selectedPlayer.designatedPlayer as? MusicPlayers.Scriptable)?.playerBundleID == bundleID {
                    NSApplication.shared.terminate(self)
                }
            }.store(in: &cancelBag)

        // Widget data bridge.
        //
        // Lyrics/track change and playback state change (play/pause/seek)
        // alter the timeline structure, so they rebuild the timeline.
        //
        // Line index change is handled separately and only refreshes the
        // dataStore — the timeline already contains future entries that
        // drive the next line transition autonomously, so a reload here
        // would only add WidgetKit scheduling latency (~hundreds of ms,
        // the visible "widget lyrics lag" before this change).
        $currentLyrics
            .signal()
            .receive(on: DispatchQueue.lyricsDisplay)
            .sink { [weak self] in
                guard let self = self else { return }
                reloadWidgetTimeline()
            }
            .store(in: &cancelBag)

        // Pause is observed as a single, clean willChange event — react
        // immediately. Resume from MusicPlayer's SystemMedia/mediaremote-
        // adapter backend, in contrast, fires two willChange events
        // 160ms–900ms apart: the first carries a stale `time` (off by
        // several seconds), the second carries the real position. Naively
        // reloading on the first event makes the widget fetch a timeline
        // built from the wrong `time`, and WidgetKit's reload throttle
        // can push the corrective fetch out by several seconds. So we
        // route the two cases separately: the resume path is debounced
        // long enough to absorb the longest jitter window we've measured,
        // while the pause path stays on the fast `receive(on:)` route.
        selectedPlayer.playbackStateWillChange
            .filter { !$0.isPlaying }
            .receive(on: DispatchQueue.lyricsDisplay)
            .sink { [weak self] state in
                guard let self = self else { return }
                reloadWidgetTimeline(playbackState: state)
            }
            .store(in: &cancelBag)

        selectedPlayer.playbackStateWillChange
            .filter { $0.isPlaying }
            .debounce(for: .milliseconds(1000), scheduler: DispatchQueue.lyricsDisplay)
            .sink { [weak self] state in
                guard let self = self else { return }
                reloadWidgetTimeline(playbackState: state)
            }
            .store(in: &cancelBag)

        $currentLineIndex
            .signal()
            .receive(on: DispatchQueue.lyricsDisplay)
            .sink { [weak self] in
                guard let self = self else { return }
                updateWidgetSnapshot()
            }
            .store(in: &cancelBag)

        currentTrackChanged()

        Task { @MainActor in
            updateLyricsManager()
        }
    }

    @MainActor
    func updateLyricsManager() {
        let musixmatchToken = defaults[.musixmatchToken].flatMap { $0.isEmpty ? nil : $0 }
        let providers: [LyricsProvider] = [
            LyricsProviders.Service.netease.create(),
            LyricsProviders.Service.qq.create(),
            LyricsProviders.Service.kugou.create(),
            LyricsProviders.Service.lrclib.create(),
            LyricsProviders.Service.musixmatch.create(.init(usertoken: musixmatchToken)),
        ]
        // Route B: for Apple Music tracks, a search plugin recovers the
        // native-script name via the Apple Music catalog so the providers
        // can match it. The plugin runs upstream of the providers — it
        // widens the search, it is not a lyrics source itself.
        var plugins: [LyricsSearchRequestPlugin] = []
        if #available(macOS 12.0, *), defaults[.appleMusicNameRecoveryEnabled], selectedPlayer.name == .appleMusic {
            plugins.append(AppleMusicNameRecoveryPlugin())
        }
        lyricsManager = LyricsProviders.Group(providers: providers, plugins: plugins)
    }

    var currentLineCheckSchedule: Cancellable?

    // Reschedule on every publish. The schedule path is cheap (timer
    // cancel + binary search + new timer, ~10µs per call) and any form
    // of dedup here would let the previously scheduled timer keep
    // firing on a stale wallclock anchor, lagging or leading the real
    // playback boundary. Passing the anchor-derived `PlaybackState`
    // from the publish through to the schedule, instead of re-reading
    // the cached `selectedPlayer` value, is preserved by routing every
    // event through here.
    private func playbackStateChanged(_ playbackState: PlaybackState) {
        scheduleCurrentLineCheck(playbackState: playbackState)
    }

    func scheduleCurrentLineCheck(playbackState: PlaybackState? = nil) {
        currentLineCheckSchedule?.cancel()
        guard let lyrics = currentLyrics else {
            return
        }
        // Use the anchor-derived `PlaybackState.time` rather than the
        // delegate-cached `selectedPlayer.playbackTime`. The latter can lag
        // around repeat-one wrap and track-change boundaries, leaving the
        // lyric index stalled while playback has actually moved on.
        let resolvedPlaybackState = playbackState ?? MusicPlayers.Selected.shared.playbackState
        let trackDuration = selectedPlayer.currentTrack?.duration
        let playbackTime = resolvedPlaybackState.lyricsDisplayTime(trackDuration: trackDuration)
        let (index, next) = lyrics[playbackTime + lyrics.adjustedTimeDelay]
        if currentLineIndex != index {
            currentLineIndex = index
        }
        let q = DispatchQueue.lyricsDisplay
        if let next = next, resolvedPlaybackState.isPlaying {
            let dt = max(0, lyrics.lines[next].position - playbackTime - lyrics.adjustedTimeDelay)
            currentLineCheckSchedule = q.schedule(
                after: q.now.advanced(by: .seconds(dt)),
                interval: .seconds(42),
                tolerance: .milliseconds(20)
            ) { [unowned self] in
                self.scheduleCurrentLineCheck()
            }
        } else if resolvedPlaybackState.isPlaying {
            // Past the last lyric line but still playing: keep a recovery edge
            // for missed state publishes, and snap the next check to the track
            // duration plus a short confirmation window when it is closer than
            // the regular polling interval.
            // Combined with `lyricsDisplayTime(trackDuration:)`, this lets
            // repeat-one wrap back to the opening lyric without waiting for the
            // next one-second poll when the player keeps the old playback anchor.
            let nextCheckDelay = Self.lastLineCheckDelay(playbackTime: playbackTime, trackDuration: trackDuration)
            let tolerance: DispatchQueue.SchedulerTimeType.Stride = nextCheckDelay < 1 ? .milliseconds(20) : .milliseconds(100)
            currentLineCheckSchedule = q.schedule(
                after: q.now.advanced(by: .seconds(nextCheckDelay)),
                interval: .seconds(1),
                tolerance: tolerance
            ) { [unowned self] in
                self.scheduleCurrentLineCheck()
            }
        }
    }

    private static func lastLineCheckDelay(playbackTime: TimeInterval, trackDuration: TimeInterval?) -> TimeInterval {
        guard playbackTime.isFinite,
              let trackDuration = trackDuration,
              trackDuration.isFinite,
              trackDuration > 0 else {
            return 1
        }
        let wrapCheckTime = trackDuration + PlaybackState.lyricsRepeatWrapGracePeriod
        guard wrapCheckTime > playbackTime else {
            return 1
        }
        return min(1, wrapCheckTime - playbackTime)
    }

    func writeToiTunes(overwrite: Bool) {
        guard selectedPlayer.name == .appleMusic,
              let currentLyrics = currentLyrics,
              let sbTrack = selectedPlayer.currentTrack?.originalTrack,
              overwrite || (sbTrack.value(forKey: "lyrics") as! String?)?.isEmpty != false else {
            return
        }

        let content: String
        if defaults[.writeiTunesConvertToPlainLRC] {
            // For plain LRC export, preserve the legacy LRC formatting but still respect
            // the Chinese conversion setting for consistency with the non-plain branch.
            var legacy = currentLyrics.legacyDescription
            if let converter = ChineseConverter.shared {
                legacy = converter.convert(legacy)
            }
            // Note: translations are intentionally not appended for plain LRC export,
            // even when `writeiTunesWithTranslation` is enabled, to keep the legacy
            // LRC output single-line per timestamp.
            content = legacy
        } else {
            content = currentLyrics.lines.map { line -> String in
                var content = line.content
                if let converter = ChineseConverter.shared {
                    content = converter.convert(content)
                }
                if defaults[.writeiTunesWithTranslation] {
                    // TODO: tagged translation
                    let code = currentLyrics.metadata.translationLanguages.first
                    if var translation = line.attachments[.translation(languageCode: code)] {
                        if let converter = ChineseConverter.shared {
                            translation = converter.convert(translation)
                        }
                        content += "\n" + translation
                    }
                }
                return content
            }.joined(separator: "\n")
        }
        // swiftlint:disable:next force_try
        let regex = Regex(#"\n{3,}"#)
        let replaced = content.replacingMatches(of: regex, with: "\n\n")
        sbTrack.setValue(replaced, forKey: "lyrics")
    }

    func currentTrackChanged() {
        if currentLyrics?.metadata.needsPersist == true {
            currentLyrics?.persist()
        }
        currentLyrics = nil
        currentLineIndex = nil
        searchTask?.cancel()
        guard let track = selectedPlayer.currentTrack else {
            Task { await ArtworkSimilarityScorer.shared.updateNowPlaying(image: nil, trackId: nil) }
            return
        }
        let nowPlayingImage = track.artwork
        let nowPlayingId = track.id
        Task { await ArtworkSimilarityScorer.shared.updateNowPlaying(image: nowPlayingImage, trackId: nowPlayingId) }
        // FIXME: deal with optional value
        let title = track.title ?? ""
        let artist = track.artist ?? ""

        guard !defaults[.noSearchingTrackIds].contains(track.id) else {
            return
        }

        var candidateLyricsURL: [(URL, Bool, Bool)] = [] // (fileURL, isSecurityScoped, needsSearching)

        if defaults[.loadLyricsBesideTrack] {
            if let embeddedLyrics = track.lyrics, !embeddedLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let lyrics = Lyrics(embeddedLyrics) {
                    if lyrics.metadata.title == nil || lyrics.metadata.title?.isEmpty == true {
                        lyrics.metadata.title = title
                    }
                    if lyrics.metadata.artist == nil || lyrics.metadata.artist?.isEmpty == true {
                        lyrics.metadata.artist = artist
                    }
                    lyrics.applyQQMusicKanaFurigana()
                    lyrics.filtrate()
                    lyrics.recognizeLanguage()
                    currentLyrics = lyrics
                    return
                }
            }
            if let fileName = track.localFileURL?.deletingPathExtension() {
                candidateLyricsURL += [
                    (fileName.appendingPathExtension("lrcx"), false, false),
                    (fileName.appendingPathExtension("lrc"), false, false),
                ]
            }
        }

        let (url, security) = defaults.lyricsSavingPath()
        let titleForReading = title.replacingOccurrences(of: "/", with: ":")
        let artistForReading = artist.replacingOccurrences(of: "/", with: ":")
        let fileName = url.appendingPathComponent("\(titleForReading) - \(artistForReading)")
        candidateLyricsURL += [
            (fileName.appendingPathExtension("lrcx"), security, false),
            (fileName.appendingPathExtension("lrc"), security, true),
        ]

        for (url, security, needsSearching) in candidateLyricsURL {
            if security {
                guard url.startAccessingSecurityScopedResource() else {
                    continue
                }
            }
            defer {
                if security {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            if let lrcContents = try? String(contentsOf: url, encoding: String.Encoding.utf8),
               let lyrics = Lyrics(lrcContents) {
                lyrics.metadata.localURL = url
                lyrics.metadata.title = title
                lyrics.metadata.artist = artist
                lyrics.applyQQMusicKanaFurigana()
                lyrics.filtrate()
                lyrics.recognizeLanguage()
                currentLyrics = lyrics
                if needsSearching {
                    break
                } else {
                    return
                }
            }
        }

        if let album = track.album, defaults[.noSearchingAlbumNames].contains(album) {
            return
        }

        let duration = track.duration ?? 0
        // Strip bracketed suffixes ("(feat. X)", "[Explicit]", "(Remix)", "【现场版】" …)
        // from the search title when the preference is on; providers usually return
        // zero matches for the bracketed form. The full title still drives local
        // cache lookup above and the lyrics metadata association below.
        let searchTitle = defaults[.stripSearchTitleBracketsEnabled] ? title.strippingBrackets : title
        let request = LyricsSearchRequest(searchTerm: .info(title: searchTitle, artist: artist), duration: duration, limit: 5, userInfo: [:])
        searchRequest = request
        searchTask = Task { @MainActor in
            do {
                // Accept the first arrived lyrics immediately,
                // but keep collecting for a short window to allow higher-priority providers,
                // which might be slower, to replace it.
                let window = defaults[.lyricsPriorityWindow] ?? 5 // seconds
                var firstReceived = false
                var collectionStart: Date?

                for try await lyrics in lyricsManager.lyrics(for: request) {
                    if !firstReceived {
                        lyricsReceived(lyrics: lyrics)
                        if let current = currentLyrics, current === lyrics {
                            firstReceived = true
                            collectionStart = Date()
                        }
                        continue
                    }

                    // Route B name-recovery results are slower than the direct
                    // providers by design, so they are exempt from the priority
                    // window — otherwise they would always arrive too late.
                    let lyricsIsRecovered = lyrics.isFromSearchPlugin
                    let withinWindow = collectionStart.map { Date().timeIntervalSince($0) <= window } ?? false

                    if withinWindow || lyricsIsRecovered {
                        lyricsReceived(lyrics: lyrics)
                    }
                    // Past the window and not a recovery result: drop it (no
                    // late swap from the direct providers), but keep draining
                    // the stream so the Route B plugin runs to completion
                    // instead of being torn down — and cancelled — mid-request.
                }

                if defaults[.writeToiTunesAutomatically] {
                    writeToiTunes(overwrite: true)
                }
            } catch is CancellationError {
                // Search was cancelled due to track change
            } catch {
                print("Failed to fetch lyrics: \(error.localizedDescription)")
            }
        }
    }

    // MARK: LyricsSourceDelegate

    func lyricsReceived(lyrics: Lyrics) {
        // Match by session id, not request equality: Route B's plugin
        // expands one search into several requests with different search
        // terms but the same session id, and all of them belong here.
        guard let req = searchRequest,
              lyrics.metadata.request?.id == req.id,
              let track = selectedPlayer.currentTrack else {
            return
        }
        if defaults[.strictSearchEnabled], !lyrics.isMatched() {
            return
        }
        // Route B re-searches with the recovered native-script name; those
        // results supersede the original localized-name search outright. A
        // recovered lyric always replaces a localized one, and a localized
        // lyric is never allowed to replace a recovered one — within the
        // same tier the usual quality/source priority decides.
        let lyricsIsRecovered = lyrics.isFromSearchPlugin
        if let current = currentLyrics {
            if lyricsIsRecovered != current.isFromSearchPlugin {
                guard lyricsIsRecovered else {
                    return
                }
            } else if !lyricsHasHigherPriority(lyrics, over: current) {
                return
            }
        }

        lyrics.associateWithTrack(track)
        lyrics.applyQQMusicKanaFurigana()
        lyrics.filtrate()
        lyrics.recognizeLanguage()
        lyrics.metadata.needsPersist = true
        currentLyrics = lyrics
        scheduleArtworkScoring(for: lyrics, against: track)
    }

    private func scheduleArtworkScoring(for lyrics: Lyrics, against track: MusicTrack) {
        guard defaults[.artworkSimilarityBoostEnabled],
              let url = lyrics.metadata.artworkURL else { return }
        let scoredTrackId = track.id
        Task { [weak self] in
            let matched = await ArtworkSimilarityScorer.shared.matches(artworkURL: url)
            guard matched, let self else { return }
            await self.applyArtworkBonus(to: lyrics, scoredTrackId: scoredTrackId)
        }
    }

    @MainActor
    private func applyArtworkBonus(to lyrics: Lyrics, scoredTrackId: String) {
        // Drop the bonus if the user has already moved on to another song —
        // the score was computed against a now-stale artwork.
        guard selectedPlayer.currentTrack?.id == scoredTrackId else { return }
        lyrics.artworkMatchBonus = ArtworkSimilarityScorer.matchBonus
        // The lyrics may now outrank the current selection. Re-run the swap
        // check; lyricsReceived's own guards (request id, recovered/non-
        // recovered tier, strict match) still apply.
        if let current = currentLyrics, current !== lyrics,
           lyricsHasHigherPriority(lyrics, over: current) {
            currentLyrics = lyrics
        }
    }

    // MARK: Widget Data Bridge

    /// Persist the current snapshot and ask WidgetKit to rebuild the timeline.
    /// Use when the timeline structure must change: track switch, lyrics
    /// (re)load, play/pause toggle, or seek.
    ///
    /// Pass `playbackState` when responding to a `playbackStateWillChange`
    /// emission so the snapshot uses the new value directly, instead of
    /// re-reading `selectedPlayer.playbackState` (which can still hold the
    /// pre-change value during the willSet phase).
    func reloadWidgetTimeline(playbackState: PlaybackState? = nil) {
        guard #available(macOS 14, *) else { return }
        writeWidgetSnapshot(playbackState: playbackState, reloadOnSuccess: true)
    }

    /// Persist the current snapshot without rebuilding the timeline.
    /// Use on lyric-line transitions: pre-generated future entries already
    /// drive the line change in the widget process, so a reload would only
    /// add WidgetKit scheduling latency. We still refresh the dataStore so
    /// on-demand reads (placeholder, configuration UI) stay accurate.
    func updateWidgetSnapshot() {
        guard #available(macOS 14, *) else { return }
        writeWidgetSnapshot(playbackState: nil, reloadOnSuccess: false)
    }

    private func writeWidgetSnapshot(playbackState explicitPlaybackState: PlaybackState?, reloadOnSuccess: Bool) {
        // let usedExplicit = explicitPlaybackState != nil
        guard let track = selectedPlayer.currentTrack else {
            // #log(.info, "[LXWG][Write] no current track → clearing dataStore + reloading timelines (reloadOnSuccess=\(reloadOnSuccess, privacy: .public), usedExplicit=\(usedExplicit, privacy: .public))")
            widgetDataStore.clear()
            WidgetCenter.shared.reloadAllTimelines()
            return
        }

        let playbackState = explicitPlaybackState ?? selectedPlayer.playbackState
        let playbackTime = playbackState.time
        // #log(.info, "[LXWG][Write] enter (track=\(track.title ?? "nil", privacy: .public), isPlaying=\(playbackState.isPlaying, privacy: .public), time=\(playbackTime, privacy: .public), usedExplicit=\(usedExplicit, privacy: .public), reloadOnSuccess=\(reloadOnSuccess, privacy: .public))")

        // Build lyrics lines with context window
        var lyricsLines: [LyricsLineEntry] = []
        var widgetCurrentLineIndex = 0
        var availableTranslationLanguages: [String] = []

        if let lyrics = currentLyrics {
            availableTranslationLanguages = lyrics.metadata.translationLanguages
            let enabledLines = lyrics.lines.enumerated().filter { $0.element.enabled }
            let contextRadius = 50
            let (currentIndex, _) = lyrics[playbackTime + lyrics.adjustedTimeDelay]

            // Find the position of currentIndex in enabledLines
            let enabledCurrentPosition = enabledLines.firstIndex { $0.offset == currentIndex } ?? 0

            let startPosition = max(0, enabledCurrentPosition - contextRadius)
            let endPosition = min(enabledLines.count - 1, enabledCurrentPosition + contextRadius)

            if startPosition <= endPosition {
                let windowSlice = enabledLines[startPosition ... endPosition]
                lyricsLines = windowSlice.enumerated().map { windowIndex, indexedLine in
                    let line = indexedLine.element
                    let nextPosition = line.position // startTime
                    // Calculate endTime from the next enabled line
                    let sliceArray = Array(windowSlice)
                    let endTime: TimeInterval? = (windowIndex + 1 < sliceArray.count)
                        ? sliceArray[windowIndex + 1].element.position
                        : nil

                    // Collect translations for all available languages
                    let firstTranslationLanguage = availableTranslationLanguages.first
                    let translation = firstTranslationLanguage.flatMap {
                        line.attachments[.translation(languageCode: $0)]
                    }

                    return LyricsLineEntry(
                        text: line.content,
                        translation: translation,
                        startTime: nextPosition,
                        endTime: endTime
                    )
                }
                widgetCurrentLineIndex = enabledCurrentPosition - startPosition
            }
        }

        // Extract artwork color and cover data
        var backgroundColor: CodableColor?
        if let artwork = track.resolvedArtwork {
            backgroundColor = AlbumColorExtractor.dominantColor(from: artwork)
            if let coverData = AlbumColorExtractor.compressedCoverData(from: artwork) {
                try? widgetDataStore.writeCover(coverData)
            }
        } else {
            widgetDataStore.clearCover()
        }

        // Align widget's time axis with the main app's lyrics time axis.
        // The main app uses `playbackTime + adjustedTimeDelay` everywhere
        // (currentLineIndex computation, karaoke progress, HUD), where
        // adjustedTimeDelay folds in the lyrics file's [offset:] tag plus
        // the user's global offset preference. The widget's
        // LyricsLineEntry.startTime is the raw LRC position, so we have to
        // offset playbackPosition the same way — otherwise the widget
        // permanently lags the main app by adjustedTimeDelay seconds (up
        // to ~1s for files that ship a non-zero offset tag).
        let lyricsTimeDelay = currentLyrics?.adjustedTimeDelay ?? 0
        let widgetData = LyricsWidgetData(
            trackTitle: track.title ?? "Unknown",
            artist: track.artist ?? "Unknown",
            albumName: track.album,
            backgroundColor: backgroundColor,
            lyricsLines: lyricsLines,
            currentLineIndex: widgetCurrentLineIndex,
            isPlaying: playbackState.isPlaying,
            timestamp: Date(),
            playbackPosition: playbackTime + lyricsTimeDelay,
            availableTranslationLanguages: availableTranslationLanguages
        )

        do {
            try widgetDataStore.write(widgetData)
            // #log(.info, "[LXWG][Write] wrote snapshot (isPlaying=\(widgetData.isPlaying, privacy: .public), playbackPosition=\(widgetData.playbackPosition, privacy: .public), lineIndex=\(widgetData.currentLineIndex, privacy: .public), lyricsLines=\(widgetData.lyricsLines.count, privacy: .public), reloadOnSuccess=\(reloadOnSuccess, privacy: .public))")
        } catch {
            // #log(.error, "[LXWG][Write] dataStore.write failed: \(error.localizedDescription, privacy: .public)")
        }
        if reloadOnSuccess {
            // #log(.info, "[LXWG][Write] reloadAllTimelines()")
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}

extension AppController {
    func importLyrics(_ lyricsString: String) throws {
        guard let lrc = Lyrics(lyricsString) else {
            let errorInfo = [
                NSLocalizedDescriptionKey: "Invalid lyric file",
                NSLocalizedRecoverySuggestionErrorKey: "Please try another one.",
            ]
            let error = NSError(domain: lyricsXErrorDomain, code: 0, userInfo: errorInfo)
            throw error
        }
        guard let track = selectedPlayer.currentTrack else {
            let errorInfo = [
                NSLocalizedDescriptionKey: "No music playing",
                NSLocalizedRecoverySuggestionErrorKey: "Play a music and try again.",
            ]
            let error = NSError(domain: lyricsXErrorDomain, code: 0, userInfo: errorInfo)
            throw error
        }
        lrc.metadata.title = track.title
        lrc.metadata.artist = track.artist
        lrc.applyQQMusicKanaFurigana()
        lrc.filtrate()
        lrc.recognizeLanguage()
        lrc.metadata.needsPersist = true
        currentLyrics = lrc
        if let index = defaults[.noSearchingTrackIds].firstIndex(of: track.id) {
            defaults[.noSearchingTrackIds].remove(at: index)
        }
        if let index = defaults[.noSearchingAlbumNames].firstIndex(of: track.album ?? "") {
            defaults[.noSearchingAlbumNames].remove(at: index)
        }
    }
}
