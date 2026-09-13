import AppKit
import Combine
import LyricsXFoundation
import MusicPlayer
import OpenCC
import AppleMusicLyricsPanel

extension AppleMusicLyrics {
    final class WindowController: NSWindowController, NSWindowDelegate {
        private static let windowFrameName = NSWindow.FrameAutosaveName("AppleMusicLyricsWindow")

        init() {
            AppleMusicLyrics.hostEnvironment = .init(
                player: MusicPlayers.Selected.shared,
                isBilingualPreferred: { defaults[.preferBilingualLyrics] },
                transformTranslation: { ChineseConverter.shared?.convert($0) ?? $0 },
                lyricsTimeDelay: { $0.adjustedTimeDelay },
                translationSettingsDidChange: defaults
                    .publisher(for: [.preferBilingualLyrics, .chineseConversionIndex])
                    .map { _ in }
                    .eraseToAnyPublisher()
            )
            super.init(window: nil)
        }


        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var windowNibName: NSNib.Name? {
            ""
        }

        override func loadWindow() {
            let viewController = LyricsPanelViewController(
                lyricsPublisher: AppController.shared.$currentLyrics.eraseToAnyPublisher(),
                currentLineIndexPublisher: AppController.shared.$currentLineIndex.eraseToAnyPublisher()
            )

            let window = NSWindow(contentViewController: viewController)
            AppleMusicLyricsWindowConfiguration.apply(to: window)

            if !window.setFrameUsingName(Self.windowFrameName, force: true) {
                window.center()
            }
            window.setFrameAutosaveName(Self.windowFrameName)
            window.delegate = self
            self.window = window
        }

        override func windowDidLoad() {
            super.windowDidLoad()

            let isPinned = defaults[.appleMusicLyricsWindowPinned]
            if isPinned {
                window?.level = .floating
            }
            installPinButton(isPinned: isPinned)
        }

        // MARK: Pin control

        /// The pin used to be an `NSTitlebarAccessoryViewController`, which is
        /// precisely what stopped AppKit from auto-hiding the titlebar in full
        /// screen: `_originalWindowShouldAutomaticallyAutohide` answers no as
        /// soon as `titlebarAccessoryViewControllers` is non-empty.
        ///
        /// It is now a plain subview of the titlebar view instead. That keeps it
        /// level with the traffic lights -- the content view is covered by the
        /// titlebar up there, so a button hosted in the content view could never
        /// be clicked -- while staying invisible to the accessory count.
        private lazy var pinButton: NSButton = {
            let button = NSButton(
                image: NSImage(systemSymbolName: "pin", accessibilityDescription: "Pin window")!,
                target: self,
                action: #selector(togglePin(_:))
            )
            button.bezelStyle = .accessoryBarAction
            button.setButtonType(.toggle)
            button.isBordered = false
            button.translatesAutoresizingMaskIntoConstraints = false
            button.alphaValue = 0
            return button
        }()

        private func installPinButton(isPinned: Bool) {
            pinButton.state = isPinned ? .on : .off
            pinButton.contentTintColor = isPinned ? .controlAccentColor : .white
            mountPinButton()

            guard let contentView = window?.contentView else { return }
            contentView.addTrackingArea(
                NSTrackingArea(
                    rect: .zero,
                    options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                    owner: self
                )
            )
        }

        /// Re-run after every full screen transition: AppKit hands the titlebar
        /// over to a detached window on the way in and takes it back on the way
        /// out, and the pin has to follow whichever view is current.
        private func mountPinButton() {
            guard let closeButton = window?.standardWindowButton(.closeButton),
                  let titlebarView = closeButton.superview,
                  pinButton.superview !== titlebarView
            else { return }
            titlebarView.addSubview(pinButton)
            NSLayoutConstraint.activate([
                pinButton.trailingAnchor.constraint(equalTo: titlebarView.trailingAnchor, constant: -14),
                pinButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
                pinButton.widthAnchor.constraint(equalToConstant: 22),
                pinButton.heightAnchor.constraint(equalToConstant: 22),
            ])
        }

        override func mouseEntered(with event: NSEvent) {
            setPinButtonVisible(true)
        }

        override func mouseExited(with event: NSEvent) {
            setPinButtonVisible(false)
        }

        private func setPinButtonVisible(_ isVisible: Bool) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                pinButton.animator().alphaValue = isVisible ? 1 : 0
            }
        }

        // MARK: Full screen

        func windowWillEnterFullScreen(_ notification: Notification) {
            guard let window else { return }
            AppleMusicLyricsWindowConfiguration.prepareForFullScreen(window)
        }

        func windowDidEnterFullScreen(_ notification: Notification) {
            mountPinButton()
        }

        func windowDidExitFullScreen(_ notification: Notification) {
            guard let window else { return }
            AppleMusicLyricsWindowConfiguration.restoreAfterFullScreen(
                window,
                isPinned: defaults[.appleMusicLyricsWindowPinned]
            )
            mountPinButton()
        }

        func windowWillClose(_ notification: Notification) {
            // The window is released on close, so persist its final frame now to
            // guarantee the next open restores it even if the session-time
            // autosave never registered (e.g. a prior window still owned the name).
            window?.saveFrame(usingName: Self.windowFrameName)
            defaults[.isShowLyricsHUD] = false
        }

        @objc private func togglePin(_ sender: NSButton) {
            guard let window else { return }
            let pinned = sender.state == .on
            // In full screen the level stays put: floating above the Space would
            // cover the titlebar AppKit slides down, and there is nothing to
            // float over anyway. The preference still records the choice, and
            // leaving full screen applies it.
            if !window.styleMask.contains(.fullScreen) {
                window.level = pinned ? .floating : .normal
            }
            sender.contentTintColor = pinned ? .controlAccentColor : .white
            defaults[.appleMusicLyricsWindowPinned] = pinned
        }
    }
}
