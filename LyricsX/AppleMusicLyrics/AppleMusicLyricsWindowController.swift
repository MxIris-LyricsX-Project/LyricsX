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

        // Dark appearance
        window.appearance = NSAppearance(named: .darkAqua)

        self.init(window: window)
        window.delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        defaults[.isShowLyricsHUD] = false
    }

    func toggleWindowLevel() {
        guard let window else { return }
        if window.level == .normal {
            window.level = .floating
        } else {
            window.level = .normal
        }
    }
}
