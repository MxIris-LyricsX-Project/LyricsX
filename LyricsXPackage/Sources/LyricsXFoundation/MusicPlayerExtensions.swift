import AppKit
import MusicPlayer

extension PlaybackState {
    public static var lyricsRepeatWrapGracePeriod: TimeInterval {
        0.5
    }

    public func lyricsDisplayTime(trackDuration: TimeInterval?) -> TimeInterval {
        let playbackTime = time
        guard isPlaying,
              playbackTime.isFinite,
              let trackDuration = trackDuration,
              trackDuration.isFinite,
              trackDuration > 0,
              playbackTime >= trackDuration + Self.lyricsRepeatWrapGracePeriod else {
            return playbackTime
        }
        return playbackTime.truncatingRemainder(dividingBy: trackDuration)
    }
}

extension MusicTrack {
    /// Returns artwork, falling back to direct SBObject KVC access when the struct's
    /// cached artwork is nil due to ScriptingBridge's NSNull caching race condition.
    /// KVC returns NSAppleEventDescriptor instead of NSImage, so raw bytes are extracted manually.
    public var resolvedArtwork: NSImage? {
        if let artwork = artwork {
            return artwork
        }
        guard let originalTrack = originalTrack as? NSObject,
              originalTrack.responds(to: NSSelectorFromString("artworks")),
              let artworksArray = originalTrack.value(forKey: "artworks") as? NSArray,
              let firstArtwork = artworksArray.firstObject as? NSObject,
              firstArtwork.responds(to: NSSelectorFromString("data")),
              let descriptor = firstArtwork.value(forKey: "data") as? NSAppleEventDescriptor else {
            return nil
        }
        return NSImage(data: descriptor.data)
    }
}
