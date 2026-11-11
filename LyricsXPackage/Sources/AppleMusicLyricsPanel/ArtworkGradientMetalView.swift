import AppKit
import MetalKit

extension AppleMusicLyrics {
    final class ArtworkGradientMetalView: MTKView, MTKViewDelegate {
        private let drawableScale: CGFloat
        private let renderer: ArtworkBackdropRenderer
        private var isFrameRenderingAllowed = false
        private var isDrawableResizingSuspended = false

        init(
            frame frameRect: NSRect,
            device metalDevice: MTLDevice,
            pipeline: any ArtworkBackdropFramePipeline,
            drawableScale: CGFloat = 1
        ) throws {
            self.drawableScale = drawableScale
            self.renderer = try ArtworkBackdropRenderer(
                device: metalDevice,
                pipeline: pipeline
            )

            super.init(frame: frameRect, device: metalDevice)

            delegate = self
            framebufferOnly = true
            colorPixelFormat = renderer.drawablePixelFormat
            depthStencilPixelFormat = .invalid
            sampleCount = 1
            preferredFramesPerSecond = ArtworkGradientRenderingPolicy.preferredFramesPerSecond(
                screenMaximumFramesPerSecond: nil
            )
            enableSetNeedsDisplay = false
            autoResizeDrawable = false
            presentsWithTransaction = false
            clearColor = pipeline.clearColor
            colorspace = pipeline.drawableColorSpace
            isPaused = true
            refreshDisplayEnvironment()
            updateDrawableSize()
        }

        @available(*, unavailable)
        required init(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var isOpaque: Bool {
            true
        }

        override func layout() {
            super.layout()
            updateDrawableSize()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            refreshDisplayEnvironment()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            refreshDisplayEnvironment()
            updateDrawableSize()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            refreshDisplayEnvironment()
            requestSingleFrame()
        }

        func setRenderingState(
            isFrameRenderingAllowed: Bool,
            isContinuousRenderingEnabled: Bool
        ) {
            let stateChanged = self.isFrameRenderingAllowed != isFrameRenderingAllowed
                || isPaused == isContinuousRenderingEnabled
            guard stateChanged else { return }

            self.isFrameRenderingAllowed = isFrameRenderingAllowed
            isPaused = !isContinuousRenderingEnabled
            renderer.setRenderingState(
                isFrameRenderingAllowed: isFrameRenderingAllowed,
                isContinuousRenderingEnabled: isContinuousRenderingEnabled,
                preferredFramesPerSecond: preferredFramesPerSecond
            )
        }

        func setPreferredFramesPerSecond(_ framesPerSecond: Int) {
            let normalizedFramesPerSecond = max(1, framesPerSecond)
            guard preferredFramesPerSecond != normalizedFramesPerSecond else { return }

            let previousFramesPerSecond = preferredFramesPerSecond
            preferredFramesPerSecond = normalizedFramesPerSecond
            renderer.setPreferredFramesPerSecond(
                previousFramesPerSecond: previousFramesPerSecond,
                currentFramesPerSecond: normalizedFramesPerSecond
            )
        }

        func setArtworkTexture(
            _ artworkTexture: MTLTexture,
            averageLuminosity: Float,
            animated: Bool
        ) {
            renderer.enqueueArtworkTexture(
                artworkTexture,
                averageLuminosity: averageLuminosity,
                animated: animated
            )
            requestSingleFrame()
        }

        func setFallbackArtwork(animated: Bool) {
            renderer.enqueueFallbackTexture(animated: animated)
            requestSingleFrame()
        }

        func setDrawableResizingSuspended(_ isSuspended: Bool) {
            guard isDrawableResizingSuspended != isSuspended else { return }
            isDrawableResizingSuspended = isSuspended
            if !isSuspended {
                updateDrawableSize()
            }
        }

        func requestSingleFrame() {
            guard isFrameRenderingAllowed, isPaused else { return }
            draw()
        }

        func draw(in view: MTKView) {
            guard isFrameRenderingAllowed else { return }
            renderer.draw(in: view)
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            renderer.drawableSizeWillChange(size)
        }

        private func refreshDisplayEnvironment() {
            let backingScaleFactor = convertToBacking(NSSize(width: 1, height: 1)).width
            let isDarkAppearance = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            renderer.setDisplayEnvironment(
                backingScaleFactor: backingScaleFactor,
                isDarkAppearance: isDarkAppearance
            )
        }

        private func updateDrawableSize() {
            guard !isDrawableResizingSuspended else { return }

            let nativeBackingBounds = convertToBacking(bounds)
            let updatedDrawableSize = ArtworkBackdropDrawableSizing.pixelSize(
                forNativeBackingSize: nativeBackingBounds.size,
                scale: drawableScale
            )
            guard drawableSize != updatedDrawableSize else { return }
            drawableSize = updatedDrawableSize
            if isPaused {
                requestSingleFrame()
            }
        }
    }
}
