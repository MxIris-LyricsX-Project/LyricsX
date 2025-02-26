//
//  SearchLyricsWindowController.swift
//  LyricsX
//
//  Created by JH on 2025/2/26.
//  Copyright © 2025 ddddxxx. All rights reserved.
//

import AppKit
import UIFoundation

final class SearchLyricsWindowController: NSWindowController {
    init() {
        let window = NSWindow(contentViewController: SearchLyricsViewController.create())
        window.title = NSLocalizedString("Search Lyrics", comment: "window title")
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
