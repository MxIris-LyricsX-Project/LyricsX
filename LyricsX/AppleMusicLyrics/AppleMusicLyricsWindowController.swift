import AppKit
import SwiftUI

@available(macOS 15, *)
final class AppleMusicLyricsWindowController: NSWindowController, NSWindowDelegate {

    convenience init() {
        let rootView = AppleMusicLyricsRootView()
        let hostingController = NSHostingController(rootView: rootView)

        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .black
        window.setContentSize(NSSize(width: 900, height: 500))
        window.minSize = NSSize(width: 500, height: 350)
        window.isMovableByWindowBackground = true
        window.setFrameAutosaveName("AppleMusicLyricsWindow")
        window.appearance = NSAppearance(named: .darkAqua)

        self.init(window: window)
        window.delegate = self

        // Add pin/unpin titlebar accessory
        let pinAccessory = NSTitlebarAccessoryViewController()
        let pinButton = NSButton(image: NSImage(systemSymbolName: "pin", accessibilityDescription: "Pin window")!, target: self, action: #selector(togglePin(_:)))
        pinButton.bezelStyle = .accessoryBarAction
        pinButton.setButtonType(.toggle)
        pinButton.isBordered = false
        pinButton.contentTintColor = .white
        pinAccessory.view = pinButton
        pinAccessory.layoutAttribute = .right
        window.addTitlebarAccessoryViewController(pinAccessory)
    }

    func windowWillClose(_ notification: Notification) {
        defaults[.isShowLyricsHUD] = false
    }

    @objc private func togglePin(_ sender: NSButton) {
        guard let window else { return }
        if sender.state == .on {
            window.level = .floating
            sender.contentTintColor = .controlAccentColor
        } else {
            window.level = .normal
            sender.contentTintColor = .white
        }
    }
}
