import CoreGraphics
import SwiftUI
import WidgetKit

/// The dark fade the small widget lays over the bottom of its cover so the
/// white title stays readable, drawn as an image rather than a gradient.
///
/// On macOS 26 and later the desktop renders widgets in the accented mode
/// whenever it is not focused, and that mode tints every gradient white: a
/// `LinearGradient` scrim turns into a white one under the white title, and
/// the title disappears. An image marked `.fullColor` keeps its colours in
/// that mode, so this fade stays dark in both states.
struct CoverScrimView: View {
    var body: some View {
        if let scrimImage = Self.scrimImage {
            Image(decorative: scrimImage, scale: 1)
                .resizable()
                .widgetAccentedRenderingMode(.fullColor)
        }
    }

    /// One pixel wide; `resizable()` stretches it across the widget.
    private static let scrimImage: CGImage? = makeScrimImage(pixelHeight: 512)

    /// Clear over the top half, then fading to 60 % black at the bottom edge,
    /// the same ramp as
    /// `LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)`.
    private static func makeScrimImage(pixelHeight: Int) -> CGImage? {
        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: 1,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ),
            let gradient = CGGradient(
                colorsSpace: colorSpace,
                colors: [
                    CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0),
                    CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.6),
                ] as CFArray,
                locations: [0, 1]
            )
        else {
            return nil
        }
        let imageHeight = CGFloat(pixelHeight)
        context.clear(CGRect(x: 0, y: 0, width: 1, height: imageHeight))
        // A bitmap context's y axis points up, so y = 0 is the image's bottom
        // row. Nothing is drawn above the start point, which leaves the top
        // half clear.
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: imageHeight / 2),
            end: CGPoint(x: 0, y: 0),
            options: []
        )
        return context.makeImage()
    }
}
