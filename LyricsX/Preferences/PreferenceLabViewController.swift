//
//  PreferenceLabViewController.swift
//  LyricsX - https://github.com/ddddxxx/LyricsX
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//

import Cocoa
import LyricsService
import LyricsServiceUI

class PreferenceLabViewController: PreferenceViewController {
    @IBOutlet var enableTouchBarLyricsButton: NSButton!

    @IBOutlet var spotifyLoginButton: NSButton!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        enableTouchBarLyricsButton.bind(.value, withDefaultName: .touchBarLyricsEnabled)
        Task {
            if await SpotifyLoginManager.shared.isLogin {
                spotifyLoginButton.title = "Logout"
            } else {
                spotifyLoginButton.title = "Login"
            }
        }
    }

    @IBAction func spotifyLoginAction(_ sender: NSButton) {
        Task {
            if await !SpotifyLoginManager.shared.isLogin {
                try await SpotifyLoginManager.shared.login()
                guard let accessToken = await SpotifyLoginManager.shared.accessTokenString else { return }
                await MainActor.run {
                    AppController.shared.lyricsManager = .init(service: LyricsProviders.Service.noAuthenticationRequiredServices +  [.spotify(accessToken: accessToken)])
                }
                spotifyLoginButton.title = "Logout"
            } else {
                await SpotifyLoginManager.shared.logout()
                await MainActor.run {
                    AppController.shared.lyricsManager = .init(service: LyricsProviders.Service.noAuthenticationRequiredServices)
                }
                spotifyLoginButton.title = "Login"
            }
        }
    }
    
    @IBAction func customizeAllowsNowPlayingApplicationsAction(_ sender: NSButton) {
        let viewController = NowPlayingApplicationListViewController()
        viewController.preferredContentSize = .init(width: 600, height: 500)
        presentAsSheet(viewController)
    }

    @IBAction func customizeTouchBarAction(_ sender: NSButton) {
        if #available(OSX 10.12.2, *) {
            NSApplication.shared.toggleTouchBarCustomizationPalette(sender)
        } else {
            // Fallback on earlier versions
        }
    }
}
