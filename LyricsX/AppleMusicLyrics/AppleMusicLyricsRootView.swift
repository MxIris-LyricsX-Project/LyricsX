import SwiftUI
import Combine
import LyricsXFoundation
import MusicPlayer

@available(macOS 15, *)
struct AppleMusicLyricsRootView: View {

    @State private var currentLyrics: Lyrics?
    @State private var currentLineIndex: Int?
    @State private var playbackTime: TimeInterval = 0
    @State private var artwork: NSImage?
    @State private var interactionState = InteractionStateModel()
    @State private var karaokeMode: KaraokeMode = .characterLevel
    @State private var trackTitle: String?
    @State private var trackArtist: String?
    @State private var trackDuration: TimeInterval?
    @State private var isPlaying: Bool = false

    private let playbackTimerPublisher = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    private var backgroundMode: Int {
        defaults[.appleMusicLyricsBackgroundMode]
    }

    var body: some View {
        ZStack {
            BackgroundView(artwork: artwork, backgroundMode: backgroundMode)
                .ignoresSafeArea()

            GeometryReader { geometry in
                let isWideEnough = geometry.size.width > 640

                if isWideEnough {
                    wideLayout(windowSize: geometry.size)
                } else {
                    compactLayout(windowSize: geometry.size)
                }
            }

            // Interaction state button overlay
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    interactionButton
                        .padding(20)
                }
            }
        }
        .onReceive(AppController.shared.$currentLyrics.receive(on: DispatchQueue.main)) { lyrics in
            currentLyrics = lyrics
            refreshArtwork()
        }
        .onReceive(AppController.shared.$currentLineIndex.receive(on: DispatchQueue.main)) { index in
            currentLineIndex = index
        }
        .onReceive(selectedPlayer.currentTrackWillChange.receive(on: DispatchQueue.main)) { _ in
            refreshArtwork()
            refreshTrackInfo()
        }
        .onReceive(playbackTimerPublisher) { _ in
            playbackTime = selectedPlayer.playbackTime
            isPlaying = selectedPlayer.playbackState.isPlaying
            if artwork == nil {
                refreshArtwork()
            }
            if trackTitle == nil {
                refreshTrackInfo()
            }
        }
        .frame(minWidth: 900, minHeight: 500)
    }

    // MARK: - Adaptive Sizing

    private func adaptiveMainFontSize(for windowWidth: CGFloat) -> CGFloat {
        max(26, min(42, windowWidth * 0.03))
    }

    private func adaptiveTranslationFontSize(for windowWidth: CGFloat) -> CGFloat {
        max(14, adaptiveMainFontSize(for: windowWidth) * 0.55)
    }

    // MARK: - Wide Layout (cover left, lyrics right)

    @ViewBuilder
    private func wideLayout(windowSize: CGSize) -> some View {
        let coverAreaWidth = windowSize.width * 0.35
        let coverSize = max(150, min(coverAreaWidth * 0.75, windowSize.height - 260))
        let mainFont = adaptiveMainFontSize(for: windowSize.width)
        let translationFont = adaptiveTranslationFontSize(for: windowSize.width)

        HStack(spacing: 0) {
            // Left: Album cover + track info + controls
            VStack(spacing: 0) {
                Spacer(minLength: 40)

                albumCoverView(size: coverSize)

                Spacer().frame(height: 20)

                trackInfoView(maxWidth: coverSize)

                Spacer().frame(height: 16)

                progressBarView(width: coverSize)

                Spacer().frame(height: 16)

                playbackControlsView

                Spacer(minLength: 40)
            }
            .frame(width: coverAreaWidth)

            // Right: Lyrics — fills remaining space
            if let lyrics = currentLyrics {
                lyricsContent(lyrics: lyrics, mainFontSize: mainFont, translationFontSize: translationFont)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                noLyricsView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Compact Layout (lyrics only, for narrow windows)

    @ViewBuilder
    private func compactLayout(windowSize: CGSize) -> some View {
        let mainFont = adaptiveMainFontSize(for: windowSize.width)
        let translationFont = adaptiveTranslationFontSize(for: windowSize.width)

        if let lyrics = currentLyrics {
            lyricsContent(lyrics: lyrics, mainFontSize: mainFont, translationFontSize: translationFont)
        } else {
            noLyricsView
        }
    }

    // MARK: - Album Cover

    @ViewBuilder
    private func albumCoverView(size: CGFloat) -> some View {
        if let artwork {
            Image(nsImage: artwork)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 10)
        } else {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.1))
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.3))
                        .foregroundStyle(Color.white.opacity(0.3))
                }
        }
    }

    // MARK: - Track Info

    @ViewBuilder
    private func trackInfoView(maxWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(trackTitle ?? "—")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.white)
                .lineLimit(1)

            Text(trackArtist ?? "—")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.6))
                .lineLimit(1)
        }
        .frame(maxWidth: maxWidth, alignment: .leading)
    }

    // MARK: - Progress Bar

    @ViewBuilder
    private func progressBarView(width: CGFloat) -> some View {
        let duration = trackDuration ?? 0
        let progress = duration > 0 ? min(1, max(0, playbackTime / duration)) : 0

        VStack(spacing: 4) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.3))
                        .frame(height: 4)

                    Capsule()
                        .fill(Color.white)
                        .frame(width: geometry.size.width * progress, height: 4)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard duration > 0 else { return }
                            let fraction = max(0, min(1, value.location.x / geometry.size.width))
                            selectedPlayer.playbackTime = fraction * duration
                        }
                )
            }
            .frame(height: 4)

            HStack {
                Text(formatTime(playbackTime))
                Spacer()
                Text("-\(formatTime(max(0, duration - playbackTime)))")
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(Color.white.opacity(0.6))
        }
        .frame(width: width)
    }

    // MARK: - Playback Controls

    private var playbackControlsView: some View {
        HStack(spacing: 32) {
            Button {
                if selectedPlayer.playbackTime > 5 {
                    selectedPlayer.playbackTime = 0
                } else {
                    selectedPlayer.skipToPreviousItem()
                }
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 20))
            }

            Button {
                selectedPlayer.playPause()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 28))
            }

            Button {
                selectedPlayer.skipToNextItem()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 20))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.white)
    }

    // MARK: - Lyrics Content

    @ViewBuilder
    private func lyricsContent(lyrics: Lyrics, mainFontSize: CGFloat, translationFontSize: CGFloat) -> some View {
        AppleMusicLyricsScrollView(
            lyrics: lyrics,
            highlightedLineIndex: currentLineIndex,
            playbackTime: playbackTime,
            karaokeMode: karaokeMode,
            interactionState: interactionState,
            mainFontSize: mainFontSize,
            translationFontSize: translationFontSize,
            onSeek: { time in
                selectedPlayer.playbackTime = time - (lyrics.adjustedTimeDelay)
            }
        )
    }

    // MARK: - No Lyrics

    private var noLyricsView: some View {
        Text("No Lyrics")
            .font(.system(size: 24, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.4))
    }

    // MARK: - Artwork & Track Info

    private func refreshArtwork() {
        if let trackArtwork = selectedPlayer.currentTrack?.artwork {
            artwork = trackArtwork
        }
    }

    private func refreshTrackInfo() {
        trackTitle = selectedPlayer.currentTrack?.title
        trackArtist = selectedPlayer.currentTrack?.artist
        trackDuration = selectedPlayer.currentTrack?.duration
    }

    // MARK: - Time Formatting

    private func formatTime(_ time: TimeInterval) -> String {
        let totalSeconds = Int(max(0, time))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: - Interaction Button

    @ViewBuilder
    private var interactionButton: some View {
        Button {
            interactionState.toggleIsolation()
        } label: {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 36, height: 36)

                if interactionState.state == .countingDown {
                    Circle()
                        .trim(from: 0, to: interactionState.delegationProgress)
                        .stroke(Color.white.opacity(0.6), lineWidth: 2)
                        .frame(width: 36, height: 36)
                        .rotationEffect(.degrees(-90))
                }

                Image(systemName: interactionState.state == .isolated ? "lock.fill" : "arrow.down.to.line")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.8))
            }
        }
        .buttonStyle(.plain)
        .opacity(interactionState.isDelegated ? 1.0 : 0.0)
        .animation(.smooth(duration: 0.3), value: interactionState.isDelegated)
    }
}
