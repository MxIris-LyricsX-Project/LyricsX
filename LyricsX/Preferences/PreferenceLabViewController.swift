import AppKit
import LyricsXFoundation
import MusicKit

class PreferenceLabViewController: PreferenceViewController {
    @IBOutlet var enableTouchBarLyricsButton: NSButton!

    @IBOutlet var musixmatchTokenField: NSTextField!

    @IBOutlet var useAppleMusicLyricsWindowButton: NSButton!

    @IBOutlet var appleMusicNameRecoveryButton: NSButton!

    @IBOutlet var artworkSimilarityBoostButton: NSButton!

    override func viewDidLoad() {
        super.viewDidLoad()

        enableTouchBarLyricsButton.bind(.value, withDefaultName: .touchBarLyricsEnabled)
        artworkSimilarityBoostButton.bind(.value, withDefaultName: .artworkSimilarityBoostEnabled)

        useAppleMusicLyricsWindowButton.bind(.value, withDefaultName: .useAppleMusicLyricsWindow)
        if #available(macOS 15, *) {
            // Available — leave the checkbox interactive.
        } else {
            useAppleMusicLyricsWindowButton.isEnabled = false
            useAppleMusicLyricsWindowButton.toolTip = NSLocalizedString(
                "Requires macOS 15 or later",
                comment: "Tooltip on the Apple Music-style lyrics window toggle when the OS is too old."
            )
        }

        // Turning this on requires MusicAuthorization, so the button is
        // driven by an action instead of a value binding: the action gates
        // writes on the actual authorization result and rolls the state back
        // if the user denies access.
        appleMusicNameRecoveryButton.state = defaults[.appleMusicNameRecoveryEnabled] ? .on : .off
        if #available(macOS 12, *) {
            // Available — leave the checkbox interactive.
        } else {
            appleMusicNameRecoveryButton.isEnabled = false
            appleMusicNameRecoveryButton.toolTip = NSLocalizedString(
                "Requires macOS 12 or later",
                comment: "Tooltip on the Apple Music name recovery toggle when the OS is too old."
            )
        }

        if let token = defaults[.musixmatchToken] {
            musixmatchTokenField.stringValue = token
        } else {
            musixmatchTokenField.stringValue = ""
        }
    }

    @IBAction func musixmatchTokenChanged(_ sender: NSTextField) {
        let value = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            defaults.remove(.musixmatchToken)
        } else {
            defaults[.musixmatchToken] = value
        }

        // Update lyrics manager when token changes
        AppController.shared.updateLyricsManager()
    }

    @IBAction func customizeAllowsNowPlayingApplicationsAction(_ sender: NSButton) {
        let viewController = NowPlayingApplicationListViewController()
        viewController.preferredContentSize = .init(width: 600, height: 500)
        presentAsSheet(viewController)
    }

    @IBAction func customizeTouchBarAction(_ sender: NSButton) {
        NSApplication.shared.toggleTouchBarCustomizationPalette(sender)
    }

    @IBAction func appleMusicNameRecoveryButtonAction(_ sender: NSButton) {
        let didTurnOn = sender.state == .on
        guard didTurnOn else {
            defaults[.appleMusicNameRecoveryEnabled] = false
            return
        }
        guard #available(macOS 12, *) else {
            sender.state = .off
            defaults[.appleMusicNameRecoveryEnabled] = false
            return
        }
        Task { @MainActor in
            await self.enableAppleMusicNameRecoveryIfAuthorized(button: sender)
        }
    }

    @available(macOS 12, *)
    @MainActor
    private func enableAppleMusicNameRecoveryIfAuthorized(button: NSButton) async {
        let resolvedStatus: MusicAuthorization.Status
        switch MusicAuthorization.currentStatus {
        case .authorized:
            resolvedStatus = .authorized
        case .notDetermined:
            resolvedStatus = await MusicAuthorization.request()
        case .denied, .restricted:
            resolvedStatus = MusicAuthorization.currentStatus
        @unknown default:
            resolvedStatus = .denied
        }

        if resolvedStatus == .authorized {
            defaults[.appleMusicNameRecoveryEnabled] = true
        } else {
            button.state = .off
            defaults[.appleMusicNameRecoveryEnabled] = false
            presentAppleMusicAccessDeniedAlert()
        }
    }

    @MainActor
    private func presentAppleMusicAccessDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString(
            "Apple Music access is required to recover original song and artist names.",
            comment: "Alert title when MusicAuthorization is denied or restricted for the MusicKit name recovery toggle."
        )
        alert.informativeText = NSLocalizedString(
            "Grant access in System Settings > Privacy & Security > Media & Apple Music, then try again.",
            comment: "Alert body directing the user to System Settings to grant Apple Music access."
        )
        alert.addButton(withTitle: NSLocalizedString("OK", comment: "Alert OK button"))
        alert.runModal()
    }
}
