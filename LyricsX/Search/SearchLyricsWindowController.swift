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
    let viewController: SearchLyricsViewController
    
    init() {
        let viewController = SearchLyricsViewController.create()
        self.viewController = viewController
        let window = NSWindow(contentViewController: viewController)
        window.title = NSLocalizedString("Search Lyrics", comment: "window title")
        super.init(window: window)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        viewController.reloadKeyword()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
