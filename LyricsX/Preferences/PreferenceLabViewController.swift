import AppKit
import Combine
import LyricsXFoundation
import MusicKit

class PreferenceLabViewController: PreferenceViewController {
    @IBOutlet var enableTouchBarLyricsButton: NSButton!

    @IBOutlet var musixmatchTokenField: NSTextField!

    @IBOutlet var useAppleMusicLyricsWindowButton: NSButton!

    @IBOutlet var appleMusicNameRecoveryButton: NSButton!

    @IBOutlet var artworkSimilarityBoostButton: NSButton!

    @IBOutlet var highResolutionArtworkButton: NSButton!

    @IBOutlet weak var appleMusicMediaUserTokenField: NSTextField!
    @IBOutlet weak var appleMusicStorefrontField: NSTextField!
    @IBOutlet weak var appleMusicLanguageField: NSTextField!

    private let preferredLyricsTranslationLanguageField = NSTextField()
    private let lyricsTranslationEnginePopUpButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let aiLyricsTranslationConfigureButton = NSButton()
    private let lyricsTranslationTargetLanguageField = NSTextField()
    private let lyricsTranslationStatusField = NSTextField(labelWithString: "")
    /// Shown while system translation is waiting on languages this Mac has
    /// not downloaded; asks the system to download them.
    private let systemTranslationDownloadButton = NSButton()

    private let aiLyricsTranslator = OpenAICompatibleLyricsTranslator()
    private var aiConnectionTestTask: Task<Void, Never>?
    private var defaultsObservation: AnyCancellable?
    private var languagePairToDownloadObservation: AnyCancellable?
    /// `AppController.systemTranslationLanguagePairToDownload` as last
    /// delivered on the main queue; the controller sets it on the lyrics
    /// display queue, so the pane never reads it there.
    private var systemTranslationLanguagePairToDownload: SystemTranslationLanguagePair?

    /// A `SystemTranslationLanguageDownloader` from macOS 26, untyped here
    /// because a stored property cannot have a type that is not always there.
    private var systemTranslationLanguageDownloaderStorage: AnyObject?

    @available(macOS 26.0, *)
    private var systemTranslationLanguageDownloader: SystemTranslationLanguageDownloader? {
        systemTranslationLanguageDownloaderStorage as? SystemTranslationLanguageDownloader
    }

    /// The most the pane may be tall; see `updateMaximumPaneHeight()`.
    private var maximumPaneHeightConstraint: NSLayoutConstraint?

    /// The General pane's English height, for when it cannot be measured.
    private static let fallbackMaximumPaneHeight: CGFloat = 782

    override func viewDidLoad() {
        super.viewDidLoad()

        insertLyricsTranslationBox()
        embedContentInScrollView()
        if #available(macOS 26.0, *) {
            // In the pane from the start, so the system's download prompt has
            // a window to appear on the moment it is asked for.
            let downloader = SystemTranslationLanguageDownloader()
            view.addSubview(downloader.hostingView)
            systemTranslationLanguageDownloaderStorage = downloader
        }

        enableTouchBarLyricsButton.bind(.value, withDefaultName: .touchBarLyricsEnabled)
        artworkSimilarityBoostButton.bind(.value, withDefaultName: .artworkSimilarityBoostEnabled)
        highResolutionArtworkButton.bind(.value, withDefaultName: .highResolutionPanelArtworkEnabled)

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

        appleMusicMediaUserTokenField.stringValue = defaults[.appleMusicMediaUserToken] ?? ""
        appleMusicStorefrontField.stringValue = defaults[.appleMusicStorefront] ?? ""
        appleMusicLanguageField.stringValue = defaults[.appleMusicLanguage] ?? ""
        preferredLyricsTranslationLanguageField.stringValue = defaults[.preferredLyricsTranslationLanguage] ?? ""
        lyricsTranslationTargetLanguageField.stringValue = defaults[.lyricsTranslationTargetLanguage]
        selectLyricsTranslationEngine(defaults.lyricsTranslationEngine)
        refreshLyricsTranslationStatusField()
        defaultsObservation = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshLyricsTranslationStatusField()
            }
        languagePairToDownloadObservation = AppController.shared.$systemTranslationLanguagePairToDownload
            .receive(on: DispatchQueue.main)
            .sink { [weak self] languagePair in
                self?.systemTranslationLanguagePairToDownload = languagePair
                self?.refreshSystemTranslationDownloadButton()
            }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        updateMaximumPaneHeight()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        aiConnectionTestTask?.cancel()
        aiConnectionTestTask = nil
    }

    // MARK: - Layout

    /// The pane's content, laid out in the storyboard as one grid pinned to
    /// the pane's edges: a label column and a control column.
    private var contentGridView: NSGridView {
        guard let gridView = view.subviews.lazy.compactMap({ $0 as? NSGridView }).first else {
            preconditionFailure("The Lab pane's storyboard scene lays its content out in a grid view.")
        }
        return gridView
    }

    /// Adds the lyrics translation box above the Apple Music one, built the way
    /// the storyboard builds that box: a titled box spanning both columns, its
    /// own grid inset 12 pt, with a 138 pt label column — so the box's labels
    /// end, and its controls start, exactly where the pane's do.
    ///
    /// Built here rather than in the storyboard so that Auto Layout places
    /// every control: frames fixed in Interface Builder neither follow a
    /// longer localized title nor mirror for right-to-left languages.
    private func insertLyricsTranslationBox() {
        let displayLanguageLabel = NSTextField(labelWithString: NSLocalizedString(
            "Display language:",
            comment: "Label for the language whose translation the bilingual lyrics show."
        ))

        let field = preferredLyricsTranslationLanguageField
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.refusesFirstResponder = true
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.sendsActionOnEndEditing = true
        field.placeholderString = NSLocalizedString(
            "Most complete translation (e.g. zh-Hans)",
            comment: "Placeholder of the display language field: blank shows the translation covering the most lines."
        )
        field.toolTip = NSLocalizedString(
            "A language tag such as zh-Hans or ja. Blank shows the translation that covers the most lines.",
            comment: "Tooltip of the display language field in the Lab pane."
        )
        field.target = self
        field.action = #selector(preferredLyricsTranslationLanguageChanged(_:))

        let engineLabel = NSTextField(labelWithString: NSLocalizedString(
            "Translation:",
            comment: "Label for the engine that translates lyrics into the target language, in the Lab pane."
        ))
        let enginePopUpButton = lyricsTranslationEnginePopUpButton
        // Items are enabled by hand: system translation is shown but cannot be
        // picked before macOS 26.
        enginePopUpButton.autoenablesItems = false
        for engine in LyricsTranslationEngine.allCases {
            enginePopUpButton.addItem(withTitle: Self.title(of: engine))
            guard let item = enginePopUpButton.lastItem else { continue }
            item.representedObject = engine.rawValue
            if engine == .system, !isSystemLyricsTranslationAvailable {
                item.isEnabled = false
                item.toolTip = NSLocalizedString(
                    "Requires macOS 26 or later",
                    comment: "Tooltip on a Lab setting that needs macOS 26 when the OS is older."
                )
            }
        }
        enginePopUpButton.target = self
        enginePopUpButton.action = #selector(lyricsTranslationEngineChanged(_:))

        let configureButton = aiLyricsTranslationConfigureButton
        configureButton.title = NSLocalizedString(
            "Configure…",
            comment: "Button in the Lab pane that opens the AI translation settings."
        )
        configureButton.bezelStyle = .rounded
        configureButton.target = self
        configureButton.action = #selector(configureAILyricsTranslation(_:))
        let engineRow = NSStackView(views: [enginePopUpButton, configureButton])
        engineRow.orientation = .horizontal
        engineRow.alignment = .centerY
        engineRow.spacing = 12

        let targetLanguageLabel = NSTextField(labelWithString: NSLocalizedString(
            "Target language:",
            comment: "Label for the language lyrics without a translation are translated into, in the Lab pane."
        ))
        let targetLanguageField = lyricsTranslationTargetLanguageField
        targetLanguageField.bezelStyle = .roundedBezel
        targetLanguageField.focusRingType = .none
        targetLanguageField.refusesFirstResponder = true
        targetLanguageField.usesSingleLineMode = true
        targetLanguageField.lineBreakMode = .byTruncatingTail
        targetLanguageField.cell?.sendsActionOnEndEditing = true
        // The default that a blank field stands for.
        targetLanguageField.placeholderString = AILyricsTranslationPolicy.defaultTargetLanguage
        targetLanguageField.toolTip = NSLocalizedString(
            "A language tag such as zh-Hans, zh-Hant or ja. Lines without a translation into it are translated into it.",
            comment: "Tooltip of the target language field in the Lab pane."
        )
        targetLanguageField.target = self
        targetLanguageField.action = #selector(lyricsTranslationTargetLanguageChanged(_:))

        // One line, truncating, with the whole message in the tooltip: a
        // wrapping status would make the box grow and shrink with every message.
        let statusField = lyricsTranslationStatusField
        statusField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusField.textColor = .secondaryLabelColor
        statusField.lineBreakMode = .byTruncatingTail
        statusField.usesSingleLineMode = true
        statusField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let downloadButton = systemTranslationDownloadButton
        downloadButton.title = NSLocalizedString(
            "Download…",
            comment: "Button beside the Lab pane's translation status that asks the system to download the languages system translation is missing."
        )
        downloadButton.bezelStyle = .rounded
        downloadButton.controlSize = .small
        downloadButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        downloadButton.target = self
        downloadButton.action = #selector(downloadSystemTranslationLanguages(_:))
        downloadButton.isHidden = true
        // Keeps its own width, so a status shorter than the row is what
        // stretches. With both at the default hugging priority, a short
        // status — the Chinese ones — left the stack two ways to fill the row.
        downloadButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let statusRow = NSStackView(views: [statusField, downloadButton])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.distribution = .fill
        statusRow.spacing = 8

        let boxGridView = NSGridView(views: [
            [displayLanguageLabel, field],
            [engineLabel, engineRow],
            [targetLanguageLabel, targetLanguageField],
            [NSGridCell.emptyContentView, statusRow],
        ])
        boxGridView.translatesAutoresizingMaskIntoConstraints = false
        boxGridView.rowSpacing = 6
        boxGridView.columnSpacing = 20
        boxGridView.column(at: 0).width = 138
        boxGridView.column(at: 0).xPlacement = .trailing
        boxGridView.column(at: 1).width = 338
        for rowIndex in 0 ..< 3 {
            boxGridView.row(at: rowIndex).height = 28
            boxGridView.row(at: rowIndex).yPlacement = .center
        }
        boxGridView.cell(for: field)?.xPlacement = .fill
        boxGridView.cell(for: targetLanguageField)?.xPlacement = .fill
        boxGridView.cell(for: statusRow)?.xPlacement = .fill

        let box = NSBox()
        box.title = NSLocalizedString(
            "Lyrics translation",
            comment: "Title of the Lab pane's box grouping the lyrics translation settings."
        )
        // Zero, as the storyboard's boxes have. An NSBox made in code starts
        // with 5 pt margins around its content view, which moved every control
        // in here 5 pt off the pane's columns and narrowed the field by 10.
        box.contentViewMargins = .zero
        box.translatesAutoresizingMaskIntoConstraints = false
        guard let boxContentView = box.contentView else {
            preconditionFailure("An NSBox comes with a content view.")
        }
        boxContentView.addSubview(boxGridView)
        // The insets of the Apple Music box's grid in the storyboard.
        NSLayoutConstraint.activate([
            boxGridView.topAnchor.constraint(equalTo: boxContentView.topAnchor, constant: 8),
            boxGridView.leadingAnchor.constraint(equalTo: boxContentView.leadingAnchor, constant: 12),
            boxContentView.trailingAnchor.constraint(greaterThanOrEqualTo: boxGridView.trailingAnchor, constant: 12),
            boxContentView.bottomAnchor.constraint(equalTo: boxGridView.bottomAnchor, constant: 8),
        ])

        let gridView = contentGridView
        let appleMusicBoxRowIndex = (0 ..< gridView.numberOfRows).first {
            gridView.row(at: $0).cell(at: 0).contentView is NSBox
        } ?? gridView.numberOfRows
        let row = gridView.insertRow(at: appleMusicBoxRowIndex, with: [box, NSGridCell.emptyContentView])
        row.topPadding = 5
        row.mergeCells(in: NSRange(location: 0, length: 2))
        row.cell(at: 0).xPlacement = .fill
    }

    /// Moves the pane's grid into a scroll view, so that the pane is never
    /// taller than `maximumPaneHeightConstraint` allows and scrolls instead.
    ///
    /// The window is sized from the selected pane and cannot be resized, so a
    /// pane taller than the screen leaves its last rows below the screen's
    /// bottom edge, out of reach. This one already was in German, Spanish,
    /// French and Russian before the translation box joined it; see
    /// PreferenceWindowSizing.md. The scroll view takes the content's height at
    /// priority 700 — above the window's stay-put 500, below a control's 750
    /// compression resistance, as the other panes' size constraints are — and
    /// never more than the cap.
    private func embedContentInScrollView() {
        let gridView = contentGridView
        // Takes the grid's constraints to the pane along with it.
        gridView.removeFromSuperview()

        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(gridView)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView = HorizontallyFixedClipView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = documentView
        view.addSubview(scrollView)

        let contentHeightConstraint = scrollView.heightAnchor.constraint(equalTo: documentView.heightAnchor)
        contentHeightConstraint.priority = NSLayoutConstraint.Priority(700)
        let maximumPaneHeightConstraint = scrollView.heightAnchor.constraint(
            lessThanOrEqualToConstant: Self.fallbackMaximumPaneHeight
        )
        self.maximumPaneHeightConstraint = maximumPaneHeightConstraint

        NSLayoutConstraint.activate([
            // The insets the storyboard gives the grid on the pane.
            gridView.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 20),
            gridView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 75),
            documentView.trailingAnchor.constraint(equalTo: gridView.trailingAnchor, constant: 20),
            documentView.bottomAnchor.constraint(equalTo: gridView.bottomAnchor, constant: 20),

            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),

            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            // As wide as the content. A legacy scroller, shown only once the
            // content overflows, then covers the grid's 20 pt trailing inset
            // rather than any of the grid.
            scrollView.widthAnchor.constraint(equalTo: documentView.widthAnchor),
            contentHeightConstraint,
            maximumPaneHeightConstraint,
        ])
    }

    /// Caps the pane at the General pane's height. The General pane is the
    /// tallest of the panes that do not scroll, and its window, 870 pt in
    /// English, is what a 13-inch MacBook Air's 876 pt has to fit anyway, so
    /// this pane's window is never taller than that one's.
    ///
    /// Measured rather than written down: the General pane's height moves with
    /// its content and with the language the app runs in.
    private func updateMaximumPaneHeight() {
        let generalPane = parent?.children.first { $0 is PreferenceGeneralViewController }
        let generalPaneHeight = generalPane?.view.fittingSize.height ?? 0
        maximumPaneHeightConstraint?.constant = generalPaneHeight > 0
            ? generalPaneHeight
            : Self.fallbackMaximumPaneHeight
    }

    // MARK: - Lyrics translation

    @objc private func preferredLyricsTranslationLanguageChanged(_ sender: NSTextField) {
        let value = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            defaults.remove(.preferredLyricsTranslationLanguage)
            return
        }
        guard let language = AILyricsTranslationPolicy.normalizedLanguageIdentifier(value) else {
            sender.stringValue = defaults[.preferredLyricsTranslationLanguage] ?? ""
            updateLyricsTranslationStatus(NSLocalizedString(
                "Display language must be a valid language tag, such as zh-Hans or ja.",
                comment: "Validation feedback for the preferred lyric display language."
            ))
            return
        }
        defaults[.preferredLyricsTranslationLanguage] = language
        sender.stringValue = language
    }

    private static func title(of engine: LyricsTranslationEngine) -> String {
        switch engine {
        case .off:
            return NSLocalizedString(
                "Off",
                comment: "Lab pane translation engine choice that translates nothing."
            )
        case .system:
            return NSLocalizedString(
                "System Translation",
                comment: "Lab pane translation engine choice that uses the system's Translation framework, on this Mac."
            )
        case .ai:
            return NSLocalizedString(
                "AI (OpenAI-compatible)",
                comment: "Lab pane translation engine choice that sends lines to an OpenAI-compatible endpoint."
            )
        }
    }

    private func selectLyricsTranslationEngine(_ engine: LyricsTranslationEngine) {
        let index = lyricsTranslationEnginePopUpButton.indexOfItem(withRepresentedObject: engine.rawValue)
        if index >= 0 {
            lyricsTranslationEnginePopUpButton.selectItem(at: index)
        }
        aiLyricsTranslationConfigureButton.isEnabled = engine == .ai
        refreshSystemTranslationDownloadButton()
    }

    private static var lyricsTranslationOffStatus: String {
        NSLocalizedString(
            "Lyrics translation is off.",
            comment: "Status shown when the Lab pane's lyrics translation is turned off."
        )
    }

    @objc private func lyricsTranslationEngineChanged(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let engine = LyricsTranslationEngine(rawValue: rawValue),
              engine != defaults.lyricsTranslationEngine else {
            return
        }
        // What the previous engine reported is about that engine. Replaced
        // before the switch is stored, so whatever the new engine reports —
        // it starts on the change, on another queue — lands after it.
        updateLyricsTranslationStatus(engine == .off ? Self.lyricsTranslationOffStatus : "")
        defaults.lyricsTranslationEngine = engine
        selectLyricsTranslationEngine(engine)
    }

    @objc private func lyricsTranslationTargetLanguageChanged(_ sender: NSTextField) {
        let value = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            // Blank stands for the default the placeholder shows.
            defaults.remove(.lyricsTranslationTargetLanguage)
            return
        }
        guard let language = AILyricsTranslationPolicy.normalizedLanguageIdentifier(value) else {
            sender.stringValue = defaults[.lyricsTranslationTargetLanguage]
            updateLyricsTranslationStatus(NSLocalizedString(
                "The target language must be a language tag, such as zh-Hans or ja.",
                comment: "Status for lyrics translation when the target language is not a valid language tag."
            ))
            return
        }
        defaults[.lyricsTranslationTargetLanguage] = language
        sender.stringValue = language
    }

    /// Shows the download button while system translation is the engine and
    /// is waiting on a language pair, with what it would download as its
    /// tooltip.
    private func refreshSystemTranslationDownloadButton() {
        let languagePair = systemTranslationLanguagePairToDownload
        let isWaitingOnDownload = languagePair != nil && defaults.lyricsTranslationEngine == .system
        systemTranslationDownloadButton.isHidden = !isWaitingOnDownload
        systemTranslationDownloadButton.toolTip = languagePair.map { languagePair in
            String(
                format: NSLocalizedString(
                    "Download the languages for %@",
                    comment: "Tooltip of the Lab pane's download button; %@ is a translation direction such as Japanese → Chinese, Simplified."
                ),
                languagePair.localizedDescription
            )
        }
    }

    @objc private func downloadSystemTranslationLanguages(_ sender: NSButton) {
        guard #available(macOS 26.0, *),
              let downloader = systemTranslationLanguageDownloader,
              let languagePair = systemTranslationLanguagePairToDownload else {
            return
        }
        sender.isEnabled = false
        downloader.requestDownload(of: languagePair) { [weak self] error in
            sender.isEnabled = true
            guard error == nil else {
                // Dismissed, or the download failed: the languages are still
                // missing, and the status says so again in those words.
                self?.updateLyricsTranslationStatus(String(
                    format: NSLocalizedString(
                        "The languages for %@ were not downloaded.",
                        comment: "Status shown when the system's language download prompt was dismissed or failed; %@ is a translation direction such as Japanese → Chinese, Simplified."
                    ),
                    languagePair.localizedDescription
                ))
                return
            }
            AppController.shared.retryLyricsTranslation()
        }
    }

    @objc private func configureAILyricsTranslation(_ sender: NSButton) {
        let settings = AILyricsTranslationSettingsViewController()
        settings.onSave = { [weak self] configuration, shouldTest in
            AppController.shared.retryLyricsTranslation()

            if shouldTest {
                self?.testAITranslationConnection(configuration: configuration)
            }
        }
        presentAsSheet(settings)
    }

    private func testAITranslationConnection(configuration: AILyricsTranslationConfiguration) {
        aiConnectionTestTask?.cancel()
        updateLyricsTranslationStatus(NSLocalizedString(
            "Testing connection…",
            comment: "Status shown while testing the AI lyrics translation endpoint."
        ))
        aiConnectionTestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let apiKey = try AILyricsTranslationCredentialStore.apiKey(for: configuration.endpoint) else {
                    updateLyricsTranslationStatus(NSLocalizedString(
                        "No API key is saved for this endpoint.",
                        comment: "Status shown when endpoint testing finds no stored API key."
                    ))
                    return
                }
                try await aiLyricsTranslator.testConnection(
                    configuration: configuration,
                    apiKey: apiKey
                )
                guard !Task.isCancelled else { return }
                updateLyricsTranslationStatus(NSLocalizedString(
                    "Connection succeeded.",
                    comment: "Status shown when the AI lyrics translation endpoint test succeeds."
                ))
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch {
                guard !Task.isCancelled else { return }
                updateLyricsTranslationStatus(OpenAICompatibleLyricsTranslator.failureDescription(for: error))
            }
        }
    }

    private func updateLyricsTranslationStatus(_ message: String) {
        defaults[.lyricsTranslationStatus] = message
        refreshLyricsTranslationStatusField()
    }

    private func refreshLyricsTranslationStatusField() {
        let status = defaults[.lyricsTranslationStatus]
        lyricsTranslationStatusField.stringValue = status
        // The field is one line, so the tooltip carries the whole message for
        // whichever translation is too long to fit.
        lyricsTranslationStatusField.toolTip = status.isEmpty ? nil : status
    }

    @IBAction func musixmatchTokenChanged(_ sender: NSTextField) {
        let value = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            defaults.remove(.musixmatchToken)
        } else {
            defaults[.musixmatchToken] = value
        }

        // Update lyrics manager when token changes
        Task { @MainActor in await AppController.shared.updateLyricsManager() }
    }

    // MARK: - Apple Music media-user-token / overrides

    /// The user pastes their `media-user-token` (copied from Safari's
    /// `music.apple.com` cookies). The provider rebuild picks up the new
    /// value and constructs a fresh `AppleMusicSession` against it.
    @IBAction func appleMusicMediaUserTokenChanged(_ sender: NSTextField) {
        let value = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            defaults.remove(.appleMusicMediaUserToken)
        } else {
            defaults[.appleMusicMediaUserToken] = value
        }
        Task { @MainActor in await AppController.shared.updateLyricsManager() }
    }

    @IBAction func appleMusicStorefrontChanged(_ sender: NSTextField) {
        let value = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            defaults.remove(.appleMusicStorefront)
        } else {
            defaults[.appleMusicStorefront] = value
        }
        Task { @MainActor in await AppController.shared.updateLyricsManager() }
    }

    @IBAction func appleMusicLanguageChanged(_ sender: NSTextField) {
        let value = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            defaults.remove(.appleMusicLanguage)
        } else {
            defaults[.appleMusicLanguage] = value
        }
        Task { @MainActor in await AppController.shared.updateLyricsManager() }
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

/// Flipped so that a scrolled document starts at its first row: with a
/// non-flipped document, AppKit leaves the clip view at the content's bottom.
private final class FlippedView: NSView {
    override var isFlipped: Bool {
        true
    }
}

/// A clip view that only scrolls vertically. The document is as wide as the
/// scroll view, so while a legacy scroller shows it is a scroller's width wider
/// than the clip, and a trackpad would otherwise nudge it sideways.
private final class HorizontallyFixedClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrainedBounds = super.constrainBoundsRect(proposedBounds)
        constrainedBounds.origin.x = 0
        return constrainedBounds
    }
}
