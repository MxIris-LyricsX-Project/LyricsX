import Foundation
import Metal
import MetalKit

extension AppleMusicLyrics {
    /// Which Apple Music backdrop the lyrics panel paints behind the lyrics.
    ///
    /// Selected through a hidden user-defaults key and read once when the
    /// panel's background view is created, so `defaults write` takes effect the
    /// next time the panel window is opened.
    enum ArtworkBackdropVariant: String, CaseIterable, Sendable {
        /// Music 26's Now Playing full-window player, drawn by
        /// `MediaCoreUI.Backdrop.CompositeRenderer`: a 128 pixel artwork kept in
        /// gamma space, three rotating copies on a quarter-resolution canvas, a
        /// point-sized Gaussian blur, a subdivided mesh warp, and a white lift
        /// with mild colour grading.
        case mediaCoreUI26
        /// The MiniPlayer large-artwork `TSLBackdropMetalView` the earlier
        /// renderer reproduced, kept without its screenshot calibration so the
        /// two can be compared side by side.
        case legacyTSL

        static let userDefaultsKey = "AppleMusicLyricsBackdropVariant"
        static let `default`: ArtworkBackdropVariant = .mediaCoreUI26

        static func resolve(from userDefaults: UserDefaults = .standard) -> ArtworkBackdropVariant {
            guard let rawValue = userDefaults.string(forKey: userDefaultsKey),
                  let variant = ArtworkBackdropVariant(rawValue: rawValue) else {
                return .default
            }
            return variant
        }

        /// Longest artwork edge handed to the renderer. Music's Now Playing
        /// backdrop redraws the cover to at most 128 pixels; the MiniPlayer
        /// backdrop keeps 300.
        var maximumArtworkDimension: Int {
            switch self {
            case .mediaCoreUI26:
                return NowPlayingBackdropConfiguration().artworkDimension
            case .legacyTSL:
                return ArtworkGradientConfiguration().maximumArtworkDimension
            }
        }

        var artworkAbsenceFallbackDelay: TimeInterval {
            switch self {
            case .mediaCoreUI26:
                return NowPlayingBackdropConfiguration().artworkAbsenceFallbackDelay
            case .legacyTSL:
                return ArtworkGradientConfiguration().artworkAbsenceFallbackDelay
            }
        }

        /// `MediaCoreUI` loads the cover with `SRGB: false` and no mipmaps, so
        /// every stage sees gamma-encoded values; the MiniPlayer pipeline decodes
        /// to linear light and samples mipmaps.
        var artworkTextureLoadingOptions: [MTKTextureLoader.Option: Any] {
            switch self {
            case .mediaCoreUI26:
                return [
                    .SRGB: false,
                    .origin: MTKTextureLoader.Origin.topLeft,
                    .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
                    .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                ]
            case .legacyTSL:
                return [
                    .SRGB: true,
                    .generateMipmaps: true,
                    .origin: MTKTextureLoader.Origin.topLeft,
                    .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
                    .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                ]
            }
        }

        func makePipeline(
            device metalDevice: MTLDevice,
            shaderLibrary: MTLLibrary? = nil
        ) throws -> any ArtworkBackdropFramePipeline {
            switch self {
            case .mediaCoreUI26:
                return try NowPlayingBackdropPipeline(
                    device: metalDevice,
                    configuration: NowPlayingBackdropConfiguration(),
                    shaderLibrary: shaderLibrary
                )
            case .legacyTSL:
                return try ArtworkBackdropPipeline(
                    device: metalDevice,
                    configuration: ArtworkGradientConfiguration(),
                    shaderLibrary: shaderLibrary
                )
            }
        }
    }
}
