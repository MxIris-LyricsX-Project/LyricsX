#include <metal_stdlib>
using namespace metal;

struct ArtworkCompositionVertexOutput {
    float4 position [[position]];
    float2 textureCoordinate;
};

struct ArtworkBackdropMeshVertex {
    float2 clipSpacePosition;
    float2 destinationClipSpacePosition;
    float2 textureCoordinate;
};

struct ArtworkBackdropMeshVertexOutput {
    float4 position [[position]];
    float2 textureCoordinate;
};

constant float2 artworkBackdropClipSpacePositions[6] = {
    float2(-1.0, -1.0),
    float2(-1.0, 1.0),
    float2(1.0, 1.0),
    float2(-1.0, -1.0),
    float2(1.0, 1.0),
    float2(1.0, -1.0),
};

constant float2 artworkBackdropInstanceTranslations[3] = {
    float2(0.0, 0.0),
    float2(-0.5, 0.7),
    float2(-0.95, -0.7),
};

constant float artworkBackdropRotationPeriods[3] = {60.0, 45.0, 35.0};

float2 artworkBackdropRotateClockwise(float2 position, float rotationSine, float rotationCosine) {
    return float2(
        position.x * rotationCosine + position.y * rotationSine,
        position.y * rotationCosine - position.x * rotationSine
    );
}

vertex ArtworkCompositionVertexOutput artworkBackdropCompositionVertex(
    uint vertexIdentifier [[vertex_id]],
    uint instanceIdentifier [[instance_id]],
    constant float4 &compositionParameters [[buffer(0)]]
) {
    float2 clipSpacePosition = artworkBackdropClipSpacePositions[vertexIdentifier];
    float2 textureCoordinate = clipSpacePosition * 0.5 + 0.5;
    textureCoordinate.y = 1.0 - textureCoordinate.y;
    float rotationAngle = compositionParameters.y * (M_PI_F * 2.0)
        / artworkBackdropRotationPeriods[instanceIdentifier];
    float rotationSine = sin(rotationAngle);
    float rotationCosine = cos(rotationAngle);
    // Music applies view * rotation * model translation * rotation.
    float2 artworkPosition = artworkBackdropRotateClockwise(
        clipSpacePosition,
        rotationSine,
        rotationCosine
    );
    artworkPosition += artworkBackdropInstanceTranslations[instanceIdentifier];
    artworkPosition = artworkBackdropRotateClockwise(
        artworkPosition,
        rotationSine,
        rotationCosine
    );
    artworkPosition.y *= compositionParameters.x;

    ArtworkCompositionVertexOutput output;
    output.position = float4(artworkPosition, 0.0, 1.0);
    output.textureCoordinate = textureCoordinate;
    return output;
}

fragment float4 artworkBackdropCompositionFragment(
    ArtworkCompositionVertexOutput input [[stage_in]],
    texture2d<float> sourceTexture [[texture(0)]],
    texture2d<float> destinationTexture [[texture(1)]],
    constant float4 &compositionParameters [[buffer(0)]]
) {
    constexpr sampler artworkSampler(
        address::clamp_to_edge,
        filter::linear,
        mip_filter::linear
    );
    float4 sourceColor = sourceTexture.sample(
        artworkSampler,
        input.textureCoordinate
    );
    float4 destinationColor = destinationTexture.sample(
        artworkSampler,
        input.textureCoordinate
    );
    float3 artworkColor = mix(
        sourceColor,
        destinationColor,
        clamp(compositionParameters.z, 0.0, 1.0)
    ).rgb;
    float luminosity = dot(artworkColor, float3(0.3, 0.59, 0.11));
    return float4(mix(float3(luminosity), artworkColor, compositionParameters.w), 1.0);
}

vertex ArtworkBackdropMeshVertexOutput artworkBackdropMeshVertex(
    const device ArtworkBackdropMeshVertex *vertices [[buffer(0)]],
    constant float4 &motionParameters [[buffer(1)]],
    uint vertexIdentifier [[vertex_id]]
) {
    ArtworkBackdropMeshVertex meshVertex = vertices[vertexIdentifier];
    float elapsedTime = motionParameters.x;
    float warpPhase = elapsedTime * M_PI_F / motionParameters.y;
    float interpolationPosition = acos(clamp(sin(warpPhase), -1.0, 1.0)) / M_PI_F;
    float interpolationProgress = smoothstep(0.0, 1.0, interpolationPosition);
    float2 position = mix(
        meshVertex.clipSpacePosition,
        meshVertex.destinationClipSpacePosition,
        interpolationProgress
    );

    ArtworkBackdropMeshVertexOutput output;
    output.position = float4(position, 0.0, 1.0);
    output.textureCoordinate = (meshVertex.textureCoordinate - 0.5) * motionParameters.z + 0.5;
    return output;
}

fragment float4 artworkBackdropFinalFragment(
    ArtworkBackdropMeshVertexOutput input [[stage_in]],
    texture2d<float> blurredArtworkTexture [[texture(0)]],
    constant float4 &appearanceParameters [[buffer(0)]],
    constant float2 &colorRangeParameters [[buffer(1)]]
) {
    constexpr sampler artworkSampler(
        address::clamp_to_edge,
        filter::linear
    );
    float3 artworkColor = blurredArtworkTexture.sample(
        artworkSampler,
        input.textureCoordinate
    ).rgb;
    float luminosity = dot(artworkColor, float3(0.3, 0.59, 0.11));
    float3 saturatedColor = mix(
        float3(luminosity),
        artworkColor,
        appearanceParameters.x
    );
    // Limit highlights before the dark scrim so saturation cannot cancel it.
    saturatedColor = min(saturatedColor, appearanceParameters.w);
    saturatedColor *= 1.0 - clamp(appearanceParameters.y, 0.0, 1.0);
    saturatedColor -= appearanceParameters.z;
    return float4(clamp(saturatedColor, colorRangeParameters.x, colorRangeParameters.y), 1.0);
}

// MARK: - Music 26 Now Playing backdrop (MediaCoreUI.Backdrop.CompositeRenderer)
//
// A port of MediaCoreUI 26.6's `blended_fragment`, `rotation_vertex`,
// `rotation_fragment`, `pinch_vertex` and `pinch_fragment`. The uniform
// layout mirrors `NowPlayingBackdropUniforms` in NowPlayingBackdropUniforms.swift
// field for field; keep both in the same order.

struct NowPlayingQuadVertex {
    float2 position;
    float2 textureCoordinate;
};

struct NowPlayingRotationInstance {
    float4x4 modelMatrix;
    float timeScale;
    int rotationReferenceInstance;
    float2 padding;
};

struct NowPlayingColorGrading {
    float redStrength;
    float redSpill;
    float blueStrength;
    float blueSpill;
    float plateauEnd;
    float falloffEnd;
    float secondaryDarkening;
    float mix;
};

struct NowPlayingBackdropUniforms {
    float4x4 viewMatrix;
    NowPlayingRotationInstance rotationInstances[3];
    float time;
    float crossfadeProgress;
    float meshProgress;
    float pinchMix;
    float saturation;
    float whiteMix;
    float darken;
    float padding;
    float4 spectrum;
    NowPlayingColorGrading colorGrading;
};

struct NowPlayingQuadVertexOutput {
    float4 position [[position]];
    float2 textureCoordinate;
};

struct NowPlayingRotationVertexOutput {
    float4 position [[position]];
    float2 textureCoordinate;
    uint instanceIdentifier [[flat]];
};

struct NowPlayingMeshVertexOutput {
    float4 position [[position]];
    float2 textureCoordinate;
};

vertex NowPlayingQuadVertexOutput nowPlayingQuadVertex(
    const device NowPlayingQuadVertex *vertices [[buffer(0)]],
    uint vertexIdentifier [[vertex_id]]
) {
    NowPlayingQuadVertex quadVertex = vertices[vertexIdentifier];
    NowPlayingQuadVertexOutput output;
    output.position = float4(quadVertex.position, 0.0, 1.0);
    output.textureCoordinate = quadVertex.textureCoordinate;
    return output;
}

// TextureBlender: crossfade the previous cover into the current one.
fragment float4 nowPlayingBlendFragment(
    NowPlayingQuadVertexOutput input [[stage_in]],
    texture2d<float> previousArtworkTexture [[texture(0)]],
    texture2d<float> currentArtworkTexture [[texture(1)]],
    constant NowPlayingBackdropUniforms &uniforms [[buffer(0)]]
) {
    constexpr sampler artworkSampler(address::clamp_to_edge, filter::linear);
    float4 previousColor = previousArtworkTexture.sample(artworkSampler, input.textureCoordinate);
    float4 currentColor = currentArtworkTexture.sample(artworkSampler, input.textureCoordinate);
    return mix(previousColor, currentColor, uniforms.crossfadeProgress);
}

// Music's rotation matrix: the first column is (cos, -sin), so a positive
// angle turns clockwise in the y-up clip space.
float4x4 nowPlayingClockwiseRotation(float angle) {
    float rotationCosine = cos(angle);
    float rotationSine = sin(angle);
    return float4x4(
        float4(rotationCosine, -rotationSine, 0.0, 0.0),
        float4(rotationSine, rotationCosine, 0.0, 0.0),
        float4(0.0, 0.0, 1.0, 0.0),
        float4(0.0, 0.0, 0.0, 1.0)
    );
}

// RotatingArtworkRenderer vertex:
// position = skew × view' × model × rotation(time / timeScale) × vertex,
// where view' also turns with the reference instance's angle when one is set.
vertex NowPlayingRotationVertexOutput nowPlayingRotationVertex(
    const device NowPlayingQuadVertex *vertices [[buffer(0)]],
    constant NowPlayingBackdropUniforms &uniforms [[buffer(1)]],
    uint vertexIdentifier [[vertex_id]],
    uint instanceIdentifier [[instance_id]]
) {
    NowPlayingQuadVertex quadVertex = vertices[vertexIdentifier];
    NowPlayingRotationInstance instance = uniforms.rotationInstances[instanceIdentifier];
    float angularTime = uniforms.time * (M_PI_F * 2.0);

    float4x4 viewMatrix = uniforms.viewMatrix;
    if (instance.rotationReferenceInstance >= 0) {
        float referenceTimeScale = uniforms.rotationInstances[instance.rotationReferenceInstance].timeScale;
        viewMatrix = viewMatrix * nowPlayingClockwiseRotation(angularTime / referenceTimeScale);
    }

    float spectrumMix = mix(uniforms.spectrum.x, uniforms.spectrum.y, 0.1);
    float skew = 1.0 + 0.33 * spectrumMix * spectrumMix;
    float4x4 skewMatrix = float4x4(
        float4(skew, 0.0, 0.0, 0.0),
        float4(0.0, skew, 0.0, 0.0),
        float4(0.0, 0.0, 1.0, 0.0),
        float4(0.0, 0.0, 0.0, 1.0)
    );
    float4x4 transform = skewMatrix * viewMatrix * instance.modelMatrix
        * nowPlayingClockwiseRotation(angularTime / instance.timeScale);

    NowPlayingRotationVertexOutput output;
    output.position = transform * float4(quadVertex.position, 0.0, 1.0);
    output.textureCoordinate = quadVertex.textureCoordinate;
    output.instanceIdentifier = instanceIdentifier;
    return output;
}

// RotatingArtworkRenderer fragment: darken (a little more per instance),
// contrast and saturate in gamma space. Values may leave 0...1; the half-float
// canvas keeps them until the LUT stage clamps.
fragment float4 nowPlayingRotationFragment(
    NowPlayingRotationVertexOutput input [[stage_in]],
    texture2d<float> artworkTexture [[texture(0)]],
    constant NowPlayingBackdropUniforms &uniforms [[buffer(0)]]
) {
    constexpr sampler artworkSampler(address::clamp_to_edge, filter::linear);
    float3 color = artworkTexture.sample(artworkSampler, input.textureCoordinate).rgb;

    float darken = uniforms.darken + float(input.instanceIdentifier) * 0.0075;
    color = mix(color, float3(0.0), darken);
    color = (color - 0.5) * (1.0 + uniforms.spectrum.x * 0.076) + 0.5;

    float saturation = uniforms.saturation + uniforms.spectrum.z * 0.166;
    float3x3 saturationMatrix = float3x3(
        float3(0.213 + 0.787 * saturation, 0.213 - 0.213 * saturation, 0.213 - 0.213 * saturation),
        float3(0.715 - 0.715 * saturation, 0.715 + 0.285 * saturation, 0.715 - 0.715 * saturation),
        float3(0.072 - 0.072 * saturation, 0.072 - 0.072 * saturation, 0.072 + 0.928 * saturation)
    );
    return float4(saturationMatrix * color, 1.0);
}

// PinchRenderer vertex: blend the source and destination surfaces by the mesh
// progress, then blend that against the unwarped grid by pinchMix.
vertex NowPlayingMeshVertexOutput nowPlayingPinchVertex(
    const device ArtworkBackdropMeshVertex *vertices [[buffer(0)]],
    constant NowPlayingBackdropUniforms &uniforms [[buffer(1)]],
    uint vertexIdentifier [[vertex_id]]
) {
    ArtworkBackdropMeshVertex meshVertex = vertices[vertexIdentifier];
    float2 warpedPosition = mix(
        meshVertex.clipSpacePosition,
        meshVertex.destinationClipSpacePosition,
        uniforms.meshProgress
    );
    float2 plainPosition = (meshVertex.textureCoordinate - 0.5) * (2.0 + 0.5 * (1.0 - uniforms.pinchMix));
    float2 position = mix(plainPosition, warpedPosition, uniforms.pinchMix);

    NowPlayingMeshVertexOutput output;
    output.position = float4(position, 0.0, 1.0);
    output.textureCoordinate = meshVertex.textureCoordinate;
    return output;
}

float nowPlayingGradingHueWeight(float hue, constant NowPlayingColorGrading &grading) {
    return clamp((grading.falloffEnd - hue) / (grading.falloffEnd - grading.plateauEnd), 0.0, 1.0);
}

// Analytic stand-in for Music's BackdropLUT: identity except for saturated
// reds and blues, which lose part of their dominant channel and darken their
// secondary channel most between the primary and the neighbouring hue.
float3 nowPlayingGradeColor(float3 color, constant NowPlayingColorGrading &grading) {
    float minimumComponent = min(color.r, min(color.g, color.b));
    float3 graded = color;

    if (color.r >= color.g && color.r >= color.b) {
        float chroma = color.r - minimumComponent;
        float secondary = max(color.g, color.b);
        float hue = chroma > 0.0001 ? (secondary - minimumComponent) / chroma : 0.0;
        float weight = nowPlayingGradingHueWeight(hue, grading);
        float reduction = grading.redStrength * chroma * weight;
        graded += reduction * float3(-1.0, grading.redSpill, grading.redSpill);
        float secondaryReduction = grading.secondaryDarkening * chroma * hue * (1.0 - hue) * 4.0 * weight;
        if (color.g >= color.b) {
            graded.g -= secondaryReduction * color.g;
        } else {
            graded.b -= secondaryReduction * color.b;
        }
    }

    if (color.b >= color.r && color.b >= color.g) {
        float chroma = color.b - minimumComponent;
        float secondary = max(color.r, color.g);
        float hue = chroma > 0.0001 ? (secondary - minimumComponent) / chroma : 0.0;
        float weight = nowPlayingGradingHueWeight(hue, grading);
        float reduction = grading.blueStrength * chroma * weight;
        graded += reduction * float3(grading.blueSpill, grading.blueSpill, -1.0);
        float secondaryReduction = grading.secondaryDarkening * chroma * hue * (1.0 - hue) * 4.0 * weight;
        if (color.r >= color.g) {
            graded.r -= secondaryReduction * color.r;
        } else {
            graded.g -= secondaryReduction * color.g;
        }
    }

    return clamp(graded, 0.0, 1.0);
}

// PinchRenderer fragment: undo the premultiplied darkening the blur pulled in
// from the transparent canvas edge, lift towards white, then grade. Music
// samples a 32³ LUT here, whose sampler clamps the colour to 0...1 first.
fragment float4 nowPlayingPinchFragment(
    NowPlayingMeshVertexOutput input [[stage_in]],
    texture2d<float> blurredCanvasTexture [[texture(0)]],
    constant NowPlayingBackdropUniforms &uniforms [[buffer(0)]]
) {
    constexpr sampler canvasSampler(address::clamp_to_edge, filter::linear);
    float4 canvas = blurredCanvasTexture.sample(canvasSampler, input.textureCoordinate);
    float3 color = canvas.rgb / max(canvas.a, 0.0001);
    color = mix(color, float3(1.0), uniforms.whiteMix);
    color = clamp(color, 0.0, 1.0);
    float3 graded = nowPlayingGradeColor(color, uniforms.colorGrading);
    return float4(mix(color, graded, uniforms.colorGrading.mix), 1.0);
}
