//
//  PreferenceWindowController.swift
//  LyricsX
//
//  Created by JH on 2025/1/15.
//  Copyright © 2025 ddddxxx. All rights reserved.
//

import AppKit
import UIFoundation

class PreferenceWindowController: AutoActivateWindowController, StoryboardWindowController {
    
    static var storyboard: NSStoryboard { .init(name: "Preferences", bundle: .main) }
    
}
