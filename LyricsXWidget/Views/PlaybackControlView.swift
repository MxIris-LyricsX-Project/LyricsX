import SwiftUI
import AppIntents

struct PlaybackControlView: View {
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 32) {
            Button(intent: PreviousTrackIntent()) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)

            Button(intent: PlayPauseIntent()) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .buttonStyle(.plain)

            Button(intent: NextTrackIntent()) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
    }
}
