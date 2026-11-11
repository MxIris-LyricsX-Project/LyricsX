import simd

extension AppleMusicLyrics {
    /// Mirrors `NowPlayingRotationInstance` in `ArtworkGradientShaders.metal`
    /// field for field; 80 bytes, 16-byte aligned.
    struct NowPlayingRotationInstanceUniforms {
        var modelMatrix: simd_float4x4
        var timeScale: Float
        var rotationReferenceInstance: Int32
        var padding: SIMD2<Float> = .zero

        init(_ instance: NowPlayingBackdropConfiguration.RotationInstance) {
            self.modelMatrix = instance.modelMatrix
            self.timeScale = instance.timeScale
            self.rotationReferenceInstance = instance.rotationReferenceInstance
        }
    }

    /// Mirrors `NowPlayingColorGrading` in the shader; 32 bytes.
    struct NowPlayingColorGradingUniforms {
        var redStrength: Float
        var redSpill: Float
        var blueStrength: Float
        var blueSpill: Float
        var plateauEnd: Float
        var falloffEnd: Float
        var secondaryDarkening: Float
        var mix: Float

        init(_ colorGrading: NowPlayingBackdropConfiguration.ColorGrading) {
            self.redStrength = colorGrading.redStrength
            self.redSpill = colorGrading.redSpill
            self.blueStrength = colorGrading.blueStrength
            self.blueSpill = colorGrading.blueSpill
            self.plateauEnd = colorGrading.plateauEnd
            self.falloffEnd = colorGrading.falloffEnd
            self.secondaryDarkening = colorGrading.secondaryDarkening
            self.mix = colorGrading.mix
        }
    }

    /// Mirrors `NowPlayingBackdropUniforms` in the shader; 384 bytes. The
    /// order and padding are what makes the Swift and Metal layouts agree, and
    /// `NowPlayingBackdropUniformsTests` pins every offset.
    struct NowPlayingBackdropUniforms {
        var viewMatrix: simd_float4x4
        var rotationInstances: (
            NowPlayingRotationInstanceUniforms,
            NowPlayingRotationInstanceUniforms,
            NowPlayingRotationInstanceUniforms
        )
        var time: Float
        var crossfadeProgress: Float
        var meshProgress: Float
        var pinchMix: Float
        var saturation: Float
        var whiteMix: Float
        var darken: Float
        var padding: Float = 0
        var spectrum: SIMD4<Float>
        var colorGrading: NowPlayingColorGradingUniforms
    }
}
