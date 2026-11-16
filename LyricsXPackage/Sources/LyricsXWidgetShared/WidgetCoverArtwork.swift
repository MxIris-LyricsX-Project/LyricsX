import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The cover the widget shows and the colour behind it, prepared from a
/// track's artwork.
///
/// Everything is drawn on the CPU into 8-bit sRGB bitmaps, so the JPEG encoder
/// only ever sees standard-range pixels. The app used to resize the cover
/// through `NSImage.lockFocus`, which hands back an extended-range half-float
/// bitmap; ImageIO then tone-mapped it on the GPU through its Metal HDR
/// converter before writing the JPEG, which took about 400 MB of GPU memory
/// for one 400-pixel cover on a Mac Studio M3 Ultra.
public struct WidgetCoverArtwork: Equatable, Sendable {
    /// The longest side of the cover file, in pixels: 200 points at 2×, the
    /// size the file has always had. Smaller artwork keeps its own size.
    public static let maximumPixelDimension = 400

    static let compressionQuality = 0.7

    /// How much of the cover's colour the widget's background keeps.
    static let backgroundBrightness = 0.6

    /// The cover file, a JPEG.
    public let jpegData: Data
    /// The cover's colour, darkened, for the widget's background.
    public let backgroundColor: CodableColor?

    public init?(artwork: CGImage) {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let thumbnail = Self.thumbnail(of: artwork, colorSpace: colorSpace),
              let jpegData = Self.jpegData(of: thumbnail)
        else {
            return nil
        }
        self.jpegData = jpegData
        self.backgroundColor = Self.backgroundColor(of: thumbnail, colorSpace: colorSpace)
    }

    /// `artwork` drawn into an opaque 8-bit sRGB bitmap no larger than
    /// `maximumPixelDimension` on its longest side.
    private static func thumbnail(of artwork: CGImage, colorSpace: CGColorSpace) -> CGImage? {
        let longestSide = max(artwork.width, artwork.height)
        guard longestSide > 0 else { return nil }
        let scale = min(1, Double(maximumPixelDimension) / Double(longestSide))
        let width = max(1, Int((Double(artwork.width) * scale).rounded()))
        let height = max(1, Int((Double(artwork.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(artwork, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func jpegData(of thumbnail: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        let properties = [kCGImageDestinationLossyCompressionQuality: compressionQuality] as CFDictionary
        CGImageDestinationAddImage(destination, thumbnail, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// The thumbnail scaled down to a single pixel, darkened.
    private static func backgroundColor(of thumbnail: CGImage, colorSpace: CGColorSpace) -> CodableColor? {
        var pixel = [UInt8](repeating: 0, count: 4)
        let didDraw = pixel.withUnsafeMutableBytes { pixelBytes -> Bool in
            guard let context = CGContext(
                data: pixelBytes.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .medium
            context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard didDraw else { return nil }
        return CodableColor(
            red: Double(pixel[0]) / 255 * backgroundBrightness,
            green: Double(pixel[1]) / 255 * backgroundBrightness,
            blue: Double(pixel[2]) / 255 * backgroundBrightness,
            alpha: Double(pixel[3]) / 255
        )
    }
}

/// Keeps the cover prepared for the playing track, because the app writes the
/// widget's snapshot on every lyric line.
///
/// A cover belongs to a track and to the artwork's size in pixels. Players
/// hand over a new image object with every update, so the object cannot tell
/// whether the artwork changed; artwork that arrives later in another size
/// for the same track is prepared again.
public struct WidgetCoverArtworkCache: Sendable {
    private struct Key: Equatable, Sendable {
        let trackIdentifier: String
        let pixelWidth: Int
        let pixelHeight: Int
    }

    private var preparedKey: Key?
    private var preparedCover: WidgetCoverArtwork?

    public init() {}

    /// The cover for `artwork` of the track `trackIdentifier`, prepared only
    /// when the track or the artwork's size differs from the last call's. A
    /// cover that could not be prepared is tried again next time.
    public mutating func artwork(for artwork: CGImage, trackIdentifier: String) -> WidgetCoverArtwork? {
        let key = Key(trackIdentifier: trackIdentifier, pixelWidth: artwork.width, pixelHeight: artwork.height)
        if key == preparedKey, let preparedCover {
            return preparedCover
        }
        guard let cover = WidgetCoverArtwork(artwork: artwork) else { return nil }
        preparedKey = key
        preparedCover = cover
        return cover
    }
}
