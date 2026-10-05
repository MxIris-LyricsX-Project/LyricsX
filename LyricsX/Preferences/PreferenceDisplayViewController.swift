import AppKit

class PreferenceDisplayViewController: PreferenceViewController, FontSelectTextFieldDelegate {
    @IBOutlet var displayTabs: NSTabView!
    private let menuBarFrameRatePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    @IBOutlet var karaokeFontSelectField: FontSelectTextField!
    @IBOutlet var hudFontSelectField: FontSelectTextField!

    @IBOutlet var fontFallbackLabel: NSTextField!
    @IBOutlet var removeFontFallbackButton: NSButton!

    override func viewDidLoad() {
        karaokeFontSelectField.selectedFont = defaults.desktopLyricsFont
        karaokeFontSelectField.fontChangeDelegate = self
        hudFontSelectField.selectedFont = defaults.lyricsWindowFont
        hudFontSelectField.fontChangeDelegate = self
        updateScreenFontFallback()
        setupMenuBarLyricsTab()
        super.viewDidLoad()
    }

    private func setupMenuBarLyricsTab() {
        let tab = NSTabViewItem(identifier: "MenuBarLyrics")
        tab.label = NSLocalizedString("Menu Bar Lyrics", comment: "Display preferences tab")
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 554, height: 324))
        content.autoresizingMask = [.width, .height]
        tab.view = content

        let label = NSTextField(labelWithString: NSLocalizedString("Scroll frame rate:", comment: "Menu bar lyrics setting"))
        label.alignment = .right
        for rate in [0, 24, 30, 60, 90, 120] {
            let title = rate == 0 ? NSLocalizedString("Static paging (low overhead)", comment: "Menu bar lyrics with page changes instead of continuous scrolling") : "\(rate) fps"
            menuBarFrameRatePopUp.addItem(withTitle: title)
            menuBarFrameRatePopUp.lastItem?.tag = rate
        }
        let storedRate = defaults[.menuBarLyricsFrameRate]
        menuBarFrameRatePopUp.selectItem(withTag: [0, 24, 30, 60, 90, 120].contains(storedRate) ? storedRate : 30)
        menuBarFrameRatePopUp.target = self
        menuBarFrameRatePopUp.action = #selector(changeMenuBarFrameRate(_:))
        let help = NSTextField(wrappingLabelWithString: NSLocalizedString("Sets menu bar behavior for long lyrics. Higher frame rates scroll more smoothly but may use more CPU. (macOS 26 and later)", comment: "Menu bar lyrics frame rate explanation"))
        if #available(macOS 26, *) {
            // The custom menu bar renderer supports selecting its update rate.
        } else {
            menuBarFrameRatePopUp.isEnabled = false
            help.stringValue = NSLocalizedString("Requires macOS 26 or later.", comment: "Menu bar frame rate setting availability")
        }
        help.textColor = .secondaryLabelColor
        help.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        for control in [label, menuBarFrameRatePopUp, help] {
            control.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(control)
        }
        NSLayoutConstraint.activate([
            label.trailingAnchor.constraint(equalTo: content.centerXAnchor, constant: -100),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 24),
            label.centerYAnchor.constraint(equalTo: menuBarFrameRatePopUp.centerYAnchor),
            menuBarFrameRatePopUp.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 16),
            menuBarFrameRatePopUp.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            menuBarFrameRatePopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            help.leadingAnchor.constraint(equalTo: menuBarFrameRatePopUp.leadingAnchor),
            help.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            help.topAnchor.constraint(equalTo: menuBarFrameRatePopUp.bottomAnchor, constant: 12),
        ])
        displayTabs.addTabViewItem(tab)
    }

    @objc private func changeMenuBarFrameRate(_ sender: NSPopUpButton) {
        defaults[.menuBarLyricsFrameRate] = sender.selectedTag()
    }

    func updateScreenFontFallback() {
        guard let fallback = defaults[.desktopLyricsFontNameFallback].first else {
            fontFallbackLabel.isHidden = true
            removeFontFallbackButton.isHidden = true
            return
        }
        fontFallbackLabel.isHidden = false
        removeFontFallbackButton.isHidden = false
        let format = NSLocalizedString("Font Fallback: %@", comment: "")
        fontFallbackLabel.stringValue = String(format: format, arguments: [fallback])
    }

    @IBAction func removeFontFallbackAction(_ sender: Any) {
        defaults[.desktopLyricsFontNameFallback].removeAll()
        updateScreenFontFallback()
    }

    func fontChanged(from oldFont: NSFont, to newFont: NSFont, sender: FontSelectTextField) {
        if sender === karaokeFontSelectField {
            defaults[.desktopLyricsFontName] = newFont.fontName
            defaults[.desktopLyricsFontSize] = Int(newFont.pointSize)
            if (oldFont.familyName != nil && oldFont.familyName != newFont.familyName)
                || oldFont.fontName != newFont.fontName {
                // guarantee different font family of font fallback
                var fallback = defaults[.desktopLyricsFontNameFallback]
                if let index = fallback.firstIndex(of: newFont.fontName) {
                    fallback.remove(at: index)
                }
                fallback.insert(oldFont.fontName, at: 0)
                defaults[.desktopLyricsFontNameFallback] = Array(fallback.prefix(fontNameFallbackCountMax))
                updateScreenFontFallback()
            }
        } else if sender === hudFontSelectField {
            defaults[.lyricsWindowFontName] = newFont.fontName
            defaults[.lyricsWindowFontSize] = Int(newFont.pointSize)
        }
    }
}

class AlphaColorWell: NSColorWell {
    override func activate(_ exclusive: Bool) {
        NSColorPanel.shared.showsAlpha = true
        super.activate(exclusive)
    }

    override func deactivate() {
        super.deactivate()
        NSColorPanel.shared.showsAlpha = false
    }
}
