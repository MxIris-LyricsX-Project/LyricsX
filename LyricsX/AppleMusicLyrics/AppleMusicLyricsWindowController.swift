import AppKit

@available(macOS 15, *)
enum AppleMusicLyrics {}

@available(macOS 15, *)
extension AppleMusicLyrics {
    final class WindowController: NSWindowController, NSWindowDelegate {
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
            window.backgroundColor = .black
            // Custom dragging is handled by `DraggablePanelView` so the run loop
            // stays in default mode and the ColorfulX gradient keeps animating
            // during the drag (see DraggablePanelView).
            window.isMovableByWindowBackground = false
            window.appearance = NSAppearance(named: .darkAqua)
            if !window.setFrameAutosaveName("AppleMusicLyricsWindow") {
                window.center()
            }
            window.delegate = self
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
