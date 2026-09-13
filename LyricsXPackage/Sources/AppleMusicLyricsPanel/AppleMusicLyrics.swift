import AppKit
import Combine
import Foundation
import LyricsXFoundation
import MusicPlayer

/// Namespace for the Apple Music-style lyrics panel. The hosting app extends
/// it with its own glue (window controller, preference wiring).
public enum AppleMusicLyrics {}

extension AppleMusicLyrics {
    /// Everything the panel needs from the hosting app but must not know the
    /// source of — user preferences and app-level lyric policy. The defaults
    /// are self-contained so probe builds (`swift test`) run without any app.
    public struct HostEnvironment {
        /// The player the panel reads playback state from and sends transport
        /// commands to. The app passes its `MusicPlayers.Selected.shared`; the
        /// default is an inert `Virtual` player so probes need no real player.
        public var player: MusicPlayerProtocol

        /// Whether a line's translation row is shown at all.
        public var isBilingualPreferred: () -> Bool

        /// Applied to a translation before display. The app routes this
        /// through its Chinese-conversion preference.
        public var transformTranslation: (String) -> String

        /// The delay added to raw playback time before it is compared against
        /// lyric timestamps. The app folds its global user-set offset in here;
        /// the default is just the lyrics file's own `[offset:]` tag.
        public var lyricsTimeDelay: (Lyrics) -> TimeInterval

        /// Fires when the two translation policies above may return new
        /// values, so already-built lines re-render. The app wires this to its
        /// bilingual / Chinese-conversion preference changes.
        public var translationSettingsDidChange: AnyPublisher<Void, Never>

        /// Delivers a higher-resolution copy of a track's cover once the app has
        /// found one and confirmed it depicts the same artwork. The panel's cover
        /// view is stretched to roughly 1400 pixels on a full-screen 5K window,
        /// well past what a player publishes, so the picture it starts with is
        /// the player's and this replaces it in place.
        public var artworkUpgrades: AnyPublisher<ArtworkUpgrade, Never>

        public init(
            player: MusicPlayerProtocol = MusicPlayers.Virtual(),
            isBilingualPreferred: @escaping () -> Bool = { true },
            transformTranslation: @escaping (String) -> String = { $0 },
            lyricsTimeDelay: @escaping (Lyrics) -> TimeInterval = { TimeInterval($0.offset) / 1000 },
            translationSettingsDidChange: AnyPublisher<Void, Never> = Empty(completeImmediately: false).eraseToAnyPublisher(),
            artworkUpgrades: AnyPublisher<ArtworkUpgrade, Never> = Empty(completeImmediately: false).eraseToAnyPublisher()
        ) {
            self.player = player
            self.isBilingualPreferred = isBilingualPreferred
            self.transformTranslation = transformTranslation
            self.lyricsTimeDelay = lyricsTimeDelay
            self.translationSettingsDidChange = translationSettingsDidChange
            self.artworkUpgrades = artworkUpgrades
        }
    }

    /// A cover the app found on the network, already confirmed to belong to
    /// `trackIdentifier`'s song and to be larger than what the player published.
    public struct ArtworkUpgrade {
        /// The `MusicTrack.id` this cover was resolved for. The panel drops an
        /// upgrade that arrives after the listener has moved on.
        public let trackIdentifier: String
        public let image: NSImage

        public init(trackIdentifier: String, image: NSImage) {
            self.trackIdentifier = trackIdentifier
            self.image = image
        }
    }

    /// Set by the app before the panel is first shown; left at its defaults in
    /// probe harnesses.
    public static var hostEnvironment = HostEnvironment()
}

/// The app declares a `selectedPlayer` alias in `Global.swift`; this twin
/// keeps the moved sources reading the same way while resolving through the
/// host environment (the app's shared selected player once installed).
var selectedPlayer: MusicPlayerProtocol {
    AppleMusicLyrics.hostEnvironment.player
}

extension Lyrics {
    /// The app has its own `adjustedTimeDelay` (user-defaults-backed); this
    /// module-internal twin keeps the moved sources reading the same way while
    /// routing the value through the host environment.
    var adjustedTimeDelay: TimeInterval {
        AppleMusicLyrics.hostEnvironment.lyricsTimeDelay(self)
    }
}
