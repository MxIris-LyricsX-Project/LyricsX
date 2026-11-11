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
    /// The online pool held nothing to switch to — the usual state for a track
    /// whose lyrics came from a local source, which does not run a search — so
    /// one is running now to fill it.
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

    @Published private(set) var currentLocalLyricsSource: LocalLyricsSource?

    var lyricsManager: LyricsProvider
    // A slow scripting-bridge read for one track must not hold up the quick
    // adjacent-file check for the next track.
    private let localLyricsRefreshQueue = DispatchQueue(
        label: "LocalLyricsRefresh", qos: .userInitiated, attributes: .concurrent
    )
    // Selection state and displayed lyrics are confined to lyricsDisplay.
    private var localLyricsSelectionID = UUID()
    // A translation replaces the object without changing the user's selection.
    private var lyricsSelectionID = UUID()
    private var isApplyingTranslation = false
    private let musicIOQueue: DispatchQueue
    private let localLyricsCatalog: LocalLyricsCatalog
    private let localLyricsCoordinator: LocalLyricsCoordinator
    let localLyricsChanges = PassthroughSubject<LocalLyricsChange, Never>()

    @Published var currentLyrics: Lyrics? {
        willSet {
            #if DEBUG
            dispatchPrecondition(condition: .onQueue(.lyricsDisplay))
            #endif
            if !isApplyingTranslation {
                localLyricsSelectionID = UUID()
                lyricsSelectionID = UUID()
                if newValue !== currentLyrics {
                    currentLocalLyricsSource = nil
                }
            }
            willChangeValue(forKey: "lyricsOffset")
            currentLineIndex = nil
        }
        didSet {
            didChangeValue(forKey: "lyricsOffset")
            scheduleCurrentLineCheck()
            DispatchQueue.lyricsDisplay.async { [weak self] in
                guard let self else { return }
                self.startLyricsTranslation(for: self.currentLyrics)
            }
        }
    }

    @Published var currentLineIndex: Int?

    var searchRequest: LyricsSearchRequest?
    var searchTask: Task<Void, Never>?

    /// What `writeToiTunes` last put into Music, and into which track.
    /// Rejected lyrics come back out of Music only while it still holds
    /// LyricsX's own text, and by then the lyrics on screen may write something
    /// else — a translation arrived, the offset moved — so the comparison takes
    /// this write as well.
    private var lastLyricsWrittenToMusic: (trackIdentifier: String, content: String)?

    /// Every online candidate the current track's search produced, ordered by
    /// the same relation the manual search panel sorts its list by. Local
    /// embedded and file lyrics are kept in the Local Lyrics submenu instead.
    /// The display logic in `lyricsReceived` picks the top of this pool on its
    /// own; `advanceToNextLyricsCandidate` walks it by hand when that pick was
    /// wrong.
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
    private let aiLyricsTranslator = OpenAICompatibleLyricsTranslator()
    private var lyricsTranslationTask: Task<Void, Never>?
    private var lastLyricsTranslationKey: String?
    /// Whether, and until when, the automatic search may still put other
    /// lyrics on screen. An AI translation request waits for it, so nothing is
    /// paid for lyrics that a higher-priority result replaces seconds later.
    /// Confined to the lyrics display queue, like the two above.
    private var automaticLyricsReplacementWindow = AutomaticLyricsReplacementWindow()
    /// The translation put off until `automaticLyricsReplacementWindow` closes.
    private var deferredLyricsTranslationStart: DispatchWorkItem?

    /// The languages system translation found missing for the lyrics on
    /// screen: lines in them stay untranslated until they are downloaded, and
    /// the Lab pane offers to download them. Nil when nothing waits on a
    /// download. Set on the lyrics display queue.
    @Published private(set) var systemTranslationLanguagePairToDownload: SystemTranslationLanguagePair?
    /// Invalidates a replenish task even when its provider does not promptly
    /// observe Task cancellation. Results from an older generation must never
    /// change the current track or replace a later local selection.
    private var candidateReplenishID = UUID()

    private struct UserPickedCandidateCommit {
        let position: Int
        let total: Int
        let service: String?
    }

    /// What a "next candidate" request ended up doing. Published rather than
    /// returned because the replenish path resolves asynchronously, and both
    /// paths should reach the same one piece of UI.
    let lyricsCandidateSwitchOutcomes = PassthroughSubject<LyricsCandidateSwitchOutcome, Never>()

    private var previousPlaybackState: PlaybackState?

    private var cancelBag = Set<AnyCancellable>()

    private let widgetDataStore = WidgetDataStore(groupIdentifier: lyricsXGroupIdentifier)

    private lazy var widgetReloadCoordinator = WidgetReloadCoordinator { [unowned self] playbackState in
        writeWidgetSnapshot(playbackState: playbackState)
    }

    /// Set as the app quits, once the widget's snapshot is cleared, so nothing
    /// writes it back. Read and written on `DispatchQueue.lyricsDisplay`.
    private var widgetSnapshotIsRetired = false

    @objc dynamic var lyricsOffset: Int {
        get {
            performOnLyricsDisplayQueue { currentLyrics?.offset ?? 0 }
        }
        set {
            performOnLyricsDisplayQueue {
                currentLyrics?.offset = newValue
                currentLyrics?.metadata.needsPersist = true
                scheduleCurrentLineCheck()
            }
        }
    }

    private override init() {
        self.lyricsManager = LyricsProviders.Group()
        let musicQueue = DispatchQueue(label: "MusicLyricsIO", qos: .userInitiated)
        self.musicIOQueue = musicQueue
        let localLyricsCoordinator = LocalLyricsCoordinator(
            embeddedTitle: NSLocalizedString("Embedded Lyrics", comment: "Local lyrics menu option"),
            lyricsXTitle: "LyricsX",
            readMetadata: { track, verified, reportLocation in
                musicQueue.sync {
                    // The catalog skips providers for non-scripting tracks.
                    // Verified writes also work without an advertised optional selector.
                    let location = track.lyricsLocationRead
                    reportLocation(location)
                    let original = track.originalTrack
                    let text = verified || original?.responds(to: Selector(("lyrics"))) == true
                        ? original?.value(forKey: "lyrics") as? String : nil
                    return LocalLyricsState.Metadata(embeddedText: text, location: location)
                }
            },
            securityDirectory: { defaults.lyricsSecurityScopedDirectory(containing: $0) }
        )
        self.localLyricsCoordinator = localLyricsCoordinator
        self.localLyricsCatalog = localLyricsCoordinator.catalog
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
        // Lyrics, track and playback state changes alter the timeline
        // structure, so they rebuild it — but through WidgetReloadCoordinator,
        // not one reload each. WidgetKit runs one app-requested reload every
        // five seconds and holds the rest, and a track change alone is a
        // burst of changes; WidgetReloadPolicy has the rules and the reasons.
        // A plain pause or resume goes out at once. A playback report the next
        // ones may still correct waits for playback to settle: one at either
        // end of a track, or one that does not carry on from the last report,
        // like the stale position that resuming through the SystemMedia/
        // mediaremote-adapter backend reports first, which this bridge used to
        // debounce on its own.
        //
        // Line index change is handled separately and only refreshes the
        // dataStore — the timeline already contains future entries that
        // drive the next line transition autonomously, so a reload here
        // would only add WidgetKit scheduling latency (~hundreds of ms,
        // the visible "widget lyrics lag" before this change).
        $currentLyrics
            .map { $0 != nil }
            .sink { [weak self] hasLyrics in
                self?.widgetReloadCoordinator.note(.lyricsChanged(hasLyrics: hasLyrics))
            }
            .store(in: &cancelBag)

        selectedPlayer.playbackStateWillChange
            .sink { [weak self] playbackState in
                self?.widgetReloadCoordinator.notePlaybackState(
                    isPlaying: playbackState.isPlaying,
                    position: playbackState.time,
                    trackDuration: selectedPlayer.currentTrack?.duration
                )
            }
            .store(in: &cancelBag)

        // The widgets have no settings of their own: they show translations
        // when the app does, in the language the app shows them in, so they
        // all share one configuration and every reload reaches all of them at
        // once.
        defaults.publisher(for: [.preferBilingualLyrics, .preferredLyricsTranslationLanguage])
            .signal()
            .sink { [weak self] in
                self?.widgetReloadCoordinator.note(.displaySettingsChanged)
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

        defaults.publisher(for: [
            .lyricsTranslationEngine,
            .aiLyricsTranslationEnabled,
            .aiLyricsTranslationEndpoint,
            .aiLyricsTranslationModel,
            .lyricsTranslationTargetLanguage,
            .aiLyricsTranslationPrompt,
        ])
        .signal()
        .receive(on: DispatchQueue.lyricsDisplay)
        .sink { [weak self] in
            guard let self = self else { return }
            lastLyricsTranslationKey = nil
            startLyricsTranslation(for: currentLyrics)
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
        let request = performOnLyricsDisplayQueue { () -> (MusicTrack, String, UUID, LocalLyricsState.Session)? in
            guard selectedPlayer.name == .appleMusic, let lyrics = currentLyrics,
                  let track = selectedPlayer.currentTrack, track.originalTrack != nil,
                  let session = localLyricsCatalog.captureSession(for: track.id) else { return nil }
            return (track, musicLyricsContent(for: lyrics), lyricsSelectionID, session)
        }
        guard let (track, content, selectionID, session) = request, let scriptingTrack = track.originalTrack else { return }
        musicIOQueue.async {
            var token: LocalLyricsState.WriteToken?
            let result = MusicLyricsOperation.write(
                content, overwrite: overwrite,
                read: { scriptingTrack.value(forKey: "lyrics") as? String },
                beforeWrite: {
                    performOnLyricsDisplayQueue {
                        guard selectedPlayer.currentTrack?.id == track.id, self.lyricsSelectionID == selectionID,
                              self.localLyricsCatalog.isActive(session) else { return false }
                        token = self.localLyricsCatalog.beginWrite(session: session)
                        return token != nil
                    }
                },
                write: { text in
                    scriptingTrack.setValue(text, forKey: "lyrics")
                    performOnLyricsDisplayQueue { self.lastLyricsWrittenToMusic = (track.id, text) }
                }
            )
            guard let token else { return }
            guard self.localLyricsCatalog.finishWrite(result.verifiedText, token: token) else { return }
            self.publishLocalLyricsChange(for: track.id, change: result.verifiedText == nil ? .embeddedRefreshRequired : .embedded)
        }
    }

    func removeRejectedLyricsFromMusic(of track: MusicTrack) {
        let request = performOnLyricsDisplayQueue { () -> ([String], LocalLyricsState.Session)? in
            guard selectedPlayer.name == .appleMusic,
                  let session = localLyricsCatalog.captureSession(for: track.id) else { return nil }
            var contents: [String] = []
            if let last = lastLyricsWrittenToMusic, last.trackIdentifier == track.id { contents.append(last.content) }
            if let currentLyrics { contents.append(musicLyricsContent(for: currentLyrics)) }
            return (contents, session)
        }
        guard let (writtenContents, session) = request else { return }
        musicIOQueue.async {
            guard LyricsStoragePolicy.clearsLyricsInMusicWhenRejected(
                lyricsInMusic: track.lyrics, contentsLyricsXWrote: writtenContents
            ) else { return }
            // The captured rejection still applies if playback moved on while
            // Music was busy; only current-session menu state needs a token.
            guard let token = self.localLyricsCatalog.beginWrite(session: session, access: .verification) else { return }
            track.setLyrics("")
            let readBack = track.originalTrack?.value(forKey: "lyrics") as? String
            let verified = LyricsStoragePolicy.lyricsInMusicMatchesWrittenContent(readBack, written: "") ? "" : nil
            guard self.localLyricsCatalog.finishWrite(verified, token: token) else { return }
            self.publishLocalLyricsChange(for: track.id, change: verified == nil ? .embeddedRefreshRequired : .embedded)
        }
    }

    /// Stops both searches that may still be running for the current track,
    /// for the actions that reject the lyrics on screen. Left running, the
    /// automatic search puts its next result back on screen and, when it
    /// ends, writes it into Music; the next-candidate search applies what it
    /// finds as the user's own pick, which takes the track off the rejected
    /// list.
    func cancelLyricsSearches() {
        performOnLyricsDisplayQueue {
            searchTask?.cancel()
            searchTask = nil
            searchRequest = nil
            cancelCandidateReplenishSearch()
        }
    }

    /// The text `writeToiTunes` puts into Music for `lyrics` under the current
    /// preferences.
    private func musicLyricsContent(for lyrics: Lyrics) -> String {
        let content: String
        if defaults[.writeiTunesConvertToPlainLRC] {
            // For plain LRC export, preserve the legacy LRC formatting but still respect
            // the Chinese conversion setting for consistency with the non-plain branch.
            var legacy = lyrics.legacyDescription
            if let converter = ChineseConverter.shared {
                legacy = converter.convert(legacy)
            }
            // Note: translations are intentionally not appended for plain LRC export,
            // even when `writeiTunesWithTranslation` is enabled, to keep the legacy
            // LRC output single-line per timestamp.
            content = legacy
        } else {
            content = lyrics.lines.map { line -> String in
                var content = line.content
                if let converter = ChineseConverter.shared {
                    content = converter.convert(content)
                }
                if defaults[.writeiTunesWithTranslation] {
                    // TODO: tagged translation
                    if var translation = lyrics.displayTranslation(for: line) {
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
        return content.replacingMatches(of: regex, with: "\n\n")
    }

    private func currentTrackChanged() {
        performOnLyricsDisplayQueue { handleCurrentTrackChange() }
    }

    private func handleCurrentTrackChange() {
        // Ahead of clearing the lyrics below, so the widget knows to wait for
        // the new track's.
        widgetReloadCoordinator.note(.trackChanged)
        cancelLyricsTranslation()
        automaticLyricsReplacementWindow.reset()
        persistCurrentLyrics()
        searchTask?.cancel()
        searchTask = nil
        searchRequest = nil
        resetLyricsCandidatePool()
        let track = selectedPlayer.currentTrack
        let session = localLyricsCoordinator.activate(track?.id)
        currentLyrics = nil
        currentLineIndex = nil
        let selectionID = localLyricsSelectionID
        guard let track, let session else {
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

        if let imported = localLyricsCoordinator.takeDeferredImport(for: session) {
            applyImportedLyrics(imported, for: track, session: session)
            return
        }
        guard !defaults[.noSearchingTrackIds].contains(track.id) else {
            return
        }

        localLyricsRefreshQueue.async {
            guard self.isCurrentTrackLookup(track, selectionID: selectionID) else { return }
            // Disk reads and player metadata both stay off the display queue.
            if let overrideURL = self.userSelectedLyricsURL(forTrackId: track.id),
               let lyrics = self.loadLyrics(at: overrideURL, title: title, artist: artist) {
                let source: LocalLyricsSource = self.isLyricsXManagedFile(overrideURL) ? .lyricsX : .file(overrideURL)
                self.commitTrackLookupLyrics(lyrics, source: source, for: track, selectionID: selectionID)
                return
            }
            let loadsBesideTrack = defaults[.loadLyricsBesideTrack]
            let metadata = loadsBesideTrack ? self.localLyricsCatalog.metadata(for: track, read: .coalesced, session: session) : nil
            self.continueTrackLookup(track, embeddedLyrics: metadata?.embeddedText, musicFileURL: metadata?.fileURL, selectionID: selectionID)
        }
    }

    private func isCurrentTrackLookup(_ track: MusicTrack, selectionID: UUID) -> Bool {
        performOnLyricsDisplayQueue {
            selectedPlayer.currentTrack?.id == track.id
                && localLyricsSelectionID == selectionID
        }
    }

    @discardableResult
    private func commitTrackLookupLyrics(
        _ lyrics: Lyrics,
        source: LocalLyricsSource,
        for track: MusicTrack,
        selectionID: UUID
    ) -> UUID? {
        performOnLyricsDisplayQueue {
            guard selectedPlayer.currentTrack?.id == track.id,
                  localLyricsSelectionID == selectionID else {
                return nil
            }
            currentLyrics = lyrics
            currentLocalLyricsSource = source
            return localLyricsSelectionID
        }
    }

    private func continueTrackLookup(
        _ track: MusicTrack,
        embeddedLyrics: String?,
        musicFileURL: URL?,
        selectionID: UUID
    ) {
        var selectionID = selectionID
        guard isCurrentTrackLookup(track, selectionID: selectionID) else { return }
        let title = track.title ?? ""
        let artist = track.artist ?? ""
        var candidateLyricsFiles: [LyricsLookupCandidateFile] = []

        if defaults[.loadLyricsBesideTrack] {
            if let embeddedLyrics, !embeddedLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let lyrics = Lyrics(embeddedLyrics) {
                    prepareEmbeddedLyrics(lyrics, title: title, artist: artist)
                    commitTrackLookupLyrics(lyrics, source: .embedded, for: track, selectionID: selectionID)
                    return
                }
            }
            if let besideTrackBaseURL = musicFileURL?.deletingPathExtension() {
                candidateLyricsFiles += [
                    LyricsLookupCandidateFile(
                        fileURL: besideTrackBaseURL.appendingPathExtension("lrcx"),
                        allowsFurtherSearching: false,
                        isLibraryFile: false
                    ),
                    LyricsLookupCandidateFile(
                        fileURL: besideTrackBaseURL.appendingPathExtension("lrc"),
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
                let source: LocalLyricsSource = candidateFile.isLibraryFile ? .lyricsX : .file(candidateFile.fileURL)
                guard let committedSelectionID = commitTrackLookupLyrics(
                    lyrics,
                    source: source,
                    for: track,
                    selectionID: selectionID
                ) else {
                    return
                }
                if candidateFile.allowsFurtherSearching {
                    selectionID = committedSelectionID
                    break
                } else {
                    return
                }
            }
        }

        if let album = track.album, defaults[.noSearchingAlbumNames].contains(album) {
            return
        }

        performOnLyricsDisplayQueue {
            guard selectedPlayer.currentTrack?.id == track.id, localLyricsSelectionID == selectionID else { return }
            let request = makeLyricsSearchRequest(for: track)
            automaticLyricsReplacementWindow.searchStarted(identifier: request.id, isAutomatic: true)
            lastLyricsTranslationKey = nil
            startLyricsTranslation(for: currentLyrics)
            searchRequest = request
            searchTask = Task { @MainActor in
                await runLyricsSearch(request, for: track, title: title, artist: artist)
            }
        }
    }

    @MainActor
    private func runLyricsSearch(
        _ request: LyricsSearchRequest,
        for track: MusicTrack,
        title: String,
        artist: String
    ) async {
        defer { automaticSearchEnded(request) }
        do {
            // Accept the first arrived lyrics immediately,
            // but keep collecting for a short window to allow higher-priority providers,
            // which might be slower, to replace it.
            let window = defaults[.lyricsPriorityWindow] ?? 5 // seconds
            var firstReceived = false
            var collectionStart: Date?

            let completion = try await LyricsSearchCompletion.consume(lyricsManager.lyrics(for: request)) { lyrics in
                if !firstReceived {
                    automaticSearchShowedFirstResult(request, closingAt: Date().addingTimeInterval(window))
                    lyricsReceived(lyrics: lyrics)
                    let displayedLyrics = performOnLyricsDisplayQueue { currentLyrics }
                    if let current = displayedLyrics, current === lyrics {
                        firstReceived = true
                        collectionStart = Date()
                    }
                    return
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

            guard completion == .finished else { return }
            guard performOnLyricsDisplayQueue({
                searchRequest == request && selectedPlayer.currentTrack?.id == track.id
            }) else {
                return
            }
            await loadLibraryLyricsIfSearchFoundNothing(
                for: track,
                title: title,
                artist: artist,
                expectedSearchRequest: request
            )

            guard !Task.isCancelled, performOnLyricsDisplayQueue({
                searchRequest == request && selectedPlayer.currentTrack?.id == track.id
            }) else { return }
            if defaults[.writeToiTunesAutomatically] { writeToiTunes(overwrite: true) }
        } catch is CancellationError {
            // Search was cancelled due to track change
        } catch {
            #log(.error, "Failed to fetch lyrics: \(error.localizedDescription, privacy: .public)")
            guard !Task.isCancelled else { return }
            // The case the fallback exists for: every provider failed, which
            // offline is the normal outcome rather than the exception.
            guard performOnLyricsDisplayQueue({
                searchRequest == request && selectedPlayer.currentTrack?.id == track.id
            }) else {
                return
            }
            await loadLibraryLyricsIfSearchFoundNothing(
                for: track,
                title: title,
                artist: artist,
                expectedSearchRequest: request
            )
        }
    }

    /// The automatic search `request` has put its first result on screen, and
    /// better ones may replace it until `closingDate`. Asks again whether to
    /// translate the lyrics on screen.
    @MainActor
    private func automaticSearchShowedFirstResult(_ request: LyricsSearchRequest, closingAt closingDate: Date) {
        performOnLyricsDisplayQueue {
            automaticLyricsReplacementWindow.firstResultShown(bySearch: request.id, closingAt: closingDate)
            startLyricsTranslation(for: currentLyrics)
        }
    }

    /// The automatic search `request` has ended, so nothing it returns can
    /// replace the lyrics on screen any more, and a translation still waiting
    /// for it goes ahead.
    @MainActor
    private func automaticSearchEnded(_ request: LyricsSearchRequest) {
        performOnLyricsDisplayQueue {
            automaticLyricsReplacementWindow.searchEnded(identifier: request.id)
            startLyricsTranslation(for: currentLyrics)
        }
    }

    /// What one translation run is asked to do, read from the preferences.
    /// Two equal requests translate the same lyrics the same way.
    private enum LyricsTranslationRequest: Equatable {
        case ai(AILyricsTranslationConfiguration)
        case system(targetLanguage: String)

        var targetLanguage: String {
            switch self {
            case .ai(let configuration):
                return configuration.targetLanguage
            case .system(let targetLanguage):
                return targetLanguage
            }
        }

        /// The part of a run's key that is not the lyrics: everything that
        /// changes what the run would produce, or where it would send them.
        var settingsKey: String {
            switch self {
            case .ai(let configuration):
                return [
                    "ai",
                    configuration.endpoint.absoluteString,
                    configuration.model,
                    configuration.targetLanguage,
                    configuration.prompt,
                ].joined(separator: "|")
            case .system(let targetLanguage):
                return ["system", targetLanguage].joined(separator: "|")
            }
        }
    }

    /// What one run produced, from either engine, ready to apply.
    private struct LyricsTranslationOutcome {
        /// Line index → translation, including those read back from a saved copy.
        let translations: [Int: String]
        let failedLineCount: Int
        let failure: Error?
        /// System translation only: the languages the lyrics need that this
        /// Mac has not downloaded, which kept their lines untranslated.
        var languagePairToDownload: SystemTranslationLanguagePair?
    }

    /// The run the preferences ask for: nil while translation is off, and an
    /// error when the chosen engine's settings cannot be used.
    private func lyricsTranslationRequest() throws -> LyricsTranslationRequest? {
        let targetLanguage = defaults.resolvedLyricsTranslationTargetLanguage
        switch defaults.lyricsTranslationEngine {
        case .off:
            return nil
        case .ai:
            return .ai(try AILyricsTranslationPolicy.configuration(
                endpoint: defaults[.aiLyricsTranslationEndpoint],
                model: defaults[.aiLyricsTranslationModel],
                targetLanguage: targetLanguage,
                // Passed raw: `configuration(...)` resolves it, so an untouched
                // prompt still reaches the endpoint as the current default.
                prompt: defaults[.aiLyricsTranslationPrompt]
            ))
        case .system:
            guard let targetLanguage = AILyricsTranslationPolicy.normalizedLanguageIdentifier(targetLanguage) else {
                throw AILyricsTranslationError.invalidTargetLanguage
            }
            return .system(targetLanguage: targetLanguage)
        }
    }

    /// The pane's status while a request is in flight, kept in one place so the
    /// "nothing to translate" path can tell a transient status apart from a
    /// finished one. A failure message is the only place some problems are ever
    /// reported, and blanking it on the next track change would lose it.
    private var lyricsTranslationInProgressStatus: String {
        NSLocalizedString(
            "Translating lyrics…",
            comment: "Status shown while AI lyric translation is in progress."
        )
    }

    /// Reports a translation that put nothing on screen, with what failed when
    /// that is known: the pane is the only place a rejected key, a wrong model
    /// name, a used-up request limit or a language still to download is ever
    /// reported.
    private func reportLyricsTranslationFailure(_ failure: Error?) {
        guard let failure else {
            defaults[.lyricsTranslationStatus] = NSLocalizedString(
                "Translation failed; existing lyrics were kept.",
                comment: "Status shown when AI lyric translation fails."
            )
            return
        }
        // Not failures of the run but of what this Mac has: the status says
        // what to do about it rather than that something went wrong.
        if let failure = failure as? SystemLyricsTranslationError {
            defaults[.lyricsTranslationStatus] = failure.statusDescription
            return
        }
        defaults[.lyricsTranslationStatus] = String(
            format: NSLocalizedString(
                "Translation failed; existing lyrics were kept. %@",
                comment: "Status shown when AI lyric translation fails; %@ says what failed, such as the HTTP status the endpoint answered."
            ),
            OpenAICompatibleLyricsTranslator.failureDescription(for: failure)
        )
    }

    /// Stops the translation in flight and the one put off for later, and
    /// forgets which lyrics were last sent, so the next call starts afresh.
    private func cancelLyricsTranslation() {
        lyricsTranslationTask?.cancel()
        lyricsTranslationTask = nil
        deferredLyricsTranslationStart?.cancel()
        deferredLyricsTranslationStart = nil
        lastLyricsTranslationKey = nil
        systemTranslationLanguagePairToDownload = nil
    }

    /// Asks `startLyricsTranslation` again at `deadline`, when the lyrics on
    /// screen are the ones that stay.
    private func deferLyricsTranslation(until deadline: Date) {
        let start = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            startLyricsTranslation(for: currentLyrics)
        }
        deferredLyricsTranslationStart = start
        DispatchQueue.lyricsDisplay.asyncAfter(
            deadline: .now() + max(deadline.timeIntervalSinceNow, 0),
            execute: start
        )
    }

    /// Reads the API key for `endpoint`, retrying a Keychain that is only
    /// briefly unavailable. Returns nil, with the reason in the Lab pane, when
    /// there is no key to use, and nil alone when the task is cancelled.
    private func aiLyricsTranslationAPIKey(for endpoint: URL) async -> String? {
        for attempt in 0 ..< 3 {
            do {
                let apiKey = try AILyricsTranslationCredentialStore.apiKey(for: endpoint)
                guard !Task.isCancelled else { return nil }
                if apiKey == nil {
                    defaults[.lyricsTranslationStatus] = NSLocalizedString(
                        "Add an API key in AI translation settings.",
                        comment: "Status shown when no API key is stored for AI lyric translation."
                    )
                }
                return apiKey
            } catch let error as AILyricsTranslationCredentialError where error.isTransient {
                guard attempt < 2 else {
                    guard !Task.isCancelled else { return nil }
                    defaults[.lyricsTranslationStatus] = NSLocalizedString(
                        "The keychain is temporarily unavailable; translation can be retried later.",
                        comment: "Status for a temporary Keychain failure during AI translation."
                    )
                    return nil
                }
                do {
                    try await Task.sleep(nanoseconds: UInt64(250_000_000 * (1 << attempt)))
                } catch {
                    return nil
                }
            } catch {
                guard !Task.isCancelled else { return nil }
                defaults[.lyricsTranslationStatus] = NSLocalizedString(
                    "The saved API key could not be read. Check its access in Keychain.",
                    comment: "Status for a permanent Keychain failure during AI translation."
                )
                return nil
            }
        }
        return nil
    }

    /// The translations into `targetLanguage` that the file `lyrics` persist
    /// to already holds for them, when that is not the file they were read
    /// from. Reads the file, so it runs off the lyrics display queue.
    private func savedTranslations(for lyrics: Lyrics, targetLanguage: String) -> [Int: String] {
        guard let destination = lyrics.persistDestination,
              destination.fileURL != lyrics.metadata.localURL else {
            return [:]
        }
        return (try? withSecurityScopedAccess(to: destination.securityScopedDirectoryURL) {
            guard let contents = try? String(contentsOf: destination.fileURL, encoding: .utf8),
                  let savedLyrics = Lyrics(contents) else {
                return [:]
            }
            return AILyricsTranslationPolicy.savedTranslations(
                in: savedLyrics,
                for: lyrics,
                targetLanguage: targetLanguage
            )
        }) ?? [:]
    }

    /// Runs `request`'s engine over the lines of `lyrics` that still need a
    /// translation once `savedTranslations` are in. Nil when the engine cannot
    /// run at all — no API key to send — with the reason already in the pane.
    private func translate(
        _ lyrics: Lyrics,
        savedTranslations: [Int: String],
        with request: LyricsTranslationRequest
    ) async throws -> LyricsTranslationOutcome? {
        let linesToRequest = AILyricsTranslationPolicy.translationInputLines(
            lyrics: lyrics,
            targetLanguage: request.targetLanguage
        )
        guard !linesToRequest.isEmpty else {
            return LyricsTranslationOutcome(translations: savedTranslations, failedLineCount: 0, failure: nil)
        }
        switch request {
        case .ai(let configuration):
            guard let apiKey = await aiLyricsTranslationAPIKey(for: configuration.endpoint) else {
                return nil
            }
            let result = try await aiLyricsTranslator.translate(
                lyrics: lyrics,
                configuration: configuration,
                apiKey: apiKey
            )
            return LyricsTranslationOutcome(
                translations: savedTranslations.merging(result.translations) { _, new in new },
                failedLineCount: result.failedLineCount,
                failure: result.failure
            )
        case .system(let targetLanguage):
            guard #available(macOS 26.0, *) else {
                // Unreachable: the engine reads as off before macOS 26.
                return nil
            }
            let result = try await SystemLyricsTranslator().translate(
                lyrics: lyrics,
                lyricsLanguage: lyrics.metadata.language,
                targetLanguage: targetLanguage
            )
            return LyricsTranslationOutcome(
                translations: savedTranslations.merging(result.translations) { _, new in new },
                failedLineCount: result.failedLineCount,
                failure: result.failure,
                languagePairToDownload: result.languagePairToDownload
            )
        }
    }

    private func startLyricsTranslation(for lyrics: Lyrics?) {
        guard defaults.lyricsTranslationEngine != .off else {
            // The Lab pane owns the wording while translation is off, so the
            // task is cancelled without rewriting the status.
            cancelLyricsTranslation()
            return
        }
        guard let lyrics, let track = selectedPlayer.currentTrack else {
            cancelLyricsTranslation()
            // Nothing is on screen to translate. Clear the in-progress line,
            // which would otherwise sit in the pane for the rest of the session
            // with no retry coming — but leave a finished message alone.
            if defaults[.lyricsTranslationStatus] == lyricsTranslationInProgressStatus {
                defaults[.lyricsTranslationStatus] = ""
            }
            return
        }

        let request: LyricsTranslationRequest
        do {
            guard let preferredRequest = try lyricsTranslationRequest() else {
                cancelLyricsTranslation()
                return
            }
            request = preferredRequest
        } catch {
            cancelLyricsTranslation()
            defaults[.lyricsTranslationStatus] = defaults.lyricsTranslationEngine == .ai
                ? NSLocalizedString(
                    "AI translation settings are incomplete or invalid.",
                    comment: "Status for AI lyric translation when its configuration is invalid."
                )
                : NSLocalizedString(
                    "The target language must be a language tag, such as zh-Hans or ja.",
                    comment: "Status for lyrics translation when the target language is not a valid language tag."
                )
            return
        }

        let sourceFingerprint = lyricsContentFingerprint(lyrics)
        let translationKey = [track.id, sourceFingerprint, request.settingsKey].joined(separator: "|")
        guard lastLyricsTranslationKey != translationKey else { return }
        lyricsTranslationTask?.cancel()
        lyricsTranslationTask = nil
        deferredLyricsTranslationStart?.cancel()
        deferredLyricsTranslationStart = nil
        systemTranslationLanguagePairToDownload = nil
        guard AILyricsTranslationPolicy.shouldTranslate(
            lyrics: lyrics,
            sourceLanguage: lyrics.metadata.language,
            targetLanguage: request.targetLanguage
        ) else {
            lastLyricsTranslationKey = translationKey
            defaults[.lyricsTranslationStatus] = NSLocalizedString(
                "No untranslated lines need this target language.",
                comment: "Status shown when lyrics are already in the AI translation target language."
            )
            return
        }
        defaults[.lyricsTranslationStatus] = lyricsTranslationInProgressStatus
        // Only AI translation waits for the search to have its say: it is the
        // one that costs money. System translation runs on this Mac in a
        // moment, and a result for lyrics replaced meanwhile is dropped by the
        // check below like any other that arrives too late.
        if case .ai = request {
            // The key stays unrecorded while this waits, so the next call goes
            // ahead.
            switch automaticLyricsReplacementWindow.translationStart(at: Date()) {
            case .now:
                break
            case .at(let closingDate):
                // The search may still replace these lyrics, so ask once it
                // no longer can.
                deferLyricsTranslation(until: closingDate)
                return
            case .afterTheSearchShowsAResult:
                // Asked again when the search shows its first result, or ends.
                return
            }
        }
        lastLyricsTranslationKey = translationKey

        let trackID = track.id
        // `Lyrics` is a reference type, and the display queue keeps mutating the
        // displayed instance while a request is in flight — the offset setter
        // writes `idTags[.offset]`, and picking a candidate swaps `lines` and
        // `metadata`. The task runs off this queue, so hand it a private copy
        // built here. The original stays the object of record: the identity
        // check below compares against it, and the translations are applied to
        // whatever it holds by the time the answer lands.
        let translationSource = Lyrics(
            lines: lyrics.lines,
            idTags: lyrics.idTags,
            metadata: lyrics.metadata
        )
        lyricsTranslationTask = Task { [weak self] in
            guard let self = self else { return }
            // What the file these lyrics persist to already holds is not
            // translated again — for lyrics embedded in the track, or read from
            // beside it without write-back, that file is a library copy the
            // lookup never reads back, so without this every play translated
            // anew, and AI translation paid for it each time.
            let savedTranslations = self.savedTranslations(
                for: translationSource,
                targetLanguage: request.targetLanguage
            )
            let requestSource = savedTranslations.isEmpty
                ? translationSource
                : (try? AILyricsTranslationPolicy.applying(
                    savedTranslations,
                    to: translationSource,
                    targetLanguage: request.targetLanguage
                )) ?? translationSource

            do {
                guard let outcome = try await self.translate(
                    requestSource,
                    savedTranslations: savedTranslations,
                    with: request
                ) else {
                    return
                }
                try Task.checkCancellation()
                performOnLyricsDisplayQueue { [weak self] in
                    guard let self = self,
                          selectedPlayer.currentTrack?.id == trackID,
                          // The preferences still ask for what was run: the
                          // same engine, with the same settings.
                          (try? lyricsTranslationRequest()) == request,
                          let displayedLyrics = currentLyrics,
                          displayedLyrics === lyrics,
                          lyricsContentFingerprint(displayedLyrics) == sourceFingerprint else {
                        return
                    }
                    systemTranslationLanguagePairToDownload = outcome.languagePairToDownload
                    // Nothing came back, so there is nothing to show or save:
                    // the lyrics on screen and in their file stay as they are.
                    guard !outcome.translations.isEmpty else {
                        if outcome.failedLineCount == 0 {
                            // Every line it would have sent turned out to be in
                            // the target language already.
                            defaults[.lyricsTranslationStatus] = NSLocalizedString(
                                "No untranslated lines need this target language.",
                                comment: "Status shown when lyrics are already in the AI translation target language."
                            )
                        } else {
                            reportLyricsTranslationFailure(outcome.failure)
                        }
                        return
                    }

                    // Applied to the lyrics on screen *now*, not to the copy the
                    // request started from: the user may have nudged the offset
                    // or flipped a line's switch while the request was in
                    // flight, and swapping in the older object would revert
                    // both — and `persist()` would then write the reverted
                    // offset back to the file.
                    let translatedLyrics: Lyrics
                    do {
                        translatedLyrics = try AILyricsTranslationPolicy.applying(
                            outcome.translations,
                            to: displayedLyrics,
                            targetLanguage: request.targetLanguage
                        )
                    } catch {
                        reportLyricsTranslationFailure(error)
                        return
                    }

                    translatedLyrics.metadata.needsPersist = true
                    // A copy, so the candidate pool still holds the original;
                    // `reconcileLyricsCandidatePoolWithScreen()` swaps it in
                    // there before the pool is next used.
                    guard commitTranslatedLyrics(translatedLyrics, replacing: displayedLyrics, for: trackID) else {
                        return
                    }
                    if let session = localLyricsCatalog.captureSession(for: trackID),
                       localLyricsCatalog.snapshot(for: session)?.managedLyrics === translatedLyrics {
                        publishLocalLyricsChange(for: trackID)
                    }
                    if translatedLyrics.persist() {
                        if let languagePairToDownload = outcome.languagePairToDownload {
                            // What the user can act on, ahead of a count of what
                            // the download would fix.
                            defaults[.lyricsTranslationStatus] = SystemLyricsTranslationError
                                .languagesNotDownloaded(languagePairToDownload)
                                .statusDescription
                        } else {
                            defaults[.lyricsTranslationStatus] = outcome.failedLineCount == 0
                                ? NSLocalizedString(
                                    "Lyrics translated.",
                                    comment: "Status shown when all eligible lyric lines were translated."
                                )
                                : String(
                                    format: NSLocalizedString(
                                        "Translated %d lines; %d lines could not be translated.",
                                        comment: "Status shown when AI lyric translation was partially successful."
                                    ),
                                    outcome.translations.count,
                                    outcome.failedLineCount
                                )
                        }
                    } else {
                        defaults[.lyricsTranslationStatus] = NSLocalizedString(
                            "Translations are displayed but could not be saved.",
                            comment: "Status shown when translated lyrics could not be persisted."
                        )
                    }
                }
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch {
                guard !Task.isCancelled else { return }
                reportLyricsTranslationFailure(error)
            }
        }
    }

    private func commitTranslatedLyrics(_ translated: Lyrics, replacing original: Lyrics, for trackID: String) -> Bool {
        performOnLyricsDisplayQueue {
            guard selectedPlayer.currentTrack?.id == trackID,
                  currentLyrics === original,
                  let session = localLyricsCatalog.captureSession(for: trackID) else { return false }
            isApplyingTranslation = true
            defer { isApplyingTranslation = false }
            currentLyrics = translated
            if currentLocalLyricsSource == .lyricsX {
                localLyricsCatalog.rememberManagedLyrics(translated, session: session)
            }
            return true
        }
    }

    /// Translates the lyrics on screen again, as if they had just arrived:
    /// after the settings change, or once the languages system translation
    /// was missing are downloaded.
    func retryLyricsTranslation() {
        performOnLyricsDisplayQueue {
            lastLyricsTranslationKey = nil
            lyricsTranslationTask?.cancel()
            startLyricsTranslation(for: currentLyrics)
        }
    }

    /// One file an automatic lookup may read, and what reading it implies.
    private struct LyricsLookupCandidateFile {
        let fileURL: URL
        /// A plain `.lrc` is displayed but does not end the lookup: it carries
        /// none of the LRCX extras, so a search still runs to try to better it.
        let allowsFurtherSearching: Bool
        /// A file from LyricsX's own library, which the bypass switch may reject
        /// once it has been read and found to carry no user-pick mark.
        let isLibraryFile: Bool
    }

    private func isLyricsXManagedFile(_ fileURL: URL) -> Bool {
        LyricsStoragePolicy.isManagedLibraryFile(
            fileURL,
            defaultDirectoryURL: defaults.lyricsDefaultSavingDirectory,
            customDirectoryURL: defaults.lyricsCustomSavingPath
        )
    }

    private func lyricsXFileCandidates(for track: MusicTrack, preferredURL: URL?) -> [LyricsLookupCandidateFile] {
        let candidates = librarySearchFiles(title: track.title ?? "", artist: track.artist ?? "")
        guard let preferredURL,
              let preferred = candidates.first(where: { $0.fileURL == preferredURL }) else {
            return candidates
        }
        return [preferred] + candidates.filter { $0.fileURL != preferred.fileURL }
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
        let directoryURL = defaults.lyricsSavingPath()
        let baseURLs = LyricsStoragePolicy
            .libraryFileBaseNameCandidates(title: title, artist: artist)
            .map { directoryURL.appendingPathComponent($0) }
        return baseURLs.map {
            LyricsLookupCandidateFile(
                fileURL: $0.appendingPathExtension("lrcx"),
                allowsFurtherSearching: false,
                isLibraryFile: true
            )
        } + baseURLs.map {
            LyricsLookupCandidateFile(
                fileURL: $0.appendingPathExtension("lrc"),
                allowsFurtherSearching: true,
                isLibraryFile: true
            )
        }
    }

    /// Reads the library that `ignoreCachedLyricsLibrary` told the lookup to
    /// skip — but only when the search came back empty-handed. Without this,
    /// "always fetch fresh" would degrade into "no lyrics at all" whenever the
    /// network is down, which is plainly worse than a possibly stale file.
    private func loadLibraryLyricsIfSearchFoundNothing(
        for track: MusicTrack, title: String, artist: String, expectedSearchRequest: LyricsSearchRequest
    ) async {
        guard defaults[.ignoreCachedLyricsLibrary] else { return }
        let selectionID = performOnLyricsDisplayQueue { () -> UUID? in
            guard currentLyrics == nil, selectedPlayer.currentTrack?.id == track.id,
                  searchRequest == expectedSearchRequest else { return nil }
            return localLyricsSelectionID
        }
        guard let selectionID else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            localLyricsRefreshQueue.async {
                defer { continuation.resume() }
                for candidateFile in self.librarySearchFiles(title: title, artist: artist) {
                    guard self.isCurrentTrackLookup(track, selectionID: selectionID) else { return }
                    guard let lyrics = self.loadLyrics(at: candidateFile.fileURL, title: title, artist: artist) else { continue }
                    performOnLyricsDisplayQueue {
                        guard self.currentLyrics == nil, self.searchRequest == expectedSearchRequest else { return }
                        self.commitTrackLookupLyrics(lyrics, source: .lyricsX, for: track, selectionID: selectionID)
                    }
                    return
                }
            }
        }
    }

    // MARK: LyricsSourceDelegate

    func lyricsReceived(lyrics: Lyrics) {
        performOnLyricsDisplayQueue {
            guard let track = selectedPlayer.currentTrack,
                  prepareLyricsCandidate(lyrics, for: track, allowsAutomaticReplacement: true),
                  let request = searchRequest,
                  lyrics.metadata.request?.id == request.id,
                  LyricsDisplayEligibilityPolicy.shouldReplaceDisplayed(
                      selectionIsPinned: candidateSelectionIsPinned,
                      candidateArrivedAfterPriorityWindow: lyrics.arrivedAfterPriorityWindow,
                      displayedIsRecovered: currentLyrics?.isFromSearchPlugin,
                      candidateIsRecovered: lyrics.isFromSearchPlugin,
                      candidateOutranksDisplayed: currentLyrics.map { lyricsHasHigherPriority(lyrics, over: $0) } ?? true
                  ) else { return }
            currentLyrics = lyrics
            lyricsCandidatePool.selectCandidate(identicalTo: lyrics)
            markSelectedOnlineLyricsState(lyrics, for: track.id)
            publishLocalLyricsChange(for: track.id)
        }
    }

    // MARK: Lyrics Candidates

    private func resetLyricsCandidatePool() {
        performOnLyricsDisplayQueue {
            candidateReplenishID = UUID()
            candidateReplenishTask?.cancel()
            candidateReplenishTask = nil
            lyricsCandidatePool.removeAll()
            candidateSelectionIsPinned = false
            candidatePoolTrackId = nil
        }
    }

    private func cancelCandidateReplenishSearch() {
        performOnLyricsDisplayQueue {
            candidateReplenishID = UUID()
            candidateReplenishTask?.cancel()
            candidateReplenishTask = nil
        }
    }

    @discardableResult
    private func rememberSelectedOnlineLyrics(_ lyrics: Lyrics, for trackID: String) -> Bool {
        // A local file or embedded result has neither provider request nor
        // service metadata. Provider results enter the menu's online slot only
        // when this method is called after one has been selected for display,
        // either automatically or by the user; other arrivals stay in the pool.
        guard isOnlineLyricsCandidate(lyrics), selectedPlayer.currentTrack?.id == trackID,
              let session = localLyricsCatalog.captureSession(for: trackID) else { return false }
        return localLyricsCatalog.rememberManagedLyrics(lyrics, session: session)
    }

    @discardableResult
    private func markSelectedOnlineLyricsState(_ lyrics: Lyrics, for trackID: String) -> Bool {
        guard rememberSelectedOnlineLyrics(lyrics, for: trackID) else { return false }
        currentLocalLyricsSource = .lyricsX
        return true
    }

    private func publishLocalLyricsChange(for trackID: String, change: LocalLyricsChange.Kind = .lyricsX) {
        localLyricsChanges.send(LocalLyricsChange(trackID: trackID, kind: change))
    }

    func rejectCurrentLyrics(for trackID: String) {
        performOnLyricsDisplayQueue {
            guard selectedPlayer.currentTrack?.id == trackID else { return }
            cancelLyricsSearches()
            localLyricsCoordinator.discardDeferredImport(for: trackID)
            if let session = localLyricsCatalog.captureSession(for: trackID) {
                localLyricsCatalog.reject(currentLocalLyricsSource, session: session)
            }
            currentLyrics = nil
            publishLocalLyricsChange(for: trackID)
        }
    }

    /// The next-candidate shortcut is an online-search feature. Local lyrics
    /// are intentionally kept out of this pool and remain available through
    /// the Local Lyrics submenu instead.
    private func isOnlineLyricsCandidate(_ lyrics: Lyrics) -> Bool {
        lyrics.metadata.request != nil || lyrics.metadata.service != nil
    }

    /// Validates, normalizes, and stores one online result. Automatic display
    /// is deliberately kept outside this method so a replenish search can
    /// collect candidates without changing what is currently on screen.
    @discardableResult
    private func prepareLyricsCandidate(
        _ lyrics: Lyrics,
        for track: MusicTrack,
        allowsAutomaticReplacement: Bool
    ) -> Bool {
        performOnLyricsDisplayQueue {
            // Match by session id, not request equality: Route B's plugin
            // expands one search into several requests with different search
            // terms but the same session id, and all of them belong here.
            guard let lyricRequestID = lyrics.metadata.request?.id,
                  searchRequest?.id == lyricRequestID, candidatePoolTrackId == track.id else {
                return false
            }
            if defaults[.strictSearchEnabled], !lyrics.isMatched() {
                return false
            }

            lyrics.associateWithTrack(track)
            lyrics.applyQQMusicKanaFurigana()
            lyrics.filtrate()
            lyrics.recognizeLanguage()
            lyrics.metadata.needsPersist = true

            // Entering the pool is unconditional: losing the display contest says
            // nothing about whether the user might want this candidate. Only the
            // caller's display policy decides whether it goes on screen.
            guard insertIntoLyricsCandidatePool(lyrics, for: track) else {
                return false
            }
            scheduleArtworkScoring(
                for: lyrics,
                against: track,
                allowsAutomaticReplacement: allowsAutomaticReplacement
            )
            return true
        }
    }

    /// Puts the lyrics on screen in the pool in place of the candidate they
    /// are a copy of. A translation lands as a copy of the lyrics it
    /// translated — the same lines in another object — so the pool may still
    /// hold the untranslated original, and cycling back onto it would show,
    /// and then write, the lyrics without their translation.
    ///
    /// Local lyrics can have identical content, but must never replace an online entry.
    /// Run on the lyrics display queue before the pool is used.
    private func reconcileLyricsCandidatePoolWithScreen() {
        guard let onScreenLyrics = currentLyrics,
              isOnlineLyricsCandidate(onScreenLyrics),
              !lyricsCandidatePool.contains(where: { $0 === onScreenLyrics }) else {
            return
        }
        let onScreenFingerprint = lyricsContentFingerprint(onScreenLyrics)
        guard let original = lyricsCandidatePool.candidates.first(where: {
            lyricsContentFingerprint($0) == onScreenFingerprint
        }) else {
            return
        }
        let selectedCandidate = lyricsCandidatePool.selectedCandidate
        lyricsCandidatePool.replaceAll(
            with: lyricsCandidatePool.candidates.map { $0 === original ? onScreenLyrics : $0 },
            selecting: selectedCandidate === original ? onScreenLyrics : selectedCandidate
        )
    }

    /// Returns whether `lyrics` was taken into the pool. Rejects results that
    /// belong to another track, and duplicates of a candidate already held —
    /// different services routinely return the very same words, and switching
    /// onto an identical copy reads as the shortcut being broken.
    @discardableResult
    private func insertIntoLyricsCandidatePool(_ lyrics: Lyrics, for track: MusicTrack) -> Bool {
        guard candidatePoolTrackId == track.id,
              isOnlineLyricsCandidate(lyrics) else {
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
    /// Selection and lyric mutations run together on the lyrics display queue.
    func advanceToNextLyricsCandidate() {
        performOnLyricsDisplayQueue {
            guard let track = selectedPlayer.currentTrack else {
                lyricsCandidateSwitchOutcomes.send(.unavailable)
                return
            }
            // The player has moved on and the track change has not reached the
            // pool yet: its candidates are the previous track's, and switching
            // onto one would save it as this track's lyrics.
            guard LyricsResultsApplication(
                resultsFoundFor: candidatePoolTrackId,
                whilePlaying: track.id
            ) == .currentTrack else {
                lyricsCandidateSwitchOutcomes.send(.unavailable)
                return
            }
            reconcileLyricsCandidatePoolWithScreen()
            let selection = (lyricsCandidatePool.candidates, currentLyrics, lyricsSelectionID)
            guard let nextCandidate = nextDistinctOnlineCandidate(
                in: selection.0,
                comparedTo: selection.1
            ) else {
                startCandidateReplenishSearch(for: track)
                return
            }
            guard let commit = applyUserPickedCandidate(
                nextCandidate,
                for: track,
                expectedSelectionID: selection.2
            ) else {
                return
            }
            lyricsCandidateSwitchOutcomes.send(.switched(
                position: commit.position,
                total: commit.total,
                service: commit.service
            ))
        }
    }

    /// Advances through the online pool until it finds content different from
    /// what is currently displayed. The current lyrics may be local and thus
    /// absent from the pool, so pool size alone cannot identify a switchable
    /// candidate.
    private func nextDistinctOnlineCandidate(
        in candidates: [Lyrics],
        comparedTo currentLyrics: Lyrics?
    ) -> Lyrics? {
        guard !candidates.isEmpty else { return nil }
        let currentFingerprint = currentLyrics.map(lyricsContentFingerprint)
        let currentIndex = currentLyrics.flatMap { current in
            candidates.firstIndex { $0 === current }
        }
        let startIndex = currentIndex.map { ($0 + 1) % candidates.count } ?? 0
        for offset in 0..<candidates.count {
            let candidate = candidates[(startIndex + offset) % candidates.count]
            if currentFingerprint == nil || lyricsContentFingerprint(candidate) != currentFingerprint {
                return candidate
            }
        }
        return nil
    }

    /// The pool contains only online provider results. A track that currently
    /// displays local lyrics therefore starts with an empty pool and needs a
    /// search before the shortcut can switch to another result.
    private func startCandidateReplenishSearch(for track: MusicTrack) {
        performOnLyricsDisplayQueue {
            guard candidateReplenishTask == nil, selectedPlayer.currentTrack?.id == track.id else {
                if candidateReplenishTask != nil { lyricsCandidateSwitchOutcomes.send(.searching) }
                return
            }
            searchTask?.cancel()
            searchTask = nil
            candidatePoolTrackId = track.id
            let request = makeLyricsSearchRequest(for: track)
            searchRequest = request
            let replenishID = UUID()
            candidateReplenishID = replenishID
            let selectionID = lyricsSelectionID
            let onScreenFingerprint = currentLyrics.map(lyricsContentFingerprint)
            automaticLyricsReplacementWindow.searchStarted(identifier: request.id, isAutomatic: false)
            lyricsCandidateSwitchOutcomes.send(.searching)

            candidateReplenishTask = Task { @MainActor in
                defer {
                    performOnLyricsDisplayQueue {
                        if candidateReplenishID == replenishID { candidateReplenishTask = nil }
                    }
                }
                var hasSwitched = false
                do {
                    let completion = try await LyricsSearchCompletion.consume(lyricsManager.lyrics(for: request)) { lyrics in
                        performOnLyricsDisplayQueue {
                            guard candidateReplenishID == replenishID,
                                  selectedPlayer.currentTrack?.id == track.id,
                                  prepareLyricsCandidate(lyrics, for: track, allowsAutomaticReplacement: false) else { return }
                            guard !hasSwitched,
                                  let candidate = lyricsCandidatePool.candidates.first(where: { candidate in
                                      onScreenFingerprint.map { lyricsContentFingerprint(candidate) != $0 } ?? true
                                  }),
                                  let commit = applyUserPickedCandidate(candidate, for: track, expectedSelectionID: selectionID) else { return }
                            hasSwitched = true
                            lyricsCandidateSwitchOutcomes.send(.switched(
                                position: commit.position, total: commit.total, service: commit.service
                            ))
                        }
                    }
                    guard completion == .finished else { return }
                } catch is CancellationError {
                    return
                } catch {
                    #log(.error, "Failed to fetch replenish candidates: \(error.localizedDescription, privacy: .public)")
                    guard !Task.isCancelled else { return }
                }
                let shouldReportExhausted = performOnLyricsDisplayQueue {
                    candidateReplenishID == replenishID && selectedPlayer.currentTrack?.id == track.id && !hasSwitched
                }
                if shouldReportExhausted { lyricsCandidateSwitchOutcomes.send(.exhausted) }
            }
        }
    }

    /// Puts a hand-picked candidate on screen and makes it stick: pinned
    /// against later arrivals, written to disk, and recorded so the next play
    /// of this track resolves to it too.
    @discardableResult
    private func applyUserPickedCandidate(
        _ lyrics: Lyrics, for track: MusicTrack, expectedSelectionID: UUID
    ) -> UserPickedCandidateCommit? {
        performOnLyricsDisplayQueue {
            guard selectedPlayer.currentTrack?.id == track.id,
                  lyricsSelectionID == expectedSelectionID,
                  lyricsCandidatePool.contains(where: { $0 === lyrics }),
                  isOnlineLyricsCandidate(lyrics) else { return nil }
            candidateSelectionIsPinned = true
            lyricsCandidatePool.selectCandidate(identicalTo: lyrics)
            lyrics.associateWithTrack(track)
            lyrics.markAsUserPicked(origin: .nextCandidate)
            lyrics.metadata.needsPersist = true
            currentLyrics = lyrics
            markSelectedOnlineLyricsState(lyrics, for: track.id)

            let commit = UserPickedCandidateCommit(
                position: (lyricsCandidatePool.selectedIndex ?? 0) + 1,
                total: lyricsCandidatePool.count, service: lyrics.metadata.service
            )
            publishLocalLyricsChange(for: track.id)
            if let index = defaults[.noSearchingTrackIds].firstIndex(of: track.id) {
                defaults[.noSearchingTrackIds].remove(at: index)
            }
            if lyrics.persist() {
                recordUserSelectionIfAutomaticLookupWouldOverrideIt(lyrics, for: track)
            }
            if defaults[.writeToiTunesAutomatically] {
                writeToiTunes(overwrite: true)
            }
            return commit
        }
    }

    /// Adopts a list the user already sorted through — the manual search panel's
    /// results — so the shortcut carries on from what they picked there. The
    /// pool remains online-only even if a caller supplies a local Lyrics value.
    func adoptLyricsCandidates(_ candidates: [Lyrics], selecting selectedCandidate: Lyrics, for track: MusicTrack) {
        cancelCandidateReplenishSearch()
        let didAdopt = performOnLyricsDisplayQueue { () -> Bool in
            guard selectedPlayer.currentTrack?.id == track.id else { return false }
            candidatePoolTrackId = track.id
            candidateSelectionIsPinned = true
            guard isOnlineLyricsCandidate(selectedCandidate) else {
                lyricsCandidatePool.removeAll()
                return false
            }
            let onlineCandidates = candidates.filter { isOnlineLyricsCandidate($0) }
            lyricsCandidatePool.replaceAll(with: onlineCandidates, selecting: selectedCandidate)
            return markSelectedOnlineLyricsState(selectedCandidate, for: track.id)
        }
        if didAdopt {
            publishLocalLyricsChange(for: track.id)
        }
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
        guard let persistedURL = lyrics.metadata.localURL else { return }
        guard defaults[.loadLyricsBesideTrack] else {
            defaults[.lyricsSelectionOverrides] = LyricsSelectionOverrideTable.removing(
                trackId: track.id, from: defaults[.lyricsSelectionOverrides]
            )
            return
        }
        // Protect the pick immediately. An empty cache is not evidence that
        // embedded lyrics are absent, and the user may leave before Music responds.
        defaults[.lyricsSelectionOverrides] = LyricsSelectionOverrideTable.recording(
            filePath: persistedURL.path, forTrackId: track.id,
            in: defaults[.lyricsSelectionOverrides], at: Date()
        )
        let expectedEntry = defaults[.lyricsSelectionOverrides][track.id]
        if let session = localLyricsCatalog.captureSession(for: track.id) {
            verifySelectionOverride(for: track, persistedURL: persistedURL, expectedEntry: expectedEntry, session: session)
        }
    }

    private func verifySelectionOverride(
        for track: MusicTrack, persistedURL: URL, expectedEntry: String?, session: LocalLyricsState.Session
    ) {
        localLyricsRefreshQueue.async {
            let metadata = self.localLyricsCatalog.metadata(for: track, read: .fresh, session: session, access: .verification)
            let hasEmbedded = metadata?.embeddedText.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                ?? (track.originalTrack != nil)
            let besideURLs = metadata?.fileURL.map { url in
                ["lrcx", "lrc"].map { url.deletingPathExtension().appendingPathExtension($0) }
            } ?? []
            let besideFilePrecedes = !besideURLs.contains(persistedURL) && besideURLs.contains { url in
                (try? withSecurityScopedAccess(to: defaults.lyricsSecurityScopedDirectory(containing: url)) {
                    FileManager.default.fileExists(atPath: url.path)
                }) == true
            }
            performOnLyricsDisplayQueue {
                guard defaults[.lyricsSelectionOverrides][track.id] == expectedEntry else { return }
                if defaults[.loadLyricsBesideTrack], let metadata,
                   !self.localLyricsCatalog.isCurrentMetadata(metadata, session: session) {
                    // A write overtook the verification after the read. Retry
                    // before deciding whether this pin is unnecessary.
                    self.verifySelectionOverride(for: track, persistedURL: persistedURL, expectedEntry: expectedEntry, session: session)
                    return
                }
                defaults[.lyricsSelectionOverrides] = LyricsSelectionOverrideTable.reconcilingVerification(
                    forTrackId: track.id, expectedEntry: expectedEntry,
                    automaticLookupPrecedes: defaults[.loadLyricsBesideTrack] && (hasEmbedded || besideFilePrecedes),
                    in: defaults[.lyricsSelectionOverrides]
                )
            }
        }
    }

    private func loadLyrics(at fileURL: URL, title: String, artist: String) -> Lyrics? {
        try? readLyricsFile(at: fileURL, title: title, artist: artist)
    }

    private func readLyricsFile(at fileURL: URL, title: String, artist: String) throws -> Lyrics {
        try withSecurityScopedAccess(to: defaults.lyricsSecurityScopedDirectory(containing: fileURL)) {
            let lyrics = try parseLocalLyrics(String(contentsOf: fileURL, encoding: .utf8))
            lyrics.metadata.localURL = fileURL
            lyrics.metadata.title = title
            lyrics.metadata.artist = artist
            prepareLyricsForDisplay(lyrics)
            return lyrics
        }
    }

    private func prepareEmbeddedLyrics(_ lyrics: Lyrics, title: String, artist: String) {
        if lyrics.metadata.title?.isEmpty != false { lyrics.metadata.title = title }
        if lyrics.metadata.artist?.isEmpty != false { lyrics.metadata.artist = artist }
        prepareLyricsForDisplay(lyrics)
    }

    private func prepareLyricsForDisplay(_ lyrics: Lyrics) {
        lyrics.applyQQMusicKanaFurigana()
        lyrics.filtrate()
        lyrics.recognizeLanguage()
    }

    private func makeLyricsSearchRequest(for track: MusicTrack) -> LyricsSearchRequest {
        let title = track.title ?? ""
        let artist = track.artist ?? ""
        // Strip bracketed suffixes ("(feat. X)", "[Explicit]", "(Remix)", "【现场版】" …)
        // from the search title when the preference is on; providers usually return
        // zero matches for the bracketed form. The full title still drives local
        // cache lookup and the lyrics metadata association.
        let searchTitle = defaults[.stripSearchTitleBracketsEnabled] ? title.strippingBrackets : title
        return LyricsSearchRequest(
            searchTerm: .info(title: searchTitle, artist: artist),
            duration: track.duration ?? 0,
            limit: 5,
            userInfo: [:]
        )
    }

    private func scheduleArtworkScoring(
        for lyrics: Lyrics,
        against track: MusicTrack,
        allowsAutomaticReplacement: Bool
    ) {
        guard defaults[.artworkSimilarityBoostEnabled],
              let url = lyrics.metadata.artworkURL else { return }
        let scoredTrackId = track.id
        let scoredRequest = lyrics.metadata.request
        Task { [weak self] in
            let matched = await ArtworkSimilarityScorer.shared.matches(artworkURL: url)
            guard matched, let self else { return }
            await self.applyArtworkBonus(
                to: lyrics,
                scoredTrackId: scoredTrackId,
                scoredRequest: scoredRequest,
                allowsAutomaticReplacement: allowsAutomaticReplacement
            )
        }
    }

    @MainActor
    private func applyArtworkBonus(
        to lyrics: Lyrics,
        scoredTrackId: String,
        scoredRequest: LyricsSearchRequest?,
        allowsAutomaticReplacement: Bool
    ) {
        let shouldPublish = performOnLyricsDisplayQueue { () -> Bool in
            // Drop the bonus if the user has already moved on to another song —
            // the score was computed against a now-stale artwork.
            guard selectedPlayer.currentTrack?.id == scoredTrackId,
                  let scoredRequest,
                  searchRequest?.id == scoredRequest.id else { return false }
            reconcileLyricsCandidatePoolWithScreen()
            let scoredLyrics: Lyrics
            if let current = currentLyrics, current !== lyrics,
               lyricsContentFingerprint(current) == lyricsContentFingerprint(lyrics) {
                scoredLyrics = current
            } else {
                scoredLyrics = lyrics
            }
            scoredLyrics.artworkMatchBonus = ArtworkSimilarityScorer.matchBonus
            // The bonus changed this candidate's rank, so the pool has to be
            // re-sorted; the selection stays on whatever object it was pointing at.
            lyricsCandidatePool.resort()
            // The user picked a candidate by hand; a score change must not move it.
            guard !candidateSelectionIsPinned else { return false }
            // A replenish search is collecting options for an explicit user
            // switch. Artwork may reorder those options, but cannot silently
            // replace the lyrics currently on screen.
            guard allowsAutomaticReplacement else { return false }
            // A bonus landing later cannot resurrect a result that already missed
            // the priority window — otherwise late arrivals would take the screen
            // through the artwork path that they are denied through the normal one.
            guard !scoredLyrics.arrivedAfterPriorityWindow else { return false }
            // The lyrics may now outrank the current selection. Re-run the swap
            // check; lyricsReceived's own guards (request id, recovered/non-
            // recovered tier, strict match) still apply.
            guard let current = currentLyrics, current !== scoredLyrics,
                  lyricsHasHigherPriority(scoredLyrics, over: current) else { return false }
            currentLyrics = scoredLyrics
            lyricsCandidatePool.selectCandidate(identicalTo: scoredLyrics)
            // Artwork scoring may select a different online result after the
            // initial search winner. Keep the menu's single LyricsX slot in
            // sync with the candidate now shown on screen.
            return markSelectedOnlineLyricsState(scoredLyrics, for: scoredTrackId)
        }
        if shouldPublish {
            publishLocalLyricsChange(for: scoredTrackId)
        }
    }

    // MARK: Widget Data Bridge

    /// The widget's play/pause button. WidgetKit reloads the widget when the
    /// button's intent returns, so the snapshot has to show the new state by
    /// then, ahead of the player reporting it.
    func togglePlaybackFromWidget() async {
        let playbackStateBeforeToggle = await MainActor.run {
            let playbackState = selectedPlayer.playbackState
            selectedPlayer.playPause()
            return playbackState
        }
        let expectedPlaybackState: PlaybackState = playbackStateBeforeToggle.isPlaying
            ? .paused(time: playbackStateBeforeToggle.time)
            : .playing(start: Date().addingTimeInterval(-playbackStateBeforeToggle.time))
        await widgetReloadCoordinator.deliverPlaybackToggle(expectedPlaybackState: expectedPlaybackState)
    }

    /// The widget's next-track button. Returns once the next track and its
    /// lyrics are in the snapshot that WidgetKit reloads the widget with when
    /// the button's intent returns.
    func skipToNextTrackFromWidget() async {
        await MainActor.run {
            selectedPlayer.skipToNextItem()
        }
        await widgetReloadCoordinator.waitForTrackChangeDelivery(timeout: Self.widgetTrackChangeTimeout)
    }

    /// The widget's previous-track button; see `skipToNextTrackFromWidget()`.
    func skipToPreviousTrackFromWidget() async {
        await MainActor.run {
            selectedPlayer.skipToPreviousItem()
        }
        await widgetReloadCoordinator.waitForTrackChangeDelivery(timeout: Self.widgetTrackChangeTimeout)
    }

    /// How long a skip button waits for its track change. Past the longest a
    /// change is held (`WidgetReloadPolicy.Schedule.maximumHold`), plus time
    /// for the player to report the new track. A skip that restarts the same
    /// track has no track change and returns when this runs out.
    private static let widgetTrackChangeTimeout: TimeInterval = 4

    /// Persist the current snapshot without rebuilding the timeline.
    /// Use on lyric-line transitions: pre-generated future entries already
    /// drive the line change in the widget process, so a reload would only
    /// add WidgetKit scheduling latency. We still refresh the dataStore so
    /// what the widget reads on its own (a timeline WidgetKit asks for on its
    /// schedule, the snapshot in the widget gallery) and the next reload stay
    /// accurate.
    func updateWidgetSnapshot() {
        guard #available(macOS 14, *) else { return }
        writeWidgetSnapshot(playbackState: nil)
    }

    /// Clears the widget's snapshot as the app quits and reloads the widget.
    /// Nothing keeps the snapshot current after that, and the widget would go
    /// on showing a playing song — its timeline plays the lines forward from
    /// the snapshot's moment — for as long as it stays on the desktop. Runs
    /// on `DispatchQueue.lyricsDisplay`.
    func retireWidgetSnapshot() {
        widgetSnapshotIsRetired = true
        widgetDataStore.clear()
        widgetReloadCoordinator.deliverClearedSnapshotNow()
    }

    /// Writes the snapshot the widget reads and returns it, or clears it and
    /// returns `nil` when nothing is playing. Never reloads the widget: that
    /// is `WidgetReloadCoordinator`'s call.
    ///
    /// A `playbackState` passed in is used instead of the player's, for a
    /// state the player has not reported yet.
    @discardableResult
    private func writeWidgetSnapshot(playbackState explicitPlaybackState: PlaybackState?) -> LyricsWidgetData? {
        guard !widgetSnapshotIsRetired else { return nil }
        guard let track = selectedPlayer.currentTrack else {
            widgetDataStore.clear()
            return nil
        }

        let playbackState = explicitPlaybackState ?? selectedPlayer.playbackState
        let playbackTime = playbackState.time
        // #log(.info, "[LXWG][Write] enter (track=\(track.title ?? "nil", privacy: .public), isPlaying=\(playbackState.isPlaying, privacy: .public), time=\(playbackTime, privacy: .public), usedExplicit=\(explicitPlaybackState != nil, privacy: .public))")

        // Build lyrics lines with context window
        var lyricsLines: [LyricsLineEntry] = []
        var widgetCurrentLineIndex = 0

        if let lyrics = currentLyrics {
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

                    return LyricsLineEntry(
                        text: line.content,
                        // The translation the desktop lyrics show, so the
                        // widget follows the display language too.
                        translation: lyrics.displayTranslation(for: line),
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
            showsTranslation: defaults[.preferBilingualLyrics]
        )

        do {
            try widgetDataStore.write(widgetData)
            // #log(.info, "[LXWG][Write] wrote snapshot (isPlaying=\(widgetData.isPlaying, privacy: .public), playbackPosition=\(widgetData.playbackPosition, privacy: .public), lineIndex=\(widgetData.currentLineIndex, privacy: .public), lyricsLines=\(widgetData.lyricsLines.count, privacy: .public))")
        } catch {
            // #log(.error, "[LXWG][Write] dataStore.write failed: \(error.localizedDescription, privacy: .public)")
        }
        return widgetData
    }
}

extension AppController {
    private func parseLocalLyrics(_ contents: String) throws -> Lyrics {
        guard let lyrics = Lyrics(contents) else {
            throw invalidLocalLyricsError()
        }
        return lyrics
    }

    private func invalidLocalLyricsError() -> NSError {
        NSError(domain: lyricsXErrorDomain, code: 0, userInfo: [
            NSLocalizedDescriptionKey: NSLocalizedString("Invalid lyric file", comment: "Lyrics parsing error"),
        ])
    }

    private func persistCurrentLyrics() {
        performOnLyricsDisplayQueue {
            guard let lyrics = currentLyrics, lyrics.metadata.needsPersist else { return }
            lyrics.persist()
        }
    }

    func importLyrics(_ lyricsString: String, filePath: String? = nil) throws {
        try performOnLyricsDisplayQueue {
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
            cancelLyricsSearches()
            if let session = localLyricsCatalog.captureSession(for: track.id) {
                applyImportedLyrics(lrc, for: track, session: session)
            } else {
                localLyricsCoordinator.deferImportUntilActivation(lrc, for: track.id)
            }
        }
    }

    /// Runs on lyricsDisplay after the selected track has an active session.
    private func applyImportedLyrics(_ lrc: Lyrics, for track: MusicTrack, session: LocalLyricsState.Session) {
        guard selectedPlayer.currentTrack?.id == track.id, localLyricsCatalog.isActive(session) else { return }
        currentLyrics = lrc
        // An imported file is as deliberate a choice as picking a candidate, so
        // it takes over the pool and is pinned against a search still in flight.
        adoptLyricsCandidates([lrc], selecting: lrc, for: track)
        localLyricsCatalog.rememberManagedLyrics(lrc, session: session)
        currentLocalLyricsSource = .lyricsX
        publishLocalLyricsChange(for: track.id)
        if let index = defaults[.noSearchingTrackIds].firstIndex(of: track.id) {
            defaults[.noSearchingTrackIds].remove(at: index)
        }
        if let index = defaults[.noSearchingAlbumNames].firstIndex(of: track.album ?? "") {
            defaults[.noSearchingAlbumNames].remove(at: index)
        }
    }
}
