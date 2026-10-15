import AppKit
import Combine
import Regex
import OpenCC
import MusicPlayer
import LyricsXFoundation
import WidgetKit
import LyricsXWidgetShared

/// What a "switch to the next lyrics candidate" request ended up doing.
enum LyricsCandidateSwitchOutcome {
    /// Moved onto another candidate. `position` is 1-based, for display.
    case switched(position: Int, total: Int, service: String?)
    /// The pool held nothing to switch to — the usual state for a track whose
    /// lyrics came from the local cache, which never runs a search — so one is
    /// running now to fill it.
    case searching
    /// That search finished without turning up anything other than what is
    /// already on screen.
    case exhausted
    /// Nothing is playing.
    case unavailable
}

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

    /// Every candidate the current track's search produced, ordered by the same
    /// relation the manual search panel sorts its list by. The display logic in
    /// `lyricsReceived` picks the top of it on its own; `advanceToNextLyricsCandidate`
    /// walks it by hand when that pick was wrong.
    private(set) var lyricsCandidatePool = PriorityOrderedCandidatePool<Lyrics>(hasHigherPriority: lyricsHasHigherPriority)

    /// The track the pool was filled for. A search that outlives a track change
    /// would otherwise drop its results into the next track's pool.
    private var candidatePoolTrackId: String?

    /// Set once the user picks a candidate by hand. While pinned, arriving
    /// results still enter the pool but never replace `currentLyrics` —
    /// otherwise a late high-priority result would yank the screen straight
    /// back off the user's pick.
    private var candidateSelectionIsPinned = false

    private var candidateReplenishTask: Task<Void, Never>?

    /// What a "next candidate" request ended up doing. Published rather than
    /// returned because the replenish path resolves asynchronously, and both
    /// paths should reach the same one piece of UI.
    let lyricsCandidateSwitchOutcomes = PassthroughSubject<LyricsCandidateSwitchOutcome, Never>()

    private var previousPlaybackState: PlaybackState?

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
        // Ignore artwork-only changes, but restart when incomplete metadata
        // is filled in. An exact-song task must not keep a stale identity.
        selectedPlayer.currentTrackWillChange
            .removeDuplicates(by: { previous, current in
                if let previous, let current {
                    return previous.hasSameLyricsLookupIdentity(as: current)
                }
                return previous == nil && current == nil
            })
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
            Task { @MainActor in await self?.updateLyricsManager() }
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

        Task { await updateLyricsManager() }
    }

    @MainActor
    func updateLyricsManager() async {
        let musixmatchToken = defaults[.musixmatchToken].flatMap { $0.isEmpty ? nil : $0 }
        var providers: [LyricsProvider] = [
            LyricsProviders.Service.netease.create(),
            LyricsProviders.Service.qq.create(),
            LyricsProviders.Service.kugou.create(),
            LyricsProviders.Service.lrclib.create(),
            LyricsProviders.Service.musixmatch.create(.init(usertoken: musixmatchToken)),
        ]
        // Route A: official Apple Music syllable-lyrics via amp-api. Only
        // registered when the user supplied a `media-user-token` AND the
        // provider can actually reach amp-api with it (`isAuthorized` hits
        // `/v1/me/storefront` once, cached per-instance) — without that,
        // every fetch would 401 and pollute the result stream.
        if #available(macOS 12.0, *),
           let token = defaults[.appleMusicMediaUserToken],
           !token.isEmpty {
            let appleMusicProvider = LyricsProviders.Service.appleMusic.create(
                .init(
                    mediaUserToken: token,
                    storefrontOverride: defaults[.appleMusicStorefront].flatMap { $0.isEmpty ? nil : $0 },
                    languageOverride: defaults[.appleMusicLanguage].flatMap { $0.isEmpty ? nil : $0 }
                )
            )
            if await appleMusicProvider.isAuthorized {
                providers.append(appleMusicProvider)
            }
        }
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
        let shouldPreserveCurrentLine = currentLyrics != nil &&
            currentLineIndex != nil &&
            selectedPlayer.currentTrack != nil &&
            LyricsPlaybackPositionPolicy.shouldPreserveCurrentLine(
                previousState: previousPlaybackState,
                newState: playbackState
            )
        previousPlaybackState = playbackState

        // The zero-time pause publish carries no usable anchor, so there is
        // nothing to reschedule against: drop the pending timer and leave
        // `currentLineIndex` where it is until a state with a real time
        // arrives.
        if shouldPreserveCurrentLine {
            currentLineCheckSchedule?.cancel()
            currentLineCheckSchedule = nil
            return
        }
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
        resetLyricsCandidatePool()
        guard let track = selectedPlayer.currentTrack else {
            Task { await ArtworkSimilarityScorer.shared.updateNowPlaying(image: nil, trackId: nil) }
            return
        }
        candidatePoolTrackId = track.id
        let nowPlayingImage = track.artwork
        let nowPlayingId = track.id
        Task { await ArtworkSimilarityScorer.shared.updateNowPlaying(image: nowPlayingImage, trackId: nowPlayingId) }
        // FIXME: deal with optional value
        let title = track.title ?? ""
        let artist = track.artist ?? ""

        guard !defaults[.noSearchingTrackIds].contains(track.id) else {
            return
        }

        // A candidate the user switched to by hand outranks every automatic
        // lookup below — including lyrics embedded in the audio file and lyrics
        // sitting beside it, either of which would otherwise win on order alone
        // and silently undo the choice.
        if let overrideURL = userSelectedLyricsURL(forTrackId: track.id),
           let lyrics = loadLyrics(
               at: overrideURL,
               securityScopedURL: defaults.lyricsSecurityScopedDirectory(containing: overrideURL),
               title: title,
               artist: artist
           ) {
            currentLyrics = lyrics
            adoptAsSoleLyricsCandidate(lyrics)
            return
        }

        if NetEaseClientTrackResolver.isNetEase(clientIdentity(for: track)) || QQMusicClientTrackResolver.isQQMusic(clientIdentity(for: track)) {
            startClientLyrics(for: track)
            return
        }

        var candidateLyricsFiles: [LyricsLookupCandidateFile] = []

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
                    adoptAsSoleLyricsCandidate(lyrics)
                    return
                }
            }
            if let besideTrackBaseURL = track.localFileURL?.deletingPathExtension() {
                candidateLyricsFiles += [
                    LyricsLookupCandidateFile(
                        fileURL: besideTrackBaseURL.appendingPathExtension("lrcx"),
                        isSecurityScoped: false,
                        allowsFurtherSearching: false,
                        isLibraryFile: false
                    ),
                    LyricsLookupCandidateFile(
                        fileURL: besideTrackBaseURL.appendingPathExtension("lrc"),
                        isSecurityScoped: false,
                        allowsFurtherSearching: false,
                        isLibraryFile: false
                    ),
                ]
            }
        }

        // The library is the only layer the "ignore saved lyrics" switch covers:
        // everything above is either the user's own file or the user's own
        // choice, and neither is a cache to be bypassed. It is read even when
        // the switch is on, because the file itself says whether the switch
        // applies to it — and that can only be seen after reading it.
        candidateLyricsFiles += librarySearchFiles(title: title, artist: artist)

        for candidateFile in candidateLyricsFiles {
            if let lyrics = loadLyrics(
                at: candidateFile.fileURL,
                securityScopedURL: candidateFile.isSecurityScoped ? candidateFile.fileURL : nil,
                title: title,
                artist: artist
            ) {
                // The switch means "do not trust what LyricsX saved for itself".
                // Lyrics the user applied by hand were never LyricsX's own
                // decision, so they stay in play.
                if candidateFile.isLibraryFile,
                   defaults[.ignoreCachedLyricsLibrary],
                   !lyrics.isUserPicked {
                    continue
                }
                currentLyrics = lyrics
                adoptAsSoleLyricsCandidate(lyrics)
                if candidateFile.allowsFurtherSearching {
                    break
                } else {
                    return
                }
            }
        }

        if let album = track.album, defaults[.noSearchingAlbumNames].contains(album) {
            return
        }

        startPublicLyricsSearch(for: track)
    }

    /// The same configured public-source search serves normal playback and
    /// fallback from a client's exact lookup. It never carries an exact token.
    private func startPublicLyricsSearch(for track: MusicTrack) {
        guard let current = selectedPlayer.currentTrack,
              current.hasSameLyricsLookupIdentity(as: track),
              !defaults[.noSearchingTrackIds].contains(track.id),
              !defaults[.noSearchingAlbumNames].contains(track.album ?? "") else { return }
        let title = track.title ?? ""
        let artist = track.artist ?? ""
        let identity = clientIdentity(for: track)
        let titleOnly = NetEaseClientTrackResolver.isNetEase(identity) || QQMusicClientTrackResolver.isQQMusic(identity)
        let request = makeLyricsSearchRequest(for: track, titleOnly: titleOnly)
        searchRequest = request
        log("Public lyrics lookup: \(title) / \(artist); duration=\(track.duration ?? 0)")
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

                    // Past the window and not a recovery result: it may no
                    // longer take the screen (no late swap from the direct
                    // providers), but it is still a candidate the user can
                    // switch onto by hand — so it goes through the normal path
                    // and into the pool, just flagged as ineligible to display.
                    lyrics.arrivedAfterPriorityWindow = !(withinWindow || lyricsIsRecovered)
                    lyricsReceived(lyrics: lyrics)
                }

                loadLibraryLyricsIfSearchFoundNothing(for: track, title: title, artist: artist)

                if defaults[.writeToiTunesAutomatically] {
                    writeToiTunes(overwrite: true)
                }
            } catch is CancellationError {
                // Search was cancelled due to track change
            } catch {
                print("Failed to fetch lyrics: \(error.localizedDescription)")
                // The case the fallback exists for: every provider failed, which
                // offline is the normal outcome rather than the exception.
                loadLibraryLyricsIfSearchFoundNothing(for: track, title: title, artist: artist)
            }
        }
    }

    /// One file an automatic lookup may read, and what reading it implies.
    private struct LyricsLookupCandidateFile {
        let fileURL: URL
        let isSecurityScoped: Bool
        /// A plain `.lrc` is displayed but does not end the lookup: it carries
        /// none of the LRCX extras, so a search still runs to try to better it.
        let allowsFurtherSearching: Bool
        /// A file from LyricsX's own library, which the bypass switch may reject
        /// once it has been read and found to carry no user-pick mark.
        let isLibraryFile: Bool
    }

    /// The saved-lyrics library, in lookup order: every spelling of the name as
    /// LRCX first, then every spelling as plain LRC.
    ///
    /// Both spellings, because `persist()` writes the canonical (trimmed) name
    /// while libraries from older releases carry an untrimmed one. Reading only
    /// the legacy spelling leaves a file this very session just saved
    /// unreachable whenever the metadata has surrounding whitespace — harmless
    /// while a cache hit merely saved a search, but not once the search-fallback
    /// path below depends on reading back what was written. For metadata
    /// without surrounding whitespace the two spellings coincide and this
    /// returns exactly the two files it always did.
    private func librarySearchFiles(title: String, artist: String) -> [LyricsLookupCandidateFile] {
        let (directoryURL, isSecurityScoped) = defaults.lyricsSavingPath()
        let baseURLs = LyricsStoragePolicy
            .libraryFileBaseNameCandidates(title: title, artist: artist)
            .map { directoryURL.appendingPathComponent($0) }
        return baseURLs.map {
            LyricsLookupCandidateFile(
                fileURL: $0.appendingPathExtension("lrcx"),
                isSecurityScoped: isSecurityScoped,
                allowsFurtherSearching: false,
                isLibraryFile: true
            )
        } + baseURLs.map {
            LyricsLookupCandidateFile(
                fileURL: $0.appendingPathExtension("lrc"),
                isSecurityScoped: isSecurityScoped,
                allowsFurtherSearching: true,
                isLibraryFile: true
            )
        }
    }

    /// Reads the library that `ignoreCachedLyricsLibrary` told the lookup to
    /// skip — but only when the search came back empty-handed. Without this,
    /// "always fetch fresh" would degrade into "no lyrics at all" whenever the
    /// network is down, which is plainly worse than a possibly stale file.
    private func loadLibraryLyricsIfSearchFoundNothing(for track: MusicTrack, title: String, artist: String) {
        guard defaults[.ignoreCachedLyricsLibrary],
              currentLyrics == nil,
              // The search may well have outlived the track it was started for.
              selectedPlayer.currentTrack?.id == track.id else {
            return
        }
        for candidateFile in librarySearchFiles(title: title, artist: artist) {
            if let lyrics = loadLyrics(
                at: candidateFile.fileURL,
                securityScopedURL: candidateFile.isSecurityScoped ? candidateFile.fileURL : nil,
                title: title,
                artist: artist
            ) {
                let identity = clientIdentity(for: track)
                if NetEaseClientTrackResolver.isNetEase(identity) || QQMusicClientTrackResolver.isQQMusic(identity) {
                    guard lyrics.isReliableClientFallbackMatch(for: makeLyricsSearchRequest(for: track)) else { continue }
                }
                currentLyrics = lyrics
                adoptAsSoleLyricsCandidate(lyrics)
                return
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
        let identity = clientIdentity(for: track)
        if NetEaseClientTrackResolver.isNetEase(identity) || QQMusicClientTrackResolver.isQQMusic(identity) {
            guard lyrics.isReliableClientFallbackMatch(for: makeLyricsSearchRequest(for: track)) else {
                log("Client fallback rejected mismatched lyrics: \(lyrics.idTags[.title] ?? "missing title") / \(lyrics.idTags[.artist] ?? "missing artist")")
                return
            }
        }
        if defaults[.strictSearchEnabled], !lyrics.isMatched() {
            return
        }

        lyrics.associateWithTrack(track)
        lyrics.applyQQMusicKanaFurigana()
        lyrics.filtrate()
        lyrics.recognizeLanguage()
        lyrics.metadata.needsPersist = true

        // Entering the pool is unconditional: losing the display contest says
        // nothing about whether the user might want this candidate. Only the
        // decision below — whether it goes on screen — weighs priority.
        guard insertIntoLyricsCandidatePool(lyrics, for: track) else {
            return
        }
        scheduleArtworkScoring(for: lyrics, against: track)

        guard LyricsDisplayEligibilityPolicy.shouldReplaceDisplayed(
            selectionIsPinned: candidateSelectionIsPinned,
            candidateArrivedAfterPriorityWindow: lyrics.arrivedAfterPriorityWindow,
            displayedIsRecovered: currentLyrics?.isFromSearchPlugin,
            candidateIsRecovered: lyrics.isFromSearchPlugin,
            candidateOutranksDisplayed: currentLyrics.map { lyricsHasHigherPriority(lyrics, over: $0) } ?? true
        ) else {
            return
        }

        currentLyrics = lyrics
        lyricsCandidatePool.selectCandidate(identicalTo: lyrics)
    }

    // MARK: Lyrics Candidates

    private func resetLyricsCandidatePool() {
        candidateReplenishTask?.cancel()
        candidateReplenishTask = nil
        lyricsCandidatePool.removeAll()
        candidateSelectionIsPinned = false
        candidatePoolTrackId = nil
    }

    /// Makes `lyrics` the pool's only member, as the local-cache paths do —
    /// they return before any search runs, so this one file is all there is
    /// until a replenish search fills in the rest.
    private func adoptAsSoleLyricsCandidate(_ lyrics: Lyrics) {
        lyricsCandidatePool.replaceAll(with: [lyrics], selecting: lyrics)
    }

    /// Returns whether `lyrics` was taken into the pool. Rejects results that
    /// belong to another track, and duplicates of a candidate already held —
    /// different services routinely return the very same words, and switching
    /// onto an identical copy reads as the shortcut being broken.
    @discardableResult
    private func insertIntoLyricsCandidatePool(_ lyrics: Lyrics, for track: MusicTrack) -> Bool {
        guard candidatePoolTrackId == track.id else {
            return false
        }
        let fingerprint = lyricsContentFingerprint(lyrics)
        guard !lyricsCandidatePool.contains(where: { lyricsContentFingerprint($0) == fingerprint }) else {
            return false
        }
        lyricsCandidatePool.insert(lyrics)
        return true
    }

    /// Timed line content, which is what actually distinguishes one candidate
    /// from another. Metadata is deliberately left out: the same words fetched
    /// from two services differ in their tags but not in what the user reads.
    private func lyricsContentFingerprint(_ lyrics: Lyrics) -> String {
        lyrics.lines.map { "\($0.position)|\($0.content)" }.joined(separator: "\n")
    }

    /// Moves onto the next candidate for the current track, wrapping around at
    /// the end. Reports what happened through `lyricsCandidateSwitchOutcomes`.
    ///
    /// Left non-isolated to match the rest of this type: `currentLyrics` and
    /// friends are already reached from both `DispatchQueue.lyricsDisplay`
    /// (track changes) and the main queue (search results, user actions).
    func advanceToNextLyricsCandidate() {
        guard let track = selectedPlayer.currentTrack else {
            lyricsCandidateSwitchOutcomes.send(.unavailable)
            return
        }
        guard lyricsCandidatePool.count >= 2, let nextCandidate = lyricsCandidatePool.advanceSelection() else {
            startCandidateReplenishSearch(for: track)
            return
        }
        applyUserPickedCandidate(nextCandidate, for: track)
        lyricsCandidateSwitchOutcomes.send(.switched(
            position: (lyricsCandidatePool.selectedIndex ?? 0) + 1,
            total: lyricsCandidatePool.count,
            service: nextCandidate.metadata.service
        ))
    }

    private func clientIdentity(for track: MusicTrack) -> ClientPlaybackIdentity {
        ClientPlaybackIdentity(
            sourceBundleIdentifier: (track.originalTrack as? NSDictionary)?["bundleIdentifier"] as? String,
            title: track.title, album: track.album, artist: track.artist, duration: track.duration
        )
    }

    /// The client record is authoritative. Polling also detects distinct song
    /// IDs whose system Now Playing metadata is identical, without relying on
    /// MusicTrack's title-derived ID to announce every edition change.
    private func startClientLyrics(for track: MusicTrack) {
        let identity = clientIdentity(for: track)
        searchTask = Task { @MainActor [weak self] in
            let isQQ = QQMusicClientTrackResolver.isQQMusic(identity)
            let provider = (isQQ ? LyricsProviders.Service.qq : .netease).create()
            let exactKey = isQQ ? QQMusicClientTrackResolver.exactSongKey : NetEaseClientTrackResolver.exactSongKey
            let sourceName = isQQ ? "QQMusic" : "NetEase"
            var missingSince: Date?
            var attemptedSong: String?
            var verifiedLyrics: Lyrics?
            while !Task.isCancelled {
                guard let self, let currentTrack = selectedPlayer.currentTrack,
                      self.clientIdentity(for: currentTrack) == identity else { return }
                let song = await Task.detached(priority: .utility) {
                    isQQ ? QQMusicClientTrackResolver.currentSong(matching: identity) : NetEaseClientTrackResolver.currentSong(matching: identity)
                }.value
                guard !Task.isCancelled, let currentTrack = selectedPlayer.currentTrack,
                      self.clientIdentity(for: currentTrack) == identity else { return }
                if let song {
                    missingSince = nil
                    if song != attemptedSong {
                        if self.currentLyrics?.metadata.needsPersist == true { self.currentLyrics?.persist() }
                        self.currentLyrics = nil
                        self.resetLyricsCandidatePool()
                        self.candidatePoolTrackId = track.id
                        attemptedSong = song
                        verifiedLyrics = nil
                        let request = LyricsSearchRequest(
                            searchTerm: .info(title: identity.title ?? "", artist: identity.artist ?? ""),
                            duration: identity.duration ?? 0, limit: 1,
                            userInfo: [exactKey: song]
                        )
                        self.searchRequest = request
                        do {
                            for try await lyrics in provider.lyrics(for: request) {
                                guard !Task.isCancelled,
                                      let current = selectedPlayer.currentTrack,
                                      self.clientIdentity(for: current) == identity else { return }
                                // A delayed response must not attach to the next
                                // song, including two songs with identical names.
                                let confirmed = await Task.detached(priority: .utility) {
                                    isQQ ? QQMusicClientTrackResolver.currentSong(matching: identity) : NetEaseClientTrackResolver.currentSong(matching: identity)
                                }.value
                                guard !Task.isCancelled, confirmed == song,
                                      let current = selectedPlayer.currentTrack,
                                      self.clientIdentity(for: current) == identity else { break }
                                lyrics.associateWithTrack(current)
                                lyrics.applyQQMusicKanaFurigana()
                                lyrics.filtrate()
                                lyrics.recognizeLanguage()
                                lyrics.metadata.needsPersist = true
                                self.currentLyrics = lyrics
                                self.adoptAsSoleLyricsCandidate(lyrics)
                                verifiedLyrics = lyrics
                                log("\(sourceName) exact client song ID=\(lyrics.metadata.serviceToken ?? "unknown"); title search bypassed")
                            }
                        } catch is CancellationError {
                            return
                        } catch {
                            log("\(sourceName) exact lyrics unavailable: \(error.localizedDescription)")
                        }
                        if verifiedLyrics == nil {
                            let latestSong = await Task.detached(priority: .utility) {
                                isQQ ? QQMusicClientTrackResolver.currentSong(matching: identity) : NetEaseClientTrackResolver.currentSong(matching: identity)
                            }.value
                            if let latestSong, latestSong != song {
                                attemptedSong = nil
                                continue
                            }
                            guard let current = selectedPlayer.currentTrack,
                                  self.clientIdentity(for: current) == identity, !Task.isCancelled else { return }
                            log("\(sourceName) exact lookup failed or returned no lyrics; searching public sources")
                            self.resetLyricsCandidatePool()
                            self.candidatePoolTrackId = current.id
                            self.startPublicLyricsSearch(for: current)
                            return
                        }
                    } else if self.currentLyrics == nil, let verifiedLyrics {
                        self.currentLyrics = verifiedLyrics
                        self.adoptAsSoleLyricsCandidate(verifiedLyrics)
                    }
                } else {
                    // The client can briefly lag Now Playing during a switch.
                    // Allow a short grace period before public-source fallback.
                    if self.currentLyrics?.metadata.needsPersist == true { self.currentLyrics?.persist() }
                    self.currentLyrics = nil
                    if missingSince == nil { missingSince = Date() }
                    if Date().timeIntervalSince(missingSince!) >= 3 {
                        guard let current = selectedPlayer.currentTrack,
                              self.clientIdentity(for: current) == identity, !Task.isCancelled else { return }
                        log("\(sourceName) client record unavailable; searching public sources")
                        self.resetLyricsCandidatePool()
                        self.candidatePoolTrackId = current.id
                        self.startPublicLyricsSearch(for: current)
                        return
                    }
                }
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
        }
    }

    /// The pool holds at most what is already on screen. That is the normal
    /// state for a track served from the local cache — that path returns before
    /// any search runs — so run one now to have something to switch to.
    private func startCandidateReplenishSearch(for track: MusicTrack) {
        guard candidateReplenishTask == nil else {
            lyricsCandidateSwitchOutcomes.send(.searching)
            return
        }
        candidatePoolTrackId = track.id
        let onScreenLyrics = currentLyrics
        if let onScreenLyrics, !lyricsCandidatePool.contains(where: { $0 === onScreenLyrics }) {
            lyricsCandidatePool.insert(onScreenLyrics)
            lyricsCandidatePool.selectCandidate(identicalTo: onScreenLyrics)
        }
        let onScreenFingerprint = onScreenLyrics.map(lyricsContentFingerprint)
        let identity = clientIdentity(for: track)
        let titleOnly = NetEaseClientTrackResolver.isNetEase(identity) || QQMusicClientTrackResolver.isQQMusic(identity)
        let request = makeLyricsSearchRequest(for: track, titleOnly: titleOnly)
        searchRequest = request
        lyricsCandidateSwitchOutcomes.send(.searching)

        candidateReplenishTask = Task { @MainActor in
            defer { candidateReplenishTask = nil }
            var hasSwitched = false
            do {
                for try await lyrics in lyricsManager.lyrics(for: request) {
                    lyricsReceived(lyrics: lyrics)
                    guard !hasSwitched,
                          selectedPlayer.currentTrack?.id == track.id,
                          let firstDifferentCandidate = lyricsCandidatePool.candidates.first(where: {
                              lyricsContentFingerprint($0) != onScreenFingerprint
                          }) else {
                        continue
                    }
                    // Switch on the first genuinely different candidate rather
                    // than waiting for the stream to drain: a full search can
                    // run for tens of seconds, and a keystroke with nothing
                    // visible happening reads as a dead shortcut.
                    hasSwitched = true
                    applyUserPickedCandidate(firstDifferentCandidate, for: track)
                    lyricsCandidateSwitchOutcomes.send(.switched(
                        position: (lyricsCandidatePool.selectedIndex ?? 0) + 1,
                        total: lyricsCandidatePool.count,
                        service: firstDifferentCandidate.metadata.service
                    ))
                }
            } catch is CancellationError {
                return
            } catch {
                log("Failed to fetch replenish candidates: \(error.localizedDescription)")
            }
            if !hasSwitched {
                lyricsCandidateSwitchOutcomes.send(.exhausted)
            }
        }
    }

    /// Puts a hand-picked candidate on screen and makes it stick: pinned
    /// against later arrivals, written to disk, and recorded so the next play
    /// of this track resolves to it too.
    private func applyUserPickedCandidate(_ lyrics: Lyrics, for track: MusicTrack) {
        candidateSelectionIsPinned = true
        lyricsCandidatePool.selectCandidate(identicalTo: lyrics)
        lyrics.associateWithTrack(track)
        lyrics.markAsUserPicked(origin: .nextCandidate)
        lyrics.metadata.needsPersist = true
        currentLyrics = lyrics

        // Picking a candidate by hand contradicts any earlier "wrong lyrics"
        // verdict on this track, exactly as choosing one in the search panel does.
        if let index = defaults[.noSearchingTrackIds].firstIndex(of: track.id) {
            defaults[.noSearchingTrackIds].remove(at: index)
        }

        if lyrics.persist() {
            recordUserSelectionIfAutomaticLookupWouldOverrideIt(lyrics, for: track)
        }
        if defaults[.writeToiTunesAutomatically] {
            writeToiTunes(overwrite: true)
        }
    }

    /// Adopts a list the user already sorted through — the manual search panel's
    /// results — so the shortcut carries on from what they picked there.
    func adoptLyricsCandidates(_ candidates: [Lyrics], selecting selectedCandidate: Lyrics, for track: MusicTrack) {
        candidatePoolTrackId = track.id
        lyricsCandidatePool.replaceAll(with: candidates, selecting: selectedCandidate)
        candidateSelectionIsPinned = true
    }

    private func userSelectedLyricsURL(forTrackId trackId: String) -> URL? {
        LyricsSelectionOverrideTable
            .filePath(forTrackId: trackId, in: defaults[.lyricsSelectionOverrides])
            .map { URL(fileURLWithPath: $0) }
    }

    /// Records the pick only when the automatic lookup order would otherwise
    /// beat it — an embedded or beside-track file is consulted first, so
    /// without this the choice would last exactly one play.
    private func recordUserSelectionIfAutomaticLookupWouldOverrideIt(_ lyrics: Lyrics, for track: MusicTrack) {
        guard let persistedURL = lyrics.metadata.localURL else {
            return
        }
        guard defaults[.loadLyricsBesideTrack], automaticLookupPrecedes(persistedURL, for: track) else {
            // Nothing is consulted ahead of the file just written, so the plain
            // lookup order already resolves to it.
            defaults[.lyricsSelectionOverrides] = LyricsSelectionOverrideTable.removing(
                trackId: track.id,
                from: defaults[.lyricsSelectionOverrides]
            )
            return
        }
        defaults[.lyricsSelectionOverrides] = LyricsSelectionOverrideTable.recording(
            filePath: persistedURL.path,
            forTrackId: track.id,
            in: defaults[.lyricsSelectionOverrides],
            at: Date()
        )
    }

    private func automaticLookupPrecedes(_ persistedURL: URL, for track: MusicTrack) -> Bool {
        if let embeddedLyrics = track.lyrics,
           !embeddedLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        guard let besideTrackBaseURL = track.localFileURL?.deletingPathExtension() else {
            return false
        }
        let besideTrackURLs = [
            besideTrackBaseURL.appendingPathExtension("lrcx"),
            besideTrackBaseURL.appendingPathExtension("lrc"),
        ]
        guard !besideTrackURLs.contains(persistedURL) else {
            return false
        }
        return besideTrackURLs.contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func loadLyrics(at fileURL: URL, securityScopedURL: URL?, title: String, artist: String) -> Lyrics? {
        if let securityScopedURL {
            guard securityScopedURL.startAccessingSecurityScopedResource() else {
                return nil
            }
        }
        defer {
            securityScopedURL?.stopAccessingSecurityScopedResource()
        }
        guard let fileContents = try? String(contentsOf: fileURL, encoding: String.Encoding.utf8),
              let lyrics = Lyrics(fileContents) else {
            return nil
        }
        lyrics.metadata.localURL = fileURL
        lyrics.metadata.title = title
        lyrics.metadata.artist = artist
        lyrics.applyQQMusicKanaFurigana()
        lyrics.filtrate()
        lyrics.recognizeLanguage()
        return lyrics
    }

    private func makeLyricsSearchRequest(for track: MusicTrack, titleOnly: Bool = false) -> LyricsSearchRequest {
        let title = track.title ?? ""
        let artist = track.artist ?? ""
        // Strip bracketed suffixes ("(feat. X)", "[Explicit]", "(Remix)", "【现场版】" …)
        // from the search title when the preference is on; providers usually return
        // zero matches for the bracketed form. The full title still drives local
        // cache lookup and the lyrics metadata association.
        let searchTitle = defaults[.stripSearchTitleBracketsEnabled] ? title.strippingBrackets : title
        return LyricsSearchRequest(
            searchTerm: .info(title: searchTitle, artist: titleOnly ? "" : artist),
            duration: track.duration ?? 0,
            limit: 5,
            userInfo: [:]
        )
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
        // The bonus changed this candidate's rank, so the pool has to be
        // re-sorted; the selection stays on whatever object it was pointing at.
        lyricsCandidatePool.resort()
        // The user picked a candidate by hand; a score change must not move it.
        guard !candidateSelectionIsPinned else { return }
        // A bonus landing later cannot resurrect a result that already missed
        // the priority window — otherwise late arrivals would take the screen
        // through the artwork path that they are denied through the normal one.
        guard !lyrics.arrivedAfterPriorityWindow else { return }
        // The lyrics may now outrank the current selection. Re-run the swap
        // check; lyricsReceived's own guards (request id, recovered/non-
        // recovered tier, strict match) still apply.
        if let current = currentLyrics, current !== lyrics,
           lyricsHasHigherPriority(lyrics, over: current) {
            currentLyrics = lyrics
            lyricsCandidatePool.selectCandidate(identicalTo: lyrics)
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
    func importLyrics(_ lyricsString: String, filePath: String? = nil) throws {
        // Pick the parser by file extension first (drag-and-drop of a `.ttml`
        // file). For pasted text without a path, auto-detect by root element.
        let isTTML: Bool = {
            if let filePath {
                return (filePath as NSString).pathExtension.lowercased() == "ttml"
            }
            return lyricsString.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<tt")
        }()
        let parsed: Lyrics? = isTTML ? Lyrics(ttmlContent: lyricsString) : Lyrics(lyricsString)
        guard let lrc = parsed else {
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
        lrc.markAsUserPicked(origin: .import)
        lrc.metadata.needsPersist = true
        currentLyrics = lrc
        // An imported file is as deliberate a choice as picking a candidate, so
        // it takes over the pool and is pinned against a search still in flight.
        adoptLyricsCandidates([lrc], selecting: lrc, for: track)
        if let index = defaults[.noSearchingTrackIds].firstIndex(of: track.id) {
            defaults[.noSearchingTrackIds].remove(at: index)
        }
        if let index = defaults[.noSearchingAlbumNames].firstIndex(of: track.album ?? "") {
            defaults[.noSearchingAlbumNames].remove(at: index)
        }
    }
}
