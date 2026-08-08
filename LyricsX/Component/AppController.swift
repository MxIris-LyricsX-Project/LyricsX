import AppKit
import Combine
import Regex
import OpenCC
import MusicPlayer
import LyricsXFoundation

private final class LyricsDisplayTransfer<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

final class AppController: NSObject, @unchecked Sendable {
    static let shared = AppController()

    var lyricsManager: LyricsProvider

    @Published private(set) var currentLyrics: Lyrics? {
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

    private var searchRequest: LyricsSearchRequest?
    private var searchTask: Task<Void, Never>?
    private var searchDeadline: DispatchWorkItem?
    private var automaticSearchGeneration: UUID?

    private var cancelBag = Set<AnyCancellable>()

    @objc dynamic var lyricsOffset: Int {
        get {
            if !DispatchQueue.isOnLyricsDisplay {
                return DispatchQueue.lyricsDisplay.sync { self.lyricsOffset }
            }
            return currentLyrics?.offset ?? 0
        }
        set {
            if !DispatchQueue.isOnLyricsDisplay {
                DispatchQueue.lyricsDisplay.sync { self.lyricsOffset = newValue }
                return
            }
            currentLyrics?.offset = newValue
            currentLyrics?.metadata.needsPersist = true
            scheduleCurrentLineCheck()
        }
    }

    func setCurrentLyrics(_ lyrics: Lyrics?) {
        if DispatchQueue.isOnLyricsDisplay {
            cancelAutomaticLyricsSearchOnLyricsDisplay()
            currentLyrics = lyrics
        } else {
            DispatchQueue.lyricsDisplay.sync {
                self.cancelAutomaticLyricsSearchOnLyricsDisplay()
                self.currentLyrics = lyrics
            }
        }
    }

    private override init() {
        self.lyricsManager = LyricsProviders.Group()
        super.init()
        selectedPlayer.currentTrackWillChange
            .signal()
            .receive(on: DispatchQueue.lyricsDisplay)
            .invoke(AppController.currentTrackChanged, weaklyOn: self)
            .store(in: &cancelBag)
        selectedPlayer.playbackStateWillChange
            .signal()
            .receive(on: DispatchQueue.lyricsDisplay)
            .invoke(AppController.scheduleCurrentLineCheck, weaklyOn: self)
            .store(in: &cancelBag)

        workspaceNC.publisher(for: NSWorkspace.didTerminateApplicationNotification, object: nil)
            .sink { notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let bundleID = application.bundleIdentifier
                if defaults[.launchAndQuitWithPlayer], (selectedPlayer.designatedPlayer as? MusicPlayers.Scriptable)?.playerBundleID == bundleID {
                    NSApplication.shared.terminate(self)
                }
            }.store(in: &cancelBag)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.updateLyricsManager()
            } catch {
                log("Failed to initialize lyrics providers")
            }
            DispatchQueue.lyricsDisplay.async { [weak self] in
                self?.currentTrackChanged()
            }
        }
    }

    @MainActor
    func updateLyricsManager() async throws {
        let services: [LyricsProviders.Service] = LyricsProviders.Service.noAuthenticationRequiredServices

        var providers: [LyricsProvider] = []
        for service in services {
            providers.append(service.create())
        }

        // Add Musixmatch provider with saved token if available
        if let token = defaults[.musixmatchToken], !token.isEmpty {
            let musixmatchProvider = LyricsProviders.Musixmatch(usertoken: token)
            providers.append(musixmatchProvider)
        }

        let lyricsManager = LyricsDisplayTransfer(LyricsProviders.Group(providers: providers))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.lyricsDisplay.async { [weak self] in
                self?.lyricsManager = lyricsManager.value
                continuation.resume()
            }
        }
    }

    var currentLineCheckSchedule: Cancellable?

    func scheduleCurrentLineCheck() {
        currentLineCheckSchedule?.cancel()
        guard let lyrics = currentLyrics else {
            return
        }
        let playbackState = MusicPlayers.Selected.shared.playbackState
        let playbackTime = playbackState.time
        let (index, next) = lyrics[playbackTime + lyrics.adjustedTimeDelay]
        if currentLineIndex != index {
            currentLineIndex = index
        }
        if let next = next, playbackState.isPlaying {
            let dt = lyrics.lines[next].position - playbackTime - lyrics.adjustedTimeDelay
            let q = DispatchQueue.lyricsDisplay
            currentLineCheckSchedule = q.schedule(after: q.now.advanced(by: .seconds(dt)), interval: .seconds(42), tolerance: .milliseconds(20)) { [unowned self] in
                self.scheduleCurrentLineCheck()
            }
        }
    }

    func writeToiTunes(overwrite: Bool) {
        if !DispatchQueue.isOnLyricsDisplay {
            DispatchQueue.lyricsDisplay.sync {
                self.writeToiTunes(overwrite: overwrite)
            }
            return
        }
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
        cancelAutomaticLyricsSearchOnLyricsDisplay()
        currentLyrics = nil
        currentLineIndex = nil
        guard let track = selectedPlayer.currentTrack else {
            return
        }
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
        let request = LyricsSearchRequest(searchTerm: .info(title: title, artist: artist), duration: duration, limit: 5)
        let searchGeneration = UUID()
        let provider = lyricsManager
        let priorityWindow = max(defaults[.lyricsPriorityWindow] ?? 5, 0)
        searchRequest = request
        automaticSearchGeneration = searchGeneration
        searchTask = Task { [weak self] in
            do {
                for try await lyrics in provider.lyrics(for: request) {
                    try Task.checkCancellation()
                    await self?.receiveAutomaticLyrics(
                        lyrics,
                        generation: searchGeneration,
                        priorityWindow: priorityWindow
                    )
                }
            } catch is CancellationError {
                // Search was cancelled due to track change
            } catch {
                print("Failed to fetch lyrics: \(error.localizedDescription)")
            }
            await self?.finishAutomaticLyricsSearch(
                generation: searchGeneration,
                cancelProviderTask: false
            )
        }
    }

    private func cancelAutomaticLyricsSearchOnLyricsDisplay() {
        searchDeadline?.cancel()
        searchDeadline = nil
        searchTask?.cancel()
        searchTask = nil
        searchRequest = nil
        automaticSearchGeneration = nil
    }

    private func scheduleAutomaticSearchDeadline(
        generation: UUID,
        priorityWindow: TimeInterval
    ) {
        guard automaticSearchGeneration == generation,
              searchDeadline == nil else {
            return
        }
        let deadline = DispatchWorkItem { [weak self] in
            self?.finishAutomaticLyricsSearchOnLyricsDisplay(
                generation: generation,
                cancelProviderTask: true
            )
        }
        searchDeadline = deadline
        DispatchQueue.lyricsDisplay.asyncAfter(
            deadline: .now() + max(priorityWindow, 0),
            execute: deadline
        )
    }

    private func receiveAutomaticLyrics(
        _ lyrics: Lyrics,
        generation: UUID,
        priorityWindow: TimeInterval
    ) async {
        let lyrics = LyricsDisplayTransfer(lyrics)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.lyricsDisplay.async { [weak self] in
                defer { continuation.resume() }
                guard let self,
                      self.automaticSearchGeneration == generation else {
                    return
                }
                self.lyricsReceived(lyrics: lyrics.value)
                if self.currentLyrics === lyrics.value {
                    self.scheduleAutomaticSearchDeadline(
                        generation: generation,
                        priorityWindow: priorityWindow
                    )
                }
            }
        }
    }

    private func finishAutomaticLyricsSearch(
        generation: UUID,
        cancelProviderTask: Bool
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.lyricsDisplay.async { [weak self] in
                self?.finishAutomaticLyricsSearchOnLyricsDisplay(
                    generation: generation,
                    cancelProviderTask: cancelProviderTask
                )
                continuation.resume()
            }
        }
    }

    private func finishAutomaticLyricsSearchOnLyricsDisplay(
        generation: UUID,
        cancelProviderTask: Bool
    ) {
        guard automaticSearchGeneration == generation else {
            return
        }
        searchDeadline?.cancel()
        searchDeadline = nil
        if cancelProviderTask {
            searchTask?.cancel()
        }
        searchTask = nil
        searchRequest = nil
        automaticSearchGeneration = nil
        if defaults[.writeToiTunesAutomatically] {
            writeToiTunes(overwrite: true)
        }
    }

    // MARK: LyricsSourceDelegate

    func lyricsReceived(lyrics: Lyrics) {
        guard let req = searchRequest,
              lyrics.metadata.request == req,
              let track = selectedPlayer.currentTrack else {
            return
        }
        if defaults[.strictSearchEnabled], !lyrics.isMatched() {
            return
        }
        if let current = currentLyrics, !lyricsHasHigherPriority(lyrics, over: current) {
            return
        }

        lyrics.associateWithTrack(track)
        lyrics.filtrate()
        lyrics.recognizeLanguage()
        lyrics.metadata.needsPersist = true
        currentLyrics = lyrics
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
        lrc.filtrate()
        lrc.recognizeLanguage()
        lrc.metadata.needsPersist = true
        setCurrentLyrics(lrc)
        if let index = defaults[.noSearchingTrackIds].firstIndex(of: track.id) {
            defaults[.noSearchingTrackIds].remove(at: index)
        }
        if let index = defaults[.noSearchingAlbumNames].firstIndex(of: track.album ?? "") {
            defaults[.noSearchingAlbumNames].remove(at: index)
        }
    }
}
