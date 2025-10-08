import AppKit
import UIFoundation

class PreferenceWindowController: AutoActivateWindowController, StoryboardWindowController {
    static var storyboard: NSStoryboard { .init(name: "Preferences", bundle: .main) }
}
