import AppKit
import LyricsXFoundation
import UIFoundation

final class LyricsHUDWindowController: NSWindowController, NSWindowDelegate, StoryboardWindowController {
    override func windowDidLoad() {
        super.windowDidLoad()

        if let window {
            LyricsHUDWindowConfiguration.apply(to: window)
        }
    }
}
