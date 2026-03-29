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

    private let playbackTimerPublisher = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    private var backgroundMode: Int {
        defaults[.appleMusicLyricsBackgroundMode]
    }

    var body: some View {
        ZStack {
            BackgroundView(artwork: artwork, backgroundMode: backgroundMode)
                .ignoresSafeArea()

            GeometryReader { geometry in
                let isWideEnough = geometry.size.width > 500

                if isWideEnough {
                    wideLayout(windowSize: geometry.size)
                } else {
                    compactLayout
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
        }
        .onReceive(playbackTimerPublisher) { _ in
            playbackTime = selectedPlayer.playbackTime
            if artwork == nil {
                refreshArtwork()
            }
        }
    }

    // MARK: - Wide Layout (cover left, lyrics right)

    @ViewBuilder
    private func wideLayout(windowSize: CGSize) -> some View {
        let coverSize = min(windowSize.height * 0.55, windowSize.width * 0.35, 320)

        HStack(spacing: 0) {
            // Left: Album cover
            VStack {
                Spacer()
                albumCoverView(size: coverSize)
                Spacer()
            }
            .frame(width: coverSize + 60)
            .padding(.leading, 30)

            // Right: Lyrics
            if let lyrics = currentLyrics {
                lyricsContent(lyrics: lyrics)
            } else {
                noLyricsView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Compact Layout (lyrics only, for narrow windows)

    @ViewBuilder
    private var compactLayout: some View {
        if let lyrics = currentLyrics {
            lyricsContent(lyrics: lyrics)
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

    // MARK: - Lyrics Content

    @ViewBuilder
    private func lyricsContent(lyrics: Lyrics) -> some View {
        AppleMusicLyricsScrollView(
            lyrics: lyrics,
            highlightedLineIndex: currentLineIndex,
            playbackTime: playbackTime,
            karaokeMode: karaokeMode,
            interactionState: interactionState,
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

    // MARK: - Artwork

    private func refreshArtwork() {
        if let trackArtwork = selectedPlayer.currentTrack?.artwork {
            artwork = trackArtwork
        }
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
