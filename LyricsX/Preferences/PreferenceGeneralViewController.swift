import AppKit
import MusicPlayer
import ServiceManagement
import LaunchAtLogin

class PreferenceGeneralViewController: PreferenceViewController {
    @objc dynamic var launchAtLogin = LaunchAtLogin.kvo
    @IBOutlet var preferAuto: NSButton!
    @IBOutlet var preferiTunes: NSButton!
    @IBOutlet var preferSpotify: NSButton!
    @IBOutlet var preferVox: NSButton!
    @IBOutlet var preferAudirvana: NSButton!
    @IBOutlet var preferSwinsian: NSButton!

    @IBOutlet var autoLaunchButton: NSButton!

    @IBOutlet var savingPathPopUp: NSPopUpButton!
    @IBOutlet var userPathMenuItem: NSMenuItem!

    @IBOutlet var loadHomonymLrcButton: NSButton!

    @IBOutlet var languagePopUp: NSPopUpButton!

    @IBOutlet var globalOffsetTextField: NSTextField!

    private lazy var playbackRouteLyricsOffsetsButton = NSButton(
        title: NSLocalizedString(
            "Per Player & Output…",
            comment: "Button beside the global lyrics offset in the General pane. Opens the sheet of lyrics offsets set per player and output device."
        ),
        target: self,
        action: #selector(showPlaybackRouteLyricsOffsetsAction(_:))
    )

    override func viewDidLoad() {
        super.viewDidLoad()

        switch defaults[.preferredPlayerIndex] {
        case 0:
            preferiTunes.state = .on
        case 1:
            preferSpotify.state = .on
            loadHomonymLrcButton.isEnabled = false
        case 2:
            preferVox.state = .on
        case 3:
            preferAudirvana.state = .on
            loadHomonymLrcButton.isEnabled = false
        case 4:
            preferSwinsian.state = .on
        default:
            preferAuto.state = .on
            autoLaunchButton.isEnabled = false
        }

        if let url = defaults.lyricsCustomSavingPath {
            userPathMenuItem.title = url.lastPathComponent
            userPathMenuItem.toolTip = url.path
        } else {
            userPathMenuItem.isHidden = true
        }

        let localizedLan: [String] = localizations.map { lan in
            if let idx = lan.firstIndex(of: "-") {
                let script = lan[idx...].dropFirst()
                return Locale(identifier: lan).localizedString(forScriptCode: String(script))!
            } else {
                return Locale(identifier: lan).localizedString(forLanguageCode: lan)!
            }
        }
        languagePopUp.addItems(withTitles: localizedLan)

        if let lan = defaults[.selectedLanguage],
           let idx = localizations.firstIndex(of: lan) {
            languagePopUp.selectItem(at: idx + 2)
        }

        installPlaybackRouteLyricsOffsetsButton()
    }

    /// Puts the button for the offsets per player and output device beside
    /// the global offset, in the same grid cell. A row of its own would make
    /// this pane — the tallest one that does not scroll — taller than a 13-inch
    /// MacBook Air's screen; see `Documentations/Internal/PreferenceWindowSizing.md`.
    private func installPlaybackRouteLyricsOffsetsButton() {
        guard let gridView = globalOffsetTextField.superview as? NSGridView,
              let cell = gridView.cell(for: globalOffsetTextField) else {
            return
        }
        cell.contentView = nil
        let stackView = NSStackView(views: [globalOffsetTextField, playbackRouteLyricsOffsetsButton])
        stackView.orientation = .horizontal
        stackView.alignment = .firstBaseline
        stackView.spacing = 8
        cell.contentView = stackView
    }

    @objc private func showPlaybackRouteLyricsOffsetsAction(_ sender: NSButton) {
        presentAsSheet(PlaybackRouteLyricsOffsetsViewController())
    }

    @IBAction func toggleAutoLaunchAction(_ sender: NSButton) {
        let enabled = sender.state == .on
        if #available(macOS 13, *) {
            let service = SMAppService.loginItem(identifier: lyricsXHelperIdentifier)
            do {
                if enabled {
                    try service.register()
                } else {
                    try service.unregister()
                }
            } catch {
                log("SMAppService \(enabled ? "register" : "unregister") failed: \(error)")
            }
        } else {
            if !SMLoginItemSetEnabled(lyricsXHelperIdentifier as CFString, enabled) {
                log("Failed to set login item enabled")
            }
        }
    }

    @IBAction func showInFinderAction(_ sender: Any) {
        let url = defaults.lyricsSavingPath().0
        NSWorkspace.shared.open(url)
    }

    @IBAction func chooseSavingPathAction(_ sender: Any) {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.beginSheetModal(for: view.window!) { result in
            if result == .OK {
                let url = openPanel.url!
                defaults.lyricsCustomSavingPath = url
                self.userPathMenuItem.title = url.lastPathComponent
                self.userPathMenuItem.toolTip = url.path
                self.userPathMenuItem.isHidden = false
                self.savingPathPopUp.select(self.userPathMenuItem)
            } else {
                self.savingPathPopUp.selectItem(at: 0)
            }
        }
    }

    @IBAction func chooseLanguageAction(_ sender: NSPopUpButton) {
        let selectedIdx = sender.indexOfSelectedItem
        if selectedIdx == 0 {
            defaults.remove(.selectedLanguage)
            defaults.remove(.appleLanguages)
        } else {
            let lan = localizations[selectedIdx - 2]
            defaults[.selectedLanguage] = lan
            defaults[.appleLanguages] = [lan]
        }
    }

    @IBAction func helpTranslateAction(_ sender: NSButton) {
        NSWorkspace.shared.open(crowdinProjectURL)
    }

    @IBAction func preferredPlayerAction(_ sender: NSButton) {
        defaults[.preferredPlayerIndex] = sender.tag

        if sender.tag < 0 {
            autoLaunchButton.isEnabled = false
            autoLaunchButton.state = .off
            defaults[.launchAndQuitWithPlayer] = false
        } else {
            autoLaunchButton.isEnabled = true
        }

        if sender.tag == 1 || sender.tag == 3 || sender.tag == 4 {
            loadHomonymLrcButton.isEnabled = false
            loadHomonymLrcButton.state = .off
            defaults[.loadLyricsBesideTrack] = false
            defaults[.writeBackToLyricsBesideTrack] = false
        } else {
            loadHomonymLrcButton.isEnabled = true
        }
    }
}

private let localizations = Bundle.main.localizations.filter { !$0.localizedCaseInsensitiveContains("Base") }.sorted()
