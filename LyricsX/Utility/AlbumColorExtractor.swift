import AppKit
import LyricsXWidgetShared

enum AlbumColorExtractor {
    /// Extract the dominant color from an image by scaling it down to 1x1 pixel.
    static func dominantColor(from image: NSImage) -> CodableColor? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let width = 1
        let height = 1
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var pixelData = [UInt8](repeating: 0, count: bytesPerPixel)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: &pixelData,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: bytesPerRow,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let red = Double(pixelData[0]) / 255.0
        let green = Double(pixelData[1]) / 255.0
        let blue = Double(pixelData[2]) / 255.0
        let alpha = Double(pixelData[3]) / 255.0

        // Darken the color slightly for a better background effect
        let darkenFactor = 0.6
        return CodableColor(
            red: red * darkenFactor,
            green: green * darkenFactor,
            blue: blue * darkenFactor,
            alpha: alpha
        )
    }

    /// Compress an NSImage to JPEG data suitable for the widget cover file.
    static func compressedCoverData(from image: NSImage, maxDimension: CGFloat = 200) -> Data? {
        let originalSize = image.size
        let scaleFactor: CGFloat
        if originalSize.width > originalSize.height {
            scaleFactor = maxDimension / originalSize.width
        } else {
            scaleFactor = maxDimension / originalSize.height
        }

        let targetSize = NSSize(
            width: originalSize.width * scaleFactor,
            height: originalSize.height * scaleFactor
        )

        let resizedImage = NSImage(size: targetSize)
        resizedImage.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: NSRect(origin: .zero, size: originalSize),
            operation: .copy,
            fraction: 1.0
        )
        resizedImage.unlockFocus()

        guard let tiffData = resizedImage.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmapRep.representation(
                  using: .jpeg,
                  properties: [.compressionFactor: 0.7]
              ) else {
            return nil
        }

        return jpegData
    }
}
