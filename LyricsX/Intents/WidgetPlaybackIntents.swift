import AppIntents
#if !WIDGET_EXTENSION
import MusicPlayer
#endif

@available(macOS 13.0, *)
struct PlayPauseIntent: AppIntent {
    static var title: LocalizedStringResource = "Play/Pause"
    static var description: IntentDescription = "Toggle music playback"
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await MainActor.run {
            MusicPlayers.Selected.shared.playPause()
        }
        #endif
        return .result()
    }
}

@available(macOS 13.0, *)
struct NextTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Next Track"
    static var description: IntentDescription = "Skip to next track"
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await MainActor.run {
            MusicPlayers.Selected.shared.skipToNextItem()
        }
        #endif
        return .result()
    }
}

@available(macOS 13.0, *)
struct PreviousTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Previous Track"
    static var description: IntentDescription = "Skip to previous track"
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await MainActor.run {
            MusicPlayers.Selected.shared.skipToPreviousItem()
        }
        #endif
        return .result()
    }
}
