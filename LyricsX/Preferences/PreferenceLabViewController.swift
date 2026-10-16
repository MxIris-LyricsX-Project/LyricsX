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
        // One line, truncating: the box reserves exactly one line for the
        // status, so a wrapping field would make the status area grow and
        // shrink with every message.
        aiLyricsTranslationStatusField.cell?.wraps = false
        aiLyricsTranslationStatusField.cell?.usesSingleLineMode = true
        refreshAILyricsTranslationStatusField()
        defaultsObservation = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshAILyricsTranslationStatusField()
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
        let settings = AILyricsTranslationSettingsViewController()
        settings.onSave = { [weak self] configuration, shouldTest in
            AppController.shared.retryAILyricsTranslation()

            if shouldTest {
                self?.testAITranslationConnection(configuration: configuration)
            }
        }
        presentAsSheet(settings)
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
                    configuration: configuration,
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
                updateAILyricsTranslationStatus(Self.connectionFailureMessage(for: error))
            }
        }
    }

    /// Says what actually failed. One generic sentence sent the user hunting
    /// through three settings when the endpoint had answered 401.
    private static func connectionFailureMessage(for error: Error) -> String {
        if let error = error as? OpenAICompatibleLyricsTranslatorError {
            switch error {
            case .httpStatus(let status):
                return String(
                    format: NSLocalizedString(
                        "The endpoint answered HTTP %d.",
                        comment: "Status shown when the AI translation endpoint test gets a non-2xx answer; %d is the HTTP status code."
                    ),
                    status
                )
            case .responseTooLarge:
                return NSLocalizedString(
                    "The endpoint's answer was too large to read.",
                    comment: "Status shown when the AI translation endpoint test gets an oversized answer."
                )
            case .invalidResponse:
                return NSLocalizedString(
                    "The endpoint did not answer with a translation. It may not support JSON mode.",
                    comment: "Status shown when the AI translation endpoint test gets a well-formed HTTP answer that is not a translation."
                )
            }
        }
        if let error = error as? URLError {
            return String(
                format: NSLocalizedString(
                    "The request failed: %@",
                    comment: "Status shown when the AI translation endpoint test fails at the network layer; %@ is the system's description."
                ),
                error.localizedDescription
            )
        }
        return error.localizedDescription
    }

    private func updateAILyricsTranslationStatus(_ message: String) {
        defaults[.aiLyricsTranslationStatus] = message
        refreshAILyricsTranslationStatusField()
    }

    private func refreshAILyricsTranslationStatusField() {
        let status = defaults[.aiLyricsTranslationStatus]
        aiLyricsTranslationStatusField.stringValue = status
        // The field is one line, so the tooltip carries the whole message for
        // whichever translation is too long to fit.
        aiLyricsTranslationStatusField.toolTip = status.isEmpty ? nil : status
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
