import SwiftUI
import Combine
import LyricsXFoundation
import MusicPlayer

@available(macOS 15, *)
extension AppleMusicLyrics {
    struct RootView: View {
        @State private var currentLyrics: Lyrics?
        @State private var currentLineIndex: Int?
        @State private var playbackTimeModel = PlaybackTimeModel()
        @State private var artwork: NSImage?
        @State private var interactionState = InteractionStateModel()
        @State private var karaokeMode: KaraokeMode = .characterLevel
        @State private var trackTitle: String?
        @State private var trackArtist: String?
        @State private var trackDuration: TimeInterval?
        @State private var isPlaying: Bool = false
        @State private var currentTrackID: String?
        @State private var lastArtworkFetchAttemptTime: Date = .distantPast

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
                let newTrackID = selectedPlayer.currentTrack?.id
                if newTrackID != currentTrackID {
                    currentTrackID = newTrackID
                    artwork = nil
                    lastArtworkFetchAttemptTime = .distantPast
                }
                refreshArtwork()
                refreshTrackInfo()
            }
            .onReceive(playbackTimerPublisher) { _ in
                playbackTimeModel.playbackTime = selectedPlayer.playbackTime
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
            let leadingInset = max(40, windowSize.width * 0.065)
            let columnSpacing = max(40, windowSize.width * 0.1)
            let coverSize = max(150, min(windowSize.width * 0.285, windowSize.height - 260))
            let mainFont = adaptiveMainFontSize(for: windowSize.width)
            let translationFont = adaptiveTranslationFontSize(for: windowSize.width)

            HStack(spacing: columnSpacing) {
                // Left: Album cover + track info + controls
                VStack(spacing: 0) {
                    Spacer(minLength: 40)

                    albumCoverView(size: coverSize)

                    Spacer().frame(height: 20)

                    trackInfoView(maxWidth: coverSize)

                    Spacer().frame(height: 16)

                    ProgressBarView(
                        playbackTimeModel: playbackTimeModel,
                        trackDuration: trackDuration,
                        width: coverSize
                    )

                    Spacer().frame(height: 16)

                    playbackControlsView

                    Spacer(minLength: 40)
                }
                .frame(width: coverSize)
                .padding(.leading, leadingInset)

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

        // MARK: - Playback Controls

        private var playbackControlsView: some View {
            HStack(spacing: 32) {
                ControlButton(systemImage: "backward.fill", iconSize: 20) {
                    if selectedPlayer.playbackTime > 5 {
                        selectedPlayer.playbackTime = 0
                    } else {
                        selectedPlayer.skipToPreviousItem()
                    }
                }

                ControlButton(systemImage: isPlaying ? "pause.fill" : "play.fill", iconSize: 28) {
                    selectedPlayer.playPause()
                }

                ControlButton(systemImage: "forward.fill", iconSize: 20) {
                    selectedPlayer.skipToNextItem()
                }
            }
            .foregroundStyle(Color.white)
        }

        private struct ControlButton: View {
            var systemImage: String
            var iconSize: CGFloat
            var action: () -> Void

            @State private var isHovering: Bool = false

            var body: some View {
                Button(action: action) {
                    Image(systemName: systemImage)
                        .font(.system(size: iconSize))
                        .frame(width: iconSize * 2, height: iconSize * 2)
                        .background {
                            Circle()
                                .fill(Color.white.opacity(isHovering ? 0.15 : 0))
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isHovering = hovering
                }
                .animation(.smooth(duration: 0.18), value: isHovering)
            }
        }

        // MARK: - Lyrics Content

        private func lyricsContent(lyrics: Lyrics, mainFontSize: CGFloat, translationFontSize: CGFloat) -> some View {
            LyricsScrollView(
                lyrics: lyrics,
                highlightedLineIndex: currentLineIndex,
                playbackTimeModel: playbackTimeModel,
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
            // Fast path: struct's cached artwork (no IPC overhead)
            if let trackArtwork = selectedPlayer.currentTrack?.artwork {
                artwork = trackArtwork
                return
            }
            // Slow path: SBObject KVC fallback, throttled to at most once per second
            let now = Date()
            guard now.timeIntervalSince(lastArtworkFetchAttemptTime) >= 1.0 else { return }
            lastArtworkFetchAttemptTime = now
            if let trackArtwork = selectedPlayer.currentTrack?.resolvedArtwork {
                artwork = trackArtwork
            }
        }

        private func refreshTrackInfo() {
            trackTitle = selectedPlayer.currentTrack?.title
            trackArtist = selectedPlayer.currentTrack?.artist
            trackDuration = selectedPlayer.currentTrack?.duration
        }

        // MARK: - Interaction Button

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

    // MARK: - Progress Bar (isolated observation scope for 30fps playback time updates)

    struct ProgressBarView: View {
        var playbackTimeModel: PlaybackTimeModel
        var trackDuration: TimeInterval?
        var width: CGFloat

        var body: some View {
            let duration = trackDuration ?? 0
            let progress = duration > 0 ? min(1, max(0, playbackTimeModel.playbackTime / duration)) : 0

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
                    Text(Self.formatTime(playbackTimeModel.playbackTime))
                    Spacer()
                    Text("-\(Self.formatTime(max(0, duration - playbackTimeModel.playbackTime)))")
                }
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.6))
            }
            .frame(width: width)
        }

        private static func formatTime(_ time: TimeInterval) -> String {
            let totalSeconds = Int(max(0, time))
            let minutes = totalSeconds / 60
            let seconds = totalSeconds % 60
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}
