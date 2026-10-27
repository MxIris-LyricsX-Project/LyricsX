import AppKit
import MetalKit
import OSToolbox
import UIFoundation

extension AppleMusicLyrics {
    @Loggable(
        isEnabled: AppleMusicLyrics.PanelDiagnostics.isBackdropEnabled,
        subsystem: "com.JH.LyricsX.AppleMusicLyricsPanel.Backdrop",
        category: "GradientRenderer"
    )
    @Signpostable(
        isEnabled: AppleMusicLyrics.PanelDiagnostics.isBackdropEnabled,
        subsystem: "com.JH.LyricsX.AppleMusicLyricsPanel.Backdrop",
        category: "GradientRenderer"
    )
    final class GradientBackgroundView: NSView {
        private let variant: ArtworkBackdropVariant
        private let fallbackView = LayerBackedView()
        private let metalView: ArtworkGradientMetalView?
        private let textureLoader: MTKTextureLoader?
        private let artworkPreparationQueue = DispatchQueue(
            label: "ArtworkBackdropPreparation",
            qos: .userInitiated,
            autoreleaseFrequency: .workItem
        )

        private var requestState = ArtworkGradientRequestState()
        private var artworkAbsenceWorkItem: DispatchWorkItem?
        private var windowOcclusionObserver: NSObjectProtocol?
        private var windowScreenObserver: NSObjectProtocol?
        private var accessibilityDisplayOptionsObserver: NSObjectProtocol?
        private var isPresentationVisible = false
        private var isWindowDragging = false
        private var isPerformingLiveResize = false
        /// Whether the player is playing. The panel's view controller forwards
        /// the host player's state; until it does, the backdrop holds still.
        private var isPlaybackActive = false
        /// Whether the backdrop's destination texture is a track's cover rather
        /// than the grey placeholder.
        private var isShowingArtwork = false

        override init(frame frameRect: NSRect) {
            let variant = ArtworkBackdropVariant.resolve()
            self.variant = variant
            if let metalDevice = MTLCreateSystemDefaultDevice(),
               let pipeline = try? variant.makePipeline(device: metalDevice) {
                self.textureLoader = MTKTextureLoader(device: metalDevice)
                self.metalView = try? ArtworkGradientMetalView(
                    frame: frameRect,
                    device: metalDevice,
                    pipeline: pipeline
                )
            } else {
                self.textureLoader = nil
                self.metalView = nil
            }

            super.init(frame: frameRect)
            configureViewHierarchy()
            observeAccessibilityDisplayOptions()
            let variantName = variant.rawValue
            let hasMetalView = metalView != nil
            #log(
                .info,
                """
                Gradient backdrop variant=\(variantName, privacy: .public) \
                metal=\(hasMetalView, privacy: .public)
                """
            )
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            artworkAbsenceWorkItem?.cancel()
            removeWindowObservations()
            if let accessibilityDisplayOptionsObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(
                    accessibilityDisplayOptionsObserver
                )
            }
        }

        override var isOpaque: Bool {
            true
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            replaceWindowObservations()
            refreshPreferredFramesPerSecond()
            refreshRenderingState()
        }

        override func viewDidHide() {
            super.viewDidHide()
            refreshRenderingState()
        }

        override func viewDidUnhide() {
            super.viewDidUnhide()
            refreshRenderingState()
        }

        override func viewWillStartLiveResize() {
            super.viewWillStartLiveResize()
            isPerformingLiveResize = true
            refreshDrawableResizeSuspension()
            refreshRenderingState()
        }

        override func viewDidEndLiveResize() {
            super.viewDidEndLiveResize()
            isPerformingLiveResize = false
            refreshDrawableResizeSuspension()
            refreshRenderingState()
        }

        func setPresentationVisible(_ isVisible: Bool) {
            guard isPresentationVisible != isVisible else { return }
            isPresentationVisible = isVisible
            refreshRenderingState()
        }

        func setPlaybackActive(_ isActive: Bool) {
            guard isPlaybackActive != isActive else { return }
            isPlaybackActive = isActive
            refreshRenderingState()
        }

        func setWindowDragging(_ isDragging: Bool) {
            guard isWindowDragging != isDragging else { return }
            isWindowDragging = isDragging
            refreshDrawableResizeSuspension()
            refreshRenderingState()
        }

        func update(artwork: NSImage?, trackIdentity: String?) {
            handleTrackChange(artwork: artwork, trackIdentity: trackIdentity)
            guard let artwork,
                  let generation = requestState.beginArtworkRequest()
            else {
                return
            }

            artworkAbsenceWorkItem?.cancel()
            artworkAbsenceWorkItem = nil
            guard let sourceImage = artwork.cgImage(
                forProposedRect: nil,
                context: nil,
                hints: nil
            ), let textureLoader else {
                applyFallbackArtwork()
                return
            }
            prepareArtwork(
                sourceImage,
                generation: generation,
                textureLoader: textureLoader
            )
        }
    }
}

extension AppleMusicLyrics.GradientBackgroundView {
    fileprivate func handleTrackChange(artwork: NSImage?, trackIdentity: String?) {
        guard requestState.observeTrackIdentity(trackIdentity) else { return }

        let hasTrackIdentity = trackIdentity != nil
        let hasArtwork = artwork != nil
        #log(
            .info,
            """
            Gradient track changed hasIdentity=\(hasTrackIdentity, privacy: .public) \
            hasArtwork=\(hasArtwork, privacy: .public)
            """
        )
        #signpost(
            .event,
            "GradientTrackChanged",
            "hasArtwork=\(hasArtwork, privacy: .public)"
        )

        artworkAbsenceWorkItem?.cancel()
        artworkAbsenceWorkItem = nil
        if trackIdentity == nil {
            applyFallbackArtwork()
        } else if artwork == nil {
            scheduleArtworkAbsenceFallback()
        }
    }

    fileprivate func prepareArtwork(
        _ sourceImage: CGImage,
        generation: UInt64,
        textureLoader: MTKTextureLoader
    ) {
        let maximumArtworkDimension = variant.maximumArtworkDimension
        let textureLoadingOptions = variant.artworkTextureLoadingOptions
        let preparationInterval = #signpost(
            .begin,
            "ArtworkBackdropPreparation",
            "generation=\(generation, privacy: .public)"
        )
        artworkPreparationQueue.async { [weak self] in
            let preparedArtwork = AppleMusicLyrics.ArtworkBackdropImageProcessor.prepare(
                sourceImage,
                maximumDimension: maximumArtworkDimension
            )
            let preparedTexture = preparedArtwork.flatMap { preparedArtwork in
                try? textureLoader.newTexture(
                    cgImage: preparedArtwork.image,
                    options: textureLoadingOptions
                )
            }
            let preparationSucceeded = preparedTexture != nil
            #signpost(
                .end,
                preparationInterval,
                "success=\(preparationSucceeded, privacy: .public)"
            )

            DispatchQueue.main.async {
                self?.applyPreparedArtwork(
                    preparedArtwork,
                    texture: preparedTexture,
                    generation: generation
                )
            }
        }
    }

    fileprivate func applyPreparedArtwork(
        _ preparedArtwork: AppleMusicLyrics.PreparedArtworkBackdrop?,
        texture: MTLTexture?,
        generation: UInt64
    ) {
        guard requestState.acceptsResult(generation: generation) else { return }
        guard let preparedArtwork,
              let texture
        else {
            #log(
                .error,
                "Artwork backdrop preparation failed generation=\(generation, privacy: .public)"
            )
            applyFallbackArtwork()
            return
        }

        let textureWidth = texture.width
        let textureHeight = texture.height
        let averageLuminosity = preparedArtwork.averageLuminosity
        #log(
            .info,
            """
            Artwork backdrop applied generation=\(generation, privacy: .public) \
            width=\(textureWidth, privacy: .public) \
            height=\(textureHeight, privacy: .public) \
            luminosity=\(averageLuminosity, privacy: .public)
            """
        )
        #signpost(
            .event,
            "ArtworkBackdropApplied",
            "width=\(textureWidth, privacy: .public) height=\(textureHeight, privacy: .public)"
        )
        // The cover decides whether the backdrop animates at all, so the state
        // goes first: a playing panel resumes its clock before the cross-fade
        // starts on it. A paused one cuts straight to the new cover in a single
        // frame, as Reduce Motion does, because a frozen clock would hold the
        // cross-fade at its first frame.
        isShowingArtwork = true
        refreshRenderingState(requestsSingleFrame: false)
        metalView?.setArtworkTexture(
            texture,
            averageLuminosity: averageLuminosity,
            animated: currentRenderingDecision().shouldRenderContinuously
        )
    }

    fileprivate func configureViewHierarchy() {
        fallbackView.translatesAutoresizingMaskIntoConstraints = false
        fallbackView.backgroundColor = NSColor(
            red: 0.12,
            green: 0.15,
            blue: 0.2,
            alpha: 1
        )
        addSubview(fallbackView)

        var constraints = [
            fallbackView.topAnchor.constraint(equalTo: topAnchor),
            fallbackView.bottomAnchor.constraint(equalTo: bottomAnchor),
            fallbackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            fallbackView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ]
        if let metalView {
            metalView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(metalView)
            constraints.append(contentsOf: [
                metalView.topAnchor.constraint(equalTo: topAnchor),
                metalView.bottomAnchor.constraint(equalTo: bottomAnchor),
                metalView.leadingAnchor.constraint(equalTo: leadingAnchor),
                metalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }
        NSLayoutConstraint.activate(constraints)
    }

    fileprivate func removeWindowObservations() {
        if let windowOcclusionObserver {
            NotificationCenter.default.removeObserver(windowOcclusionObserver)
            self.windowOcclusionObserver = nil
        }
        if let windowScreenObserver {
            NotificationCenter.default.removeObserver(windowScreenObserver)
            self.windowScreenObserver = nil
        }
    }

    fileprivate func replaceWindowObservations() {
        removeWindowObservations()
        guard let window else { return }

        windowOcclusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.refreshRenderingState()
        }
        windowScreenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.refreshPreferredFramesPerSecond()
        }
    }

    fileprivate func observeAccessibilityDisplayOptions() {
        accessibilityDisplayOptionsObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshRenderingState()
        }
    }

    fileprivate func currentRenderingDecision() -> (canRenderFrame: Bool, shouldRenderContinuously: Bool) {
        let isWindowOccluded = !(window?.occlusionState.contains(.visible) ?? false)
        let isAttachedToWindow = window != nil
        let isWindowVisible = window?.isVisible ?? false
        let isViewHidden = isHiddenOrHasHiddenAncestor
        let shouldReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let canRenderFrame = AppleMusicLyrics.ArtworkGradientRenderingPolicy.canRenderFrame(
            isPresentationVisible: isPresentationVisible,
            isAttachedToWindow: isAttachedToWindow,
            isWindowVisible: isWindowVisible,
            isWindowOccluded: isWindowOccluded,
            isViewHidden: isViewHidden,
            isWindowDragging: isWindowDragging,
            isLiveResizing: isPerformingLiveResize
        )
        let shouldRenderContinuously = AppleMusicLyrics.ArtworkGradientRenderingPolicy.shouldRenderContinuously(
            isPresentationVisible: isPresentationVisible,
            isAttachedToWindow: isAttachedToWindow,
            isWindowVisible: isWindowVisible,
            isWindowOccluded: isWindowOccluded,
            isViewHidden: isViewHidden,
            isWindowDragging: isWindowDragging,
            isLiveResizing: isPerformingLiveResize,
            shouldReduceMotion: shouldReduceMotion,
            isPlaybackActive: isPlaybackActive,
            isShowingArtwork: isShowingArtwork
        )
        return (canRenderFrame, shouldRenderContinuously)
    }

    fileprivate func refreshRenderingState(requestsSingleFrame: Bool = true) {
        guard let metalView else { return }

        let (canRenderFrame, shouldRenderContinuously) = currentRenderingDecision()
        let isPresentationVisible = self.isPresentationVisible
        let isWindowDragging = self.isWindowDragging
        let isPerformingLiveResize = self.isPerformingLiveResize
        let isWindowOccluded = !(window?.occlusionState.contains(.visible) ?? false)
        let isWindowVisible = window?.isVisible ?? false
        let shouldReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let isPlaybackActive = self.isPlaybackActive
        let isShowingArtwork = self.isShowingArtwork

        #log(
            .info,
            """
            Gradient rendering state continuous=\(shouldRenderContinuously, privacy: .public) \
            allowed=\(canRenderFrame, privacy: .public) \
            presentationVisible=\(isPresentationVisible, privacy: .public) \
            windowVisible=\(isWindowVisible, privacy: .public) \
            occluded=\(isWindowOccluded, privacy: .public) \
            windowDragging=\(isWindowDragging, privacy: .public) \
            liveResizing=\(isPerformingLiveResize, privacy: .public) \
            reduceMotion=\(shouldReduceMotion, privacy: .public) \
            playbackActive=\(isPlaybackActive, privacy: .public) \
            showingArtwork=\(isShowingArtwork, privacy: .public)
            """
        )
        metalView.setRenderingState(
            isFrameRenderingAllowed: canRenderFrame,
            isContinuousRenderingEnabled: shouldRenderContinuously
        )
        if requestsSingleFrame {
            requestSingleFrameIfAppropriate()
        }
    }

    fileprivate func refreshPreferredFramesPerSecond() {
        let preferredFramesPerSecond = AppleMusicLyrics.ArtworkGradientRenderingPolicy.preferredFramesPerSecond(
            screenMaximumFramesPerSecond: window?.screen?.maximumFramesPerSecond
        )
        metalView?.setPreferredFramesPerSecond(preferredFramesPerSecond)
    }

    fileprivate func refreshDrawableResizeSuspension() {
        metalView?.setDrawableResizingSuspended(
            isWindowDragging || isPerformingLiveResize
        )
    }

    fileprivate func requestSingleFrameIfAppropriate() {
        guard let metalView else { return }
        let isWindowOccluded = !(window?.occlusionState.contains(.visible) ?? false)
        let canRenderFrame = AppleMusicLyrics.ArtworkGradientRenderingPolicy.canRenderFrame(
            isPresentationVisible: isPresentationVisible,
            isAttachedToWindow: window != nil,
            isWindowVisible: window?.isVisible ?? false,
            isWindowOccluded: isWindowOccluded,
            isViewHidden: isHiddenOrHasHiddenAncestor,
            isWindowDragging: isWindowDragging,
            isLiveResizing: isPerformingLiveResize
        )
        if canRenderFrame {
            metalView.requestSingleFrame()
        }
    }

    /// The placeholder never animates the backdrop, so the switch to it is a
    /// single-frame cut: a cross-fade would freeze at its first frame the
    /// moment continuous rendering stops.
    fileprivate func applyFallbackArtwork() {
        isShowingArtwork = false
        refreshRenderingState(requestsSingleFrame: false)
        metalView?.setFallbackArtwork(animated: false)
    }

    fileprivate func scheduleArtworkAbsenceFallback() {
        let generation = requestState.generation
        let artworkAbsenceWorkItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.requestState.acceptsResult(generation: generation),
                  !self.requestState.hasSubmittedArtwork
            else {
                return
            }
            self.applyFallbackArtwork()
        }
        self.artworkAbsenceWorkItem = artworkAbsenceWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + variant.artworkAbsenceFallbackDelay,
            execute: artworkAbsenceWorkItem
        )
    }
}
