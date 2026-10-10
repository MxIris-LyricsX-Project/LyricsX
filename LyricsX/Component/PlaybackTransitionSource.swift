/// A source can be temporarily empty while replacing its current track.
/// Implementations must bound this state and end it on pause or disconnect.
protocol PlaybackTransitionSource: AnyObject {
    var isChangingTrack: Bool { get }
    var isLoadingTrack: Bool { get }
}
