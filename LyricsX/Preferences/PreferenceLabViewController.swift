import AppKit
import LyricsXFoundation

class PreferenceLabViewController: PreferenceViewController {
    @IBOutlet var enableTouchBarLyricsButton: NSButton!

    @IBOutlet var spotifyLoginButton: NSButton!

    override func viewDidLoad() {
        super.viewDidLoad()
        enableTouchBarLyricsButton.bind(.value, withDefaultName: .touchBarLyricsEnabled)
        Task { @MainActor in
            if await SpotifyLoginManager.shared.isLogin {
                spotifyLoginButton.title = "Logout"
            } else {
                spotifyLoginButton.title = "Login"
            }
        }
    }

    @IBAction func spotifyLoginAction(_ sender: NSButton) {
        Task { @MainActor in
            if await !SpotifyLoginManager.shared.isLogin {
                try await SpotifyLoginManager.shared.login()
                try await AppController.shared.updateLyricsManager()
                spotifyLoginButton.title = "Logout"
            } else {
                await SpotifyLoginManager.shared.logout()
                try await AppController.shared.updateLyricsManager()
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
