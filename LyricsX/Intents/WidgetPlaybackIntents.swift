import AppIntents

// The widget's playback buttons. The sandboxed widget extension cannot drive a
// music player, so these have to run in the app. Adopting `AudioPlaybackIntent`
// gets them there without opening the app. `openAppWhenRun` used to do it by
// opening LyricsX, and opening an app that is already running is a reopen,
// which `applicationShouldHandleReopen` answers with the preferences window.
//
// WidgetKit reloads the widget when `perform()` returns and reads whatever the
// app has written for it by then, so each of these returns only once the
// widget's snapshot shows what the button did.

@available(macOS 14.0, *)
struct PlayPauseIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play/Pause"
    static let description: IntentDescription = "Toggle music playback"

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await AppController.shared.togglePlaybackFromWidget()
        #endif
        return .result()
    }
}

@available(macOS 14.0, *)
struct NextTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Next Track"
    static let description: IntentDescription = "Skip to next track"

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await AppController.shared.skipToNextTrackFromWidget()
        #endif
        return .result()
    }
}

@available(macOS 14.0, *)
struct PreviousTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Previous Track"
    static let description: IntentDescription = "Skip to previous track"

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await AppController.shared.skipToPreviousTrackFromWidget()
        #endif
        return .result()
    }
}
