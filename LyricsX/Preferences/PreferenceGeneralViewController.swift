import GenericID
import AppKit
import MusicPlayer
import ServiceManagement
import LaunchAtLogin

class PreferenceGeneralViewController: PreferenceViewController {
    @objc dynamic var launchAtLogin = LaunchAtLogin.kvo
    private let preferPhone = NSButton(radioButtonWithTitle: "AVRCP", target: nil, action: nil)
    private var bluetoothPreferenceObservation: DefaultsObservation?
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

    override func viewDidLoad() {
        super.viewDidLoad()
        setupPlayerSources()

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
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        let preferredIndex = defaults[.preferredPlayerIndex]
        let index = preferredIndex == PhonePlayer.preferenceIndex && !defaults[.phoneBluetoothEnabled] ? -1 : preferredIndex
        for (button, tag) in [(preferAuto!, -1), (preferiTunes!, 0), (preferSpotify!, 1), (preferVox!, 2), (preferAudirvana!, 3), (preferSwinsian!, 4), (preferPhone, PhonePlayer.preferenceIndex)] {
            button.state = index == tag ? .on : .off
        }
        autoLaunchButton.isEnabled = index >= 0 && index != PhonePlayer.preferenceIndex
        loadHomonymLrcButton.isEnabled = ![1, 3, 4, PhonePlayer.preferenceIndex].contains(index)
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
        guard sender.tag != PhonePlayer.preferenceIndex || defaults[.phoneBluetoothEnabled] else { return }
        for (button, tag) in [(preferAuto!, -1), (preferiTunes!, 0), (preferSpotify!, 1), (preferVox!, 2), (preferAudirvana!, 3), (preferSwinsian!, 4), (preferPhone, PhonePlayer.preferenceIndex)] {
            button.state = sender.tag == tag ? .on : .off
        }
        defaults[.preferredPlayerIndex] = sender.tag

        if sender.tag < 0 || sender.tag == PhonePlayer.preferenceIndex {
            autoLaunchButton.isEnabled = false
            autoLaunchButton.state = .off
            defaults[.launchAndQuitWithPlayer] = false
        } else {
            autoLaunchButton.isEnabled = true
        }

        if sender.tag == 1 || sender.tag == 3 || sender.tag == 4 || sender.tag == PhonePlayer.preferenceIndex {
            loadHomonymLrcButton.isEnabled = false
            loadHomonymLrcButton.state = .off
            defaults[.loadLyricsBesideTrack] = false
            defaults[.writeBackToLyricsBesideTrack] = false
        } else {
            loadHomonymLrcButton.isEnabled = true
        }
    }
    private func setupPlayerSources() {
        guard let container = preferAuto.superview else { return }
        let radios = [preferAuto!, preferiTunes!, preferSpotify!, preferVox!, preferAudirvana!, preferSwinsian!]
        let icons = radios.compactMap { radio in
            container.subviews.compactMap { $0 as? NSButton }.first { ($0.target as? NSButton) === radio }
        }
        guard icons.count == radios.count else { return }
        preferPhone.tag = PhonePlayer.preferenceIndex
        preferPhone.target = self
        preferPhone.action = #selector(preferredPlayerAction(_:))
        let bluetooth = NSButton(image: Self.avrcpIcon, target: preferPhone, action: #selector(NSButton.performClick(_:)))
        bluetooth.isBordered = false
        bluetooth.imageScaling = .scaleProportionallyUpOrDown
        bluetooth.setAccessibilityLabel("AVRCP")
        bluetooth.toolTip = NSLocalizedString("Bluetooth playback source", comment: "AVRCP source")
        preferPhone.bind(.enabled, withDefaultName: .phoneBluetoothEnabled)
        bluetooth.bind(.enabled, withDefaultName: .phoneBluetoothEnabled)
        NSLayoutConstraint.deactivate(container.constraints)
        container.subviews.forEach { $0.removeFromSuperview() }
        var sourceWidths: [CGFloat] = []
        let columns = zip(icons + [bluetooth], radios + [preferPhone]).map { icon, radio -> NSStackView in
            radio.cell?.wraps = false
            radio.cell?.lineBreakMode = .byClipping
            radio.setContentCompressionResistancePriority(.required, for: .horizontal)
            let width = max(64, ceil(radio.cell?.cellSize.width ?? radio.intrinsicContentSize.width))
            sourceWidths.append(width)
            icon.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: 52),
                icon.heightAnchor.constraint(equalToConstant: 52),
            ])
            let column = NSStackView(views: [icon, radio])
            column.orientation = .vertical
            column.alignment = .centerX
            column.spacing = 9
            column.widthAnchor.constraint(equalToConstant: width).isActive = true
            return column
        }
        let row = NSStackView(views: columns)
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -9),
        ])
        // Allow localized labels to determine the width instead of overlapping
        // the seventh source or shrinking the existing player icons.
        let baseWidth = view.frame.width
        let minimumWidth = view.widthAnchor.constraint(greaterThanOrEqualToConstant: baseWidth)
        minimumWidth.isActive = true
        let phoneColumn = columns[columns.count - 1]
        let updateVisibility: () -> Void = { [weak self, weak row, weak phoneColumn] in
            guard let self = self, let row = row, let phoneColumn = phoneColumn else { return }
            let enabled = defaults[.phoneBluetoothEnabled]
            // Hide the entire icon/radio column and remove its layout space.
            row.setVisibilityPriority(enabled ? .mustHold : .notVisible, for: phoneColumn)
            let widths = enabled ? sourceWidths : Array(sourceWidths.dropLast())
            let width = max(baseWidth, widths.reduce(0, +) + CGFloat(widths.count - 1) * row.spacing + 64)
            minimumWidth.constant = width
            self.view.setFrameSize(NSSize(width: width, height: self.view.frame.height))
            self.preferredContentSize = self.view.frame.size
        }
        updateVisibility()
        bluetoothPreferenceObservation = defaults.observe(keys: [.phoneBluetoothEnabled]) { updateVisibility() }
    }

    static var avrcpIcon: NSImage {
        NSImage(size: NSSize(width: 52, height: 52), flipped: false) { _ in
            NSColor.systemBlue.setFill()
            NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 52, height: 52)).fill()
            let rune = NSBezierPath()
            rune.move(to: NSPoint(x: 18, y: 17))
            rune.line(to: NSPoint(x: 34, y: 33))
            rune.line(to: NSPoint(x: 26, y: 41))
            rune.line(to: NSPoint(x: 26, y: 11))
            rune.line(to: NSPoint(x: 34, y: 19))
            rune.line(to: NSPoint(x: 18, y: 35))
            rune.lineWidth = 3
            rune.lineJoinStyle = .round
            rune.lineCapStyle = .round
            NSColor.white.setStroke()
            rune.stroke()
            return true
        }
    }
}

private let localizations = Bundle.main.localizations.filter { !$0.localizedCaseInsensitiveContains("Base") }.sorted()
