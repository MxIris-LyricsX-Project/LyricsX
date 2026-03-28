import SwiftUI
import LyricsXWidgetShared

struct LyricsLineView: View {
    let line: LyricsLineEntry
    let isHighlighted: Bool
    let showTranslation: Bool
    let translationLanguage: String?

    var body: some View {
        VStack(spacing: 2) {
            Text(line.text)
                .font(.system(size: isHighlighted ? 18 : 14, weight: isHighlighted ? .bold : .medium))
                .foregroundStyle(.white.opacity(isHighlighted ? 1.0 : 0.4))
                .lineLimit(2)
                .multilineTextAlignment(.center)

            if showTranslation, let translation = line.translation, !translation.isEmpty {
                Text(translation)
                    .font(.system(size: isHighlighted ? 14 : 11, weight: .regular))
                    .foregroundStyle(.white.opacity(isHighlighted ? 0.8 : 0.3))
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
            }
        }
    }
}
