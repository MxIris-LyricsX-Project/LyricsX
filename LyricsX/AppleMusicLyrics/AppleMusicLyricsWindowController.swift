import AppKit

enum AppleMusicLyrics {}

extension AppleMusicLyrics {
    final class WindowController: NSWindowController, NSWindowDelegate {
        private static let windowFrameName = NSWindow.FrameAutosaveName("AppleMusicLyricsWindow")

        init() {
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
            let viewController = LyricsPanelViewController()

            let window = NSWindow(contentViewController: viewController)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = .clear
            window.isMovableByWindowBackground = false
            if !window.setFrameUsingName(Self.windowFrameName, force: true) {
                window.center()
            }
            window.setFrameAutosaveName(Self.windowFrameName)
            window.toolbar = NSToolbar()
            window.toolbarStyle = .unified
            window.delegate = self
            window.minSize = .init(width: 980, height: 600)
            self.window = window
        }

        override func windowDidLoad() {
            super.windowDidLoad()

            let isPinned = defaults[.appleMusicLyricsWindowPinned]
            if isPinned {
                window?.level = .floating
            }
            // Add pin/unpin titlebar accessory
            let pinAccessory = NSTitlebarAccessoryViewController()
            let pinButton = NSButton(image: NSImage(systemSymbolName: "pin", accessibilityDescription: "Pin window")!, target: self, action: #selector(togglePin(_:)))
            pinButton.bezelStyle = .accessoryBarAction
            pinButton.setButtonType(.toggle)
            pinButton.isBordered = false
            pinButton.state = isPinned ? .on : .off
            pinButton.contentTintColor = isPinned ? .controlAccentColor : .white
            pinAccessory.view = pinButton
            pinAccessory.layoutAttribute = .right
            window?.addTitlebarAccessoryViewController(pinAccessory)
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
            window.level = pinned ? .floating : .normal
            sender.contentTintColor = pinned ? .controlAccentColor : .white
            defaults[.appleMusicLyricsWindowPinned] = pinned
        }
    }
}
