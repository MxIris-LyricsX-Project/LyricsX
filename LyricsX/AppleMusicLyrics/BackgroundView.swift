import SwiftUI

@available(macOS 15, *)
struct BackgroundView: View {

    var artwork: NSImage?
    var backgroundMode: Int  // 0 = artwork blur, 1 = dark, 2 = system

    var body: some View {
        switch backgroundMode {
        case 0:
            artworkBlurBackground
        case 2:
            systemMaterialBackground
        default:
            darkBackground
        }
    }

    @ViewBuilder
    private var artworkBlurBackground: some View {
        if let artwork {
            Image(nsImage: artwork)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .blur(radius: 80)
                .saturation(1.5)
                .overlay(Color.black.opacity(0.4))
                .clipped()
        } else {
            darkBackground
        }
    }

    private var darkBackground: some View {
        Color.black
    }

    private var systemMaterialBackground: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .environment(\.colorScheme, .dark)
    }
}
