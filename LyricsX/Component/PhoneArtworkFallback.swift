import AppKit
import Combine

/// The same online artwork resolver as the upstream panel, used only after
/// Bluetooth reports no usable cover service or no image handle for this song.
final class PhoneArtworkFallback {
    private var cancellables = Set<AnyCancellable>()
    private var task: Task<Void, Never>?
    private var attemptedRequest: String?
    private var generation = 0

    init() {
        Publishers.MergeMany(
            PhonePlayer.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            selectedPlayer.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            AppController.shared.$currentLyrics.map { _ in () }.eraseToAnyPublisher(),
            defaults.publisher(for: [.phoneOnlineArtworkEnabled]).map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.refresh() }
        .store(in: &cancellables)
        refresh()
    }

    deinit { task?.cancel() }

    private func refresh() {
        let phone = PhonePlayer.shared
        guard defaults[.phoneOnlineArtworkEnabled] else {
            cancel()
            phone.clearArtworkFallback()
            return
        }
        guard selectedPlayer.activePlayer === phone,
              phone.needsArtworkFallback,
              let key = phone.artworkFallbackKey,
              let track = phone.currentTrack else {
            cancel()
            return
        }
        let lyrics = AppController.shared.currentLyrics
        let candidate = lyrics?.metadata.artworkURL.map {
            ArtworkCandidateSource(url: $0, title: lyrics?.idTags[.title],
                                   artist: lyrics?.idTags[.artist], duration: lyrics?.length)
        }
        // Allow one additional attempt when lyrics or a duration arrive. Position
        // updates do not cause repeated searches, including after a failed lookup.
        let requestKey = [key, String(track.duration ?? 0), candidate?.url.absoluteString ?? ""].joined(separator: "\u{1f}")
        guard attemptedRequest != requestKey else { return }
        cancel()
        attemptedRequest = requestKey
        let requestGeneration = generation
        let request = HighResolutionArtworkRequest(
            trackIdentifier: key, title: track.title, artist: track.artist,
            album: track.album, duration: track.duration, localArtwork: nil,
            // A phone lookup can be cancelled by switching sources or tracks.
            // Cache successful covers, never turn cancellation into a week-long miss.
            lyricsArtwork: candidate, mayRecordMiss: false
        )
        task = Task { @MainActor [weak self] in
            let image = await HighResolutionArtworkService.phoneFallbackArtwork(for: request)
            guard !Task.isCancelled, let self, self.generation == requestGeneration,
                  defaults[.phoneOnlineArtworkEnabled],
                  selectedPlayer.activePlayer === phone, let image else { return }
            phone.acceptArtworkFallback(image, for: key)
        }
    }

    private func cancel() {
        task?.cancel()
        task = nil
        attemptedRequest = nil
        generation += 1
    }
}
