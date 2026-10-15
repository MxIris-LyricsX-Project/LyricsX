import AppKit
import Combine
import LyricsXFoundation
import MusicKit

class PreferenceLabViewController: PreferenceViewController {
    @IBOutlet var enableTouchBarLyricsButton: NSButton!
    @IBOutlet var preferredLyricsTranslationLanguageField: NSTextField!
    @IBOutlet var aiLyricsTranslationEnabledButton: NSButton!
    @IBOutlet var aiLyricsTranslationStatusField: NSTextField!

    @IBOutlet var musixmatchTokenField: NSTextField!

    @IBOutlet var useAppleMusicLyricsWindowButton: NSButton!

    @IBOutlet var appleMusicNameRecoveryButton: NSButton!

    @IBOutlet var artworkSimilarityBoostButton: NSButton!

    @IBOutlet var highResolutionArtworkButton: NSButton!

    @IBOutlet weak var appleMusicMediaUserTokenField: NSTextField!
    @IBOutlet weak var appleMusicStorefrontField: NSTextField!
    @IBOutlet weak var appleMusicLanguageField: NSTextField!

    private let aiLyricsTranslator = OpenAICompatibleLyricsTranslator()
    private var aiConnectionTestTask: Task<Void, Never>?
    private var defaultsObservation: AnyCancellable?

    override func viewDidLoad() {
        super.viewDidLoad()

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
        aiLyricsTranslationEnabledButton.state = defaults[.aiLyricsTranslationEnabled] ? .on : .off
        aiLyricsTranslationStatusField.stringValue = defaults[.aiLyricsTranslationStatus]
        aiLyricsTranslationStatusField.cell?.wraps = true
        aiLyricsTranslationStatusField.cell?.usesSingleLineMode = false
        defaultsObservation = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.aiLyricsTranslationStatusField.stringValue = defaults[.aiLyricsTranslationStatus]
            }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        aiConnectionTestTask?.cancel()
        aiConnectionTestTask = nil
    }

    @IBAction func preferredLyricsTranslationLanguageChanged(_ sender: NSTextField) {
        let value = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            defaults.remove(.preferredLyricsTranslationLanguage)
            return
        }
        guard let language = AILyricsTranslationPolicy.normalizedLanguageIdentifier(value) else {
            sender.stringValue = defaults[.preferredLyricsTranslationLanguage] ?? ""
            updateAILyricsTranslationStatus(NSLocalizedString(
                "Display language must be a valid language tag, such as zh-Hans or ja.",
                comment: "Validation feedback for the preferred lyric display language."
            ))
            return
        }
        defaults[.preferredLyricsTranslationLanguage] = language
        sender.stringValue = language
    }

    @IBAction func aiLyricsTranslationEnabledChanged(_ sender: NSButton) {
        defaults[.aiLyricsTranslationEnabled] = sender.state == .on
        if sender.state == .off {
            updateAILyricsTranslationStatus(NSLocalizedString(
                "AI translation is disabled.",
                comment: "Status shown when AI lyric translation is turned off."
            ))
        }
    }

    @IBAction func configureAILyricsTranslation(_ sender: NSButton) {
        let savedEndpoint = defaults[.aiLyricsTranslationEndpoint]
        let endpointField = NSTextField(
            frame: NSRect(x: 0, y: 0, width: 354, height: 24)
        )
        endpointField.stringValue = savedEndpoint.isEmpty ? AILyricsTranslationPolicy.defaultEndpoint : savedEndpoint
        let savedModel = defaults[.aiLyricsTranslationModel]
        let modelField = NSTextField(frame: NSRect(x: 0, y: 0, width: 354, height: 24))
        modelField.stringValue = savedModel.isEmpty ? AILyricsTranslationPolicy.defaultModel : savedModel
        let savedTargetLanguage = defaults[.aiLyricsTranslationTargetLanguage]
        let targetLanguageField = NSTextField(frame: NSRect(x: 0, y: 0, width: 354, height: 24))
        targetLanguageField.stringValue = savedTargetLanguage.isEmpty
            ? AILyricsTranslationPolicy.defaultTargetLanguage
            : savedTargetLanguage
        let apiKeyField = NSSecureTextField(string: "")
        apiKeyField.placeholderString = NSLocalizedString(
            "Leave blank to keep the saved key",
            comment: "Placeholder for the secure AI translation API-key field."
        )
        let removeKeyButton = NSButton(
            checkboxWithTitle: NSLocalizedString(
                "Remove saved API key",
                comment: "Checkbox to delete the saved AI translation API key from Keychain."
            ),
            target: nil,
            action: nil
        )
        let promptView = NSTextView()
        promptView.string = defaults[.aiLyricsTranslationPrompt].isEmpty
            ? AILyricsTranslationPolicy.defaultPrompt
            : defaults[.aiLyricsTranslationPrompt]
        promptView.isRichText = false
        let promptScrollView = NSScrollView(frame: NSRect(x: 126, y: 0, width: 354, height: 82))
        promptScrollView.borderType = .bezelBorder
        promptScrollView.hasVerticalScroller = true
        promptScrollView.documentView = promptView

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 270))
        func addFieldRow(_ title: String, field: NSTextField, y: CGFloat) {
            let label = NSTextField(labelWithString: title)
            label.frame = NSRect(x: 0, y: y + 3, width: 118, height: 18)
            field.frame = NSRect(x: 126, y: y, width: 354, height: 24)
            accessory.addSubview(label)
            accessory.addSubview(field)
        }
        addFieldRow(NSLocalizedString("Endpoint", comment: "AI lyrics translation endpoint setting."), field: endpointField, y: 238)
        addFieldRow(NSLocalizedString("Model", comment: "AI lyrics translation model setting."), field: modelField, y: 206)
        addFieldRow(NSLocalizedString("Target language", comment: "AI lyrics translation target language setting."), field: targetLanguageField, y: 174)
        addFieldRow(NSLocalizedString("API key", comment: "AI lyrics translation API-key setting."), field: apiKeyField, y: 142)
        removeKeyButton.frame = NSRect(x: 126, y: 112, width: 220, height: 18)
        accessory.addSubview(removeKeyButton)
        let promptLabel = NSTextField(labelWithString: NSLocalizedString(
            "Prompt",
            comment: "AI lyrics translation prompt setting."
        ))
        promptLabel.frame = NSRect(x: 0, y: 62, width: 118, height: 18)
        accessory.addSubview(promptLabel)
        accessory.addSubview(promptScrollView)

        let alert = NSAlert()
        alert.messageText = NSLocalizedString("AI lyrics translation", comment: "AI lyrics translation settings dialog title.")
        alert.informativeText = NSLocalizedString(
            "Eligible lyric lines are sent to this endpoint for translation. The provider may charge for requests; the API key is stored in Keychain.",
            comment: "Privacy and cost notice for AI lyrics translation."
        )
        alert.accessoryView = accessory
        alert.addButton(withTitle: NSLocalizedString("Save", comment: "Save AI lyrics translation settings."))
        alert.addButton(withTitle: NSLocalizedString("Save and Test", comment: "Save settings and test the AI lyrics translation endpoint."))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel AI lyrics translation settings."))

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else {
            return
        }

        do {
            let configuration = try AILyricsTranslationPolicy.configuration(
                endpoint: endpointField.stringValue,
                model: modelField.stringValue.isEmpty ? AILyricsTranslationPolicy.defaultModel : modelField.stringValue,
                targetLanguage: targetLanguageField.stringValue.isEmpty
                    ? AILyricsTranslationPolicy.defaultTargetLanguage
                    : targetLanguageField.stringValue,
                prompt: promptView.string.isEmpty ? AILyricsTranslationPolicy.defaultPrompt : promptView.string
            )
            if removeKeyButton.state == .on {
                try AILyricsTranslationCredentialStore.removeAPIKey()
            } else if !apiKeyField.stringValue.isEmpty {
                try AILyricsTranslationCredentialStore.store(
                    apiKey: apiKeyField.stringValue,
                    for: configuration.endpoint
                )
            }

            defaults[.aiLyricsTranslationEndpoint] = configuration.endpoint.absoluteString
            defaults[.aiLyricsTranslationModel] = configuration.model
            defaults[.aiLyricsTranslationTargetLanguage] = configuration.targetLanguage
            defaults[.aiLyricsTranslationPrompt] = promptView.string.isEmpty
                ? AILyricsTranslationPolicy.defaultPrompt
                : promptView.string
            AppController.shared.retryAILyricsTranslation()

            if response == .alertSecondButtonReturn {
                testAITranslationConnection(configuration: configuration)
            }
        } catch {
            updateAILyricsTranslationStatus(NSLocalizedString(
                "Settings could not be saved. Check the endpoint, language, prompt, and Keychain access.",
                comment: "Status shown when AI lyrics translation settings cannot be saved."
            ))
        }
    }

    private func testAITranslationConnection(configuration: AILyricsTranslationConfiguration) {
        aiConnectionTestTask?.cancel()
        updateAILyricsTranslationStatus(NSLocalizedString(
            "Testing connection…",
            comment: "Status shown while testing the AI lyrics translation endpoint."
        ))
        aiConnectionTestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let apiKey = try AILyricsTranslationCredentialStore.apiKey(for: configuration.endpoint) else {
                    updateAILyricsTranslationStatus(NSLocalizedString(
                        "No API key is saved for this endpoint.",
                        comment: "Status shown when endpoint testing finds no stored API key."
                    ))
                    return
                }
                try await aiLyricsTranslator.testConnection(
                    endpoint: configuration.endpoint,
                    model: configuration.model,
                    apiKey: apiKey
                )
                guard !Task.isCancelled else { return }
                updateAILyricsTranslationStatus(NSLocalizedString(
                    "Connection succeeded.",
                    comment: "Status shown when the AI lyrics translation endpoint test succeeds."
                ))
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch {
                guard !Task.isCancelled else { return }
                updateAILyricsTranslationStatus(NSLocalizedString(
                    "Connection failed. Check the endpoint, model, and API key.",
                    comment: "Generic status shown when the AI lyrics translation endpoint test fails."
                ))
            }
        }
    }

    private func updateAILyricsTranslationStatus(_ message: String) {
        defaults[.aiLyricsTranslationStatus] = message
        aiLyricsTranslationStatusField.stringValue = message
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
