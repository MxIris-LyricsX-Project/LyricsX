import CoreGraphics
import Foundation

extension AppleMusicLyrics {
    struct PreparedArtworkBackdrop {
        let image: CGImage
        let averageLuminosity: Float
    }

    enum ArtworkBackdropImageProcessor {
        private static let luminositySampleDimension = 32

        static func prepare(
            _ sourceImage: CGImage,
            maximumDimension: Int
        ) -> PreparedArtworkBackdrop? {
            guard maximumDimension > 0,
                  sourceImage.width > 0,
                  sourceImage.height > 0
            else {
                return nil
            }

            let sourceMaximumDimension = max(sourceImage.width, sourceImage.height)
            let preparedImage: CGImage
            if sourceMaximumDimension > maximumDimension {
                let downsampleScale = CGFloat(maximumDimension)
                    / CGFloat(sourceMaximumDimension)
                let destinationWidth = max(
                    1,
                    Int((CGFloat(sourceImage.width) * downsampleScale).rounded())
                )
                let destinationHeight = max(
                    1,
                    Int((CGFloat(sourceImage.height) * downsampleScale).rounded())
                )
                guard let downsampledImage = draw(
                    sourceImage,
                    width: destinationWidth,
                    height: destinationHeight
                ) else {
                    return nil
                }
                preparedImage = downsampledImage
            } else {
                preparedImage = sourceImage
            }

            return PreparedArtworkBackdrop(
                image: preparedImage,
                averageLuminosity: averageLuminosity(of: preparedImage)
            )
        }

        private static func draw(
            _ sourceImage: CGImage,
            width: Int,
            height: Int
        ) -> CGImage? {
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: nil,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width * 4,
                      space: colorSpace,
                      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                          | CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else {
                return nil
            }

            context.interpolationQuality = .high
            context.draw(
                sourceImage,
                in: CGRect(x: 0, y: 0, width: width, height: height)
            )
            return context.makeImage()
        }

        private static func averageLuminosity(of sourceImage: CGImage) -> Float {
            let sampleDimension = luminositySampleDimension
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: nil,
                      width: sampleDimension,
                      height: sampleDimension,
                      bitsPerComponent: 8,
                      bytesPerRow: sampleDimension * 4,
                      space: colorSpace,
                      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                          | CGImageAlphaInfo.premultipliedLast.rawValue
                  ),
                  let pixelData = context.data
            else {
                return 0.5
            }

            context.interpolationQuality = .medium
            context.draw(
                sourceImage,
                in: CGRect(
                    x: 0,
                    y: 0,
                    width: sampleDimension,
                    height: sampleDimension
                )
            )

            let pixelBytes = pixelData.assumingMemoryBound(to: UInt8.self)
            let pixelCount = sampleDimension * sampleDimension
            var luminositySum: Float = 0
            for pixelIndex in 0 ..< pixelCount {
                let pixelByteIndex = pixelIndex * 4
                let redComponent = linearComponent(
                    fromStandardComponent: Float(pixelBytes[pixelByteIndex]) / 255
                )
                let greenComponent = linearComponent(
                    fromStandardComponent: Float(pixelBytes[pixelByteIndex + 1]) / 255
                )
                let blueComponent = linearComponent(
                    fromStandardComponent: Float(pixelBytes[pixelByteIndex + 2]) / 255
                )
                luminositySum += redComponent * 0.2126
                    + greenComponent * 0.7152
                    + blueComponent * 0.0722
            }
            return luminositySum / Float(pixelCount)
        }

        private static func linearComponent(fromStandardComponent component: Float) -> Float {
            if component <= 0.04045 {
                return component / 12.92
            }
            return pow((component + 0.055) / 1.055, 2.4)
        }
    }
}
