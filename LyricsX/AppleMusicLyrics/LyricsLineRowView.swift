import SwiftUI
import LyricsXFoundation
import OpenCC

@available(macOS 15, *)
struct LyricsLineRowView: View {

    var line: LyricsLine
    var index: Int
    var isHighlighted: Bool
    var highlightedIndex: Int
    var elapsedTime: TimeInterval     // seconds since this line started
    var lineDuration: TimeInterval    // this line's duration
    var karaokeMode: KaraokeMode
    var mainFontSize: CGFloat
    var translationFontSize: CGFloat
    var onTap: () -> Void

    @State private var isActive: Bool = false
    @State private var isHovering: Bool = false
    private let highlightReleasingDelay: TimeInterval = 0.25

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4) {
                mainLyricsView
                translationView
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 28)
            .padding(.horizontal, 24)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
        .opacity(fadingOpacity)
        .blur(radius: fadingBlur)
        .brightness(isActive ? 0.5 : 0)
        .animation(.smooth(duration: 0.8), value: isActive)
        .onChange(of: isHighlighted, initial: true) { _, newValue in
            withAnimation(newValue
                ? .smooth(duration: 0.8)
                : .smooth(duration: 0.8).delay(highlightReleasingDelay)
            ) {
                isActive = newValue
            }
        }
    }

    // MARK: - Main Lyrics

    @ViewBuilder
    private var mainLyricsView: some View {
        let hasKaraoke = line.wordTimingEntries != nil && isHighlighted
        if hasKaraoke {
            let renderer = LyricsTextRenderer(
                elapsedTime: elapsedTime,
                lineDuration: lineDuration,
                wordTimings: line.wordTimingEntries ?? [],
                contentLength: line.content.count,
                mode: karaokeMode
            )
            Text(line.content)
                .font(.system(size: mainFontSize, weight: .bold))
                .textRenderer(renderer)
        } else {
            Text(line.content)
                .font(.system(size: mainFontSize, weight: .bold))
                .foregroundStyle(Color.white)
        }
    }

    // MARK: - Translation

    @ViewBuilder
    private var translationView: some View {
        if defaults[.preferBilingualLyrics],
           let translation = line.attachments.translation() {
            let displayText: String = {
                if let converter = ChineseConverter.shared {
                    return converter.convert(translation)
                }
                return translation
            }()
            Text(displayText)
                .font(.system(size: translationFontSize, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.7))
        }
    }

    // MARK: - Fading Effect

    private var shouldFade: Bool {
        !isActive && !isHovering
    }

    private var distance: Int {
        abs(index - highlightedIndex)
    }

    private var fadingOpacity: Double {
        guard shouldFade else { return 1.0 }
        let factor = 0.55 - Double(distance) * 0.05
        return max(0.125, min(factor, 0.55))
    }

    private var fadingBlur: CGFloat {
        guard shouldFade else { return 0 }
        let factor = CGFloat(distance) * 1.0
        return max(1.0, min(factor, 6.0))
    }
}
