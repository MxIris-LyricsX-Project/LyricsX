import AppKit
import LyricsXFoundation

class PreferenceLabViewController: PreferenceViewController {
    @IBOutlet var enableTouchBarLyricsButton: NSButton!
    @IBOutlet var enableAITranslationButton: NSButton!

    @IBOutlet var musixmatchTokenField: NSTextField!

    override func viewDidLoad() {
        super.viewDidLoad()
        
        enableTouchBarLyricsButton.bind(.value, withDefaultName: .touchBarLyricsEnabled)
        enableAITranslationButton.bind(.value, withDefaultName: .aiLyricsTranslationEnabled)

        if let token = defaults[.musixmatchToken] {
            musixmatchTokenField.stringValue = token
        } else {
            musixmatchTokenField.stringValue = ""
        }

    }

    @IBAction func toggleAITranslationAction(_ sender: NSButton) {
        guard sender.state == .on else {
            defaults[.aiLyricsTranslationEnabled] = false
            AILyricsTranslationCredentialStore.clearSessionCache()
            AppController.shared.cancelAITranslation()
            return
        }

        let configuration = try? AILyricsTranslationPolicy.configuration(
            endpoint: defaults[.aiLyricsTranslationEndpoint],
            model: defaults[.aiLyricsTranslationModel],
            targetLanguage: defaults[.aiLyricsTranslationTargetLanguage],
            prompt: defaults[.aiLyricsTranslationPrompt]
        )
        if let configuration,
           (try? AILyricsTranslationCredentialStore.hasAccessibleAPIKey(
               for: configuration.endpoint,
               allowingAuthenticationUI: true
           )) == true {
            defaults[.aiLyricsTranslationEnabled] = true
            AppController.shared.scheduleAITranslationForCurrentLyrics()
            return
        }

        // Do not leave the feature in a misleading enabled-but-unconfigured state.
        defaults[.aiLyricsTranslationEnabled] = false
        sender.state = .off
        presentAITranslationConfiguration(requiresAPIKey: true) { [weak self] in
            defaults[.aiLyricsTranslationEnabled] = true
            self?.enableAITranslationButton.state = .on
            AppController.shared.scheduleAITranslationForCurrentLyrics()
        }
    }

    @IBAction func configureAITranslationAction(_ sender: Any) {
        presentAITranslationConfiguration(requiresAPIKey: false)
    }

    private func presentAITranslationConfiguration(
        requiresAPIKey: Bool,
        onSave: (() -> Void)? = nil
    ) {
        presentAsSheet(AITranslationConfigurationViewController(
            requiresAPIKey: requiresAPIKey,
            onSave: onSave
        ))
    }

    @IBAction func musixmatchTokenChanged(_ sender: NSTextField) {
        let value = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            defaults.remove(.musixmatchToken)
        } else {
            defaults[.musixmatchToken] = value
        }
        
        // Update lyrics manager when token changes
        Task { @MainActor in
            try await AppController.shared.updateLyricsManager()
        }
    }

    @IBAction func customizeAllowsNowPlayingApplicationsAction(_ sender: NSButton) {
        let viewController = NowPlayingApplicationListViewController()
        viewController.preferredContentSize = .init(width: 600, height: 500)
        presentAsSheet(viewController)
    }

    @IBAction func customizeTouchBarAction(_ sender: NSButton) {
        NSApplication.shared.toggleTouchBarCustomizationPalette(sender)
    }
}

private final class AITranslationConfigurationViewController: NSViewController {
    private let endpointField = NSTextField(string: defaults[.aiLyricsTranslationEndpoint])
    private let modelField = NSTextField(string: defaults[.aiLyricsTranslationModel])
    private let targetLanguageField = NSTextField(string: defaults[.aiLyricsTranslationTargetLanguage])
    private let apiKeyField = NSSecureTextField(frame: .zero)
    private let promptTextView = NSTextView(frame: .zero)
    private let apiKeyStatusLabel = NSTextField(labelWithString: "")
    private lazy var testEndpointButton: NSButton = {
        let button = NSButton(
            title: NSLocalizedString("Test", comment: "Test AI endpoint button"),
            target: self,
            action: #selector(testEndpoint(_:))
        )
        button.bezelStyle = .rounded
        return button
    }()

    private let requiresAPIKey: Bool
    private let onSave: (() -> Void)?
    private var hasStoredAPIKey = false
    private var endpointTestTask: Task<Void, Never>?

    init(requiresAPIKey: Bool, onSave: (() -> Void)?) {
        self.requiresAPIKey = requiresAPIKey
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        endpointTestTask?.cancel()
    }

    override func loadView() {
        preferredContentSize = NSSize(width: 660, height: 610)
        view = NSView(frame: NSRect(origin: .zero, size: preferredContentSize))

        let titleLabel = NSTextField(labelWithString: NSLocalizedString(
            "AI Lyrics Translation",
            comment: "AI translation configuration title"
        ))
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)

        let descriptionLabel = wrappingLabel(NSLocalizedString(
            "When enabled, LyricsX translates lyric lines that do not already include the configured target language.",
            comment: "AI translation configuration description"
        ))
        descriptionLabel.textColor = .secondaryLabelColor

        endpointField.placeholderString = AILyricsTranslationPolicy.defaultEndpoint
        endpointField.identifier = NSUserInterfaceItemIdentifier("AILyricsTranslation.Endpoint")
        modelField.placeholderString = AILyricsTranslationPolicy.defaultModel
        modelField.identifier = NSUserInterfaceItemIdentifier("AILyricsTranslation.Model")
        targetLanguageField.placeholderString = AILyricsTranslationPolicy.defaultTargetLanguage
        targetLanguageField.identifier = NSUserInterfaceItemIdentifier("AILyricsTranslation.TargetLanguage")

        apiKeyField.placeholderString = NSLocalizedString(
            "Enter a new API key",
            comment: "AI translation API key placeholder"
        )
        apiKeyField.identifier = NSUserInterfaceItemIdentifier("AILyricsTranslation.APIKey")

        promptTextView.string = defaults[.aiLyricsTranslationPrompt]
        promptTextView.font = .systemFont(ofSize: NSFont.systemFontSize)
        promptTextView.isRichText = false
        promptTextView.isAutomaticQuoteSubstitutionEnabled = false
        promptTextView.isAutomaticDashSubstitutionEnabled = false
        promptTextView.isHorizontallyResizable = false
        promptTextView.isVerticallyResizable = true
        promptTextView.autoresizingMask = [.width]
        promptTextView.minSize = NSSize(width: 0, height: 190)
        promptTextView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        promptTextView.frame = NSRect(x: 0, y: 0, width: 430, height: 190)
        promptTextView.textContainerInset = NSSize(width: 5, height: 5)
        promptTextView.textContainer?.containerSize = NSSize(
            width: 430,
            height: CGFloat.greatestFiniteMagnitude
        )
        promptTextView.textContainer?.widthTracksTextView = true
        promptTextView.backgroundColor = .textBackgroundColor
        promptTextView.textColor = .textColor
        promptTextView.identifier = NSUserInterfaceItemIdentifier("AILyricsTranslation.Prompt")
        updateAPIKeyStatus()

        let promptScrollView = NSScrollView(frame: .zero)
        promptScrollView.borderType = .bezelBorder
        promptScrollView.hasVerticalScroller = true
        promptScrollView.documentView = promptTextView

        let keychainNote = wrappingLabel(NSLocalizedString(
            "The API key is stored in macOS Keychain and bound to this server. Changing to another server requires entering the key again. It is never written to LyricsX preferences or logs.",
            comment: "AI translation Keychain security note"
        ))
        keychainNote.textColor = .secondaryLabelColor
        keychainNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let endpointNote = wrappingLabel(NSLocalizedString(
            "Use the full Chat Completions endpoint. HTTPS is required except for localhost. Testing sends a minimal request using the configured model.",
            comment: "AI translation endpoint security note"
        ))
        endpointNote.textColor = .secondaryLabelColor
        endpointNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let targetLanguageNote = wrappingLabel(NSLocalizedString(
            "Use a BCP-47 language tag, such as zh-Hans, ja, or en.",
            comment: "AI translation target language note"
        ))
        targetLanguageNote.textColor = .secondaryLabelColor
        targetLanguageNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let promptVariablesNote = wrappingLabel(NSLocalizedString(
            "LyricsX replaces $targetLanguage with the target language configured above, such as Chinese, Simplified (zh-Hans).",
            comment: "AI translation prompt variables note"
        ))
        promptVariablesNote.textColor = .secondaryLabelColor
        promptVariablesNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let removeKeyButton = NSButton(
            title: NSLocalizedString("Remove API Key", comment: "Remove stored AI API key button"),
            target: self,
            action: #selector(removeAPIKey(_:))
        )
        removeKeyButton.bezelStyle = .rounded

        let cancelButton = NSButton(
            title: NSLocalizedString("Cancel", comment: "Cancel AI translation settings"),
            target: self,
            action: #selector(cancel(_:))
        )
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        let saveButton = NSButton(
            title: NSLocalizedString("Save", comment: "Save AI translation settings"),
            target: self,
            action: #selector(save(_:))
        )
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        let buttonStack = NSStackView(views: [removeKeyButton, NSView(), cancelButton, saveButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8

        let labels = [
            fieldLabel(NSLocalizedString("Endpoint:", comment: "AI translation endpoint label")),
            fieldLabel(NSLocalizedString("Model:", comment: "AI translation model label")),
            fieldLabel(NSLocalizedString("Target language:", comment: "AI translation target language label")),
            fieldLabel(NSLocalizedString("API Key:", comment: "AI translation API key label")),
            fieldLabel(NSLocalizedString("Prompt:", comment: "AI translation prompt label")),
        ]
        let keyFieldStack = NSStackView(views: [apiKeyField, apiKeyStatusLabel])
        keyFieldStack.orientation = .horizontal
        keyFieldStack.spacing = 8
        let endpointFieldStack = NSStackView(views: [endpointField, testEndpointButton])
        endpointFieldStack.orientation = .horizontal
        endpointFieldStack.alignment = .centerY
        endpointFieldStack.spacing = 8
        endpointField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        testEndpointButton.setContentHuggingPriority(.required, for: .horizontal)

        let grid = NSGridView(views: [
            [labels[0], endpointFieldStack],
            [NSView(), endpointNote],
            [labels[1], modelField],
            [labels[2], targetLanguageField],
            [NSView(), targetLanguageNote],
            [labels[3], keyFieldStack],
            [NSView(), keychainNote],
            [labels[4], promptScrollView],
            [NSView(), promptVariablesNote],
        ])
        grid.columnSpacing = 12
        grid.rowSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.row(at: 7).height = 190
        grid.row(at: 7).yPlacement = .fill

        for subview in [titleLabel, descriptionLabel, grid, buttonStack] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        promptScrollView.translatesAutoresizingMaskIntoConstraints = false
        endpointField.translatesAutoresizingMaskIntoConstraints = false
        testEndpointButton.translatesAutoresizingMaskIntoConstraints = false
        modelField.translatesAutoresizingMaskIntoConstraints = false
        targetLanguageField.translatesAutoresizingMaskIntoConstraints = false
        apiKeyField.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 22),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),

            descriptionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            descriptionLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            descriptionLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            grid.topAnchor.constraint(equalTo: descriptionLabel.bottomAnchor, constant: 18),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            endpointField.widthAnchor.constraint(greaterThanOrEqualToConstant: 330),
            testEndpointButton.widthAnchor.constraint(equalToConstant: 92),
            apiKeyField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
            promptScrollView.heightAnchor.constraint(equalToConstant: 190),

            buttonStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            buttonStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            buttonStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
        ])
    }

    private func updateAPIKeyStatus() {
        let endpoint: URL
        do {
            endpoint = try AILyricsTranslationPolicy.validatedEndpoint(endpointField.stringValue)
        } catch {
            hasStoredAPIKey = false
            apiKeyStatusLabel.stringValue = NSLocalizedString(
                "Invalid endpoint",
                comment: "Invalid AI endpoint status"
            )
            apiKeyStatusLabel.textColor = .systemRed
            return
        }

        do {
            // Validate that the item is actually readable while explicitly suppressing
            // authentication UI. Existence alone is insufficient after a signer or
            // Keychain ACL change.
            hasStoredAPIKey = try AILyricsTranslationCredentialStore.hasAccessibleAPIKey(
                for: endpoint
            )
            apiKeyStatusLabel.stringValue = hasStoredAPIKey
                ? NSLocalizedString("Stored in Keychain", comment: "AI API key stored status")
                : NSLocalizedString("Not stored", comment: "AI API key missing status")
            apiKeyStatusLabel.textColor = .secondaryLabelColor
        } catch {
            hasStoredAPIKey = false
            apiKeyStatusLabel.stringValue = NSLocalizedString(
                "Keychain unavailable",
                comment: "AI API key Keychain error status"
            )
            apiKeyStatusLabel.textColor = .systemRed
        }
    }

    @objc private func testEndpoint(_ sender: NSButton) {
        endpointTestTask?.cancel()
        sender.isEnabled = false
        sender.title = NSLocalizedString("Testing…", comment: "Testing AI endpoint button")

        endpointTestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.testEndpointButton.isEnabled = true
                self.testEndpointButton.title = NSLocalizedString(
                    "Test",
                    comment: "Test AI endpoint button"
                )
                self.endpointTestTask = nil
            }

            do {
                let configuration = try AILyricsTranslationPolicy.configuration(
                    endpoint: self.endpointField.stringValue,
                    model: self.modelField.stringValue,
                    targetLanguage: AILyricsTranslationPolicy.defaultTargetLanguage,
                    prompt: "Connection test"
                )

                let enteredAPIKey = self.apiKeyField.stringValue
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let apiKey: String?
                if enteredAPIKey.isEmpty {
                    apiKey = try AILyricsTranslationCredentialStore.apiKey(
                        for: configuration.endpoint,
                        allowingAuthenticationUI: true
                    )
                } else {
                    apiKey = try AILyricsTranslationCredentialStore.validatedAPIKey(
                        enteredAPIKey
                    )
                }

                guard let apiKey else {
                    self.showAlert(
                        message: NSLocalizedString(
                            "Could not test the endpoint.",
                            comment: "AI endpoint test failure title"
                        ),
                        information: NSLocalizedString(
                            "Enter a new API key",
                            comment: "AI translation API key placeholder"
                        )
                    )
                    return
                }

                try await OpenAICompatibleLyricsTranslator().testConnection(
                    endpoint: configuration.endpoint,
                    model: configuration.model,
                    apiKey: apiKey
                )
                try Task.checkCancellation()
                self.showAlert(
                    message: NSLocalizedString(
                        "Connection successful",
                        comment: "AI endpoint test success title"
                    ),
                    information: NSLocalizedString(
                        "The endpoint accepted a Chat Completions request for the configured model.",
                        comment: "AI endpoint test success detail"
                    ),
                    style: .informational
                )
            } catch is CancellationError {
                return
            } catch let error as AILyricsTranslationError {
                self.showValidationError(error)
            } catch let error as AILyricsTranslationCredentialError {
                let information: String
                switch error {
                case .invalidStoredValue:
                    information = NSLocalizedString(
                        "Enter a valid API key.",
                        comment: "Invalid AI API key validation"
                    )
                case .keychain:
                    information = NSLocalizedString(
                        "Check Keychain access and try again.",
                        comment: "AI API key save recovery suggestion"
                    )
                }
                self.showAlert(
                    message: NSLocalizedString(
                        "Could not test the endpoint.",
                        comment: "AI endpoint test failure title"
                    ),
                    information: information
                )
            } catch let error as OpenAICompatibleLyricsTranslatorError {
                let information: String
                switch error {
                case .httpStatus(let statusCode):
                    information = String.localizedStringWithFormat(
                        NSLocalizedString(
                            "The endpoint returned HTTP %d.",
                            comment: "AI endpoint HTTP failure detail"
                        ),
                        statusCode
                    )
                case .invalidResponse:
                    information = NSLocalizedString(
                        "The endpoint returned an invalid Chat Completions response.",
                        comment: "AI endpoint invalid response detail"
                    )
                case .responseTooLarge:
                    information = NSLocalizedString(
                        "The endpoint response exceeded the size limit.",
                        comment: "AI endpoint oversized response detail"
                    )
                }
                self.showAlert(
                    message: NSLocalizedString(
                        "Could not test the endpoint.",
                        comment: "AI endpoint test failure title"
                    ),
                    information: information
                )
            } catch {
                self.showAlert(
                    message: NSLocalizedString(
                        "Could not test the endpoint.",
                        comment: "AI endpoint test failure title"
                    ),
                    information: error.localizedDescription
                )
            }
        }
    }

    @objc private func save(_ sender: Any) {
        do {
            let configuration = try AILyricsTranslationPolicy.configuration(
                endpoint: endpointField.stringValue,
                model: modelField.stringValue,
                targetLanguage: targetLanguageField.stringValue,
                prompt: promptTextView.string
            )
            let newAPIKey = apiKeyField.stringValue
            let trimmedAPIKey = newAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let previousEndpointOrigin = URL(string: defaults[.aiLyricsTranslationEndpoint])
                .flatMap(AILyricsTranslationPolicy.endpointOrigin)
            let endpointOrigin = AILyricsTranslationPolicy.endpointOrigin(configuration.endpoint)
            let hasStoredAPIKeyForEndpoint = (try? AILyricsTranslationCredentialStore
                .hasAccessibleAPIKey(for: configuration.endpoint)) == true
            if (requiresAPIKey || defaults[.aiLyricsTranslationEnabled]),
               !hasStoredAPIKeyForEndpoint,
               trimmedAPIKey.isEmpty {
                showAlert(
                    message: NSLocalizedString("Could not save the API key.", comment: "AI API key save error"),
                    information: NSLocalizedString("Enter a new API key", comment: "AI translation API key placeholder")
                )
                return
            }
            if !trimmedAPIKey.isEmpty {
                try AILyricsTranslationCredentialStore.store(
                    apiKey: trimmedAPIKey,
                    for: configuration.endpoint
                )
                hasStoredAPIKey = true
            } else if previousEndpointOrigin != endpointOrigin {
                AILyricsTranslationCredentialStore.clearSessionCache()
            }
            defaults[.aiLyricsTranslationEndpoint] = endpointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults[.aiLyricsTranslationModel] = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults[.aiLyricsTranslationTargetLanguage] = configuration.targetLanguage
            defaults[.aiLyricsTranslationPrompt] = promptTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            dismiss(sender)
            if let onSave {
                onSave()
            } else {
                AppController.shared.scheduleAITranslationForCurrentLyrics()
            }
        } catch let error as AILyricsTranslationError {
            showValidationError(error)
        } catch {
            showAlert(
                message: NSLocalizedString("Could not save the API key.", comment: "AI API key save error"),
                information: NSLocalizedString(
                    "Check Keychain access and try again.",
                    comment: "AI API key save recovery suggestion"
                )
            )
        }
    }

    @objc private func removeAPIKey(_ sender: Any) {
        defaults[.aiLyricsTranslationEnabled] = false
        AppController.shared.cancelAITranslation()
        do {
            try AILyricsTranslationCredentialStore.removeAPIKey()
            apiKeyField.stringValue = ""
            updateAPIKeyStatus()
        } catch {
            showAlert(
                message: NSLocalizedString("Could not remove the API key.", comment: "AI API key removal error"),
                information: NSLocalizedString(
                    "Check Keychain access and try again.",
                    comment: "AI API key removal recovery suggestion"
                )
            )
        }
    }

    @objc private func cancel(_ sender: Any) {
        dismiss(sender)
    }

    private func showValidationError(_ error: AILyricsTranslationError) {
        let information: String
        switch error {
        case .invalidEndpoint:
            information = NSLocalizedString(
                "Enter a valid full Chat Completions endpoint.",
                comment: "Invalid AI endpoint validation"
            )
        case .insecureEndpoint:
            information = NSLocalizedString(
                "Use HTTPS. Plain HTTP is allowed only for localhost.",
                comment: "Insecure AI endpoint validation"
            )
        case .missingModel:
            information = NSLocalizedString("Enter a model name.", comment: "Missing AI model validation")
        case .missingTargetLanguage:
            information = NSLocalizedString(
                "Enter a target language.",
                comment: "Missing AI target language validation"
            )
        case .invalidTargetLanguage:
            information = NSLocalizedString(
                "Enter a valid BCP-47 target language tag.",
                comment: "Invalid AI target language validation"
            )
        case .missingPrompt:
            information = NSLocalizedString("Enter a translation prompt.", comment: "Missing AI prompt validation")
        default:
            information = NSLocalizedString(
                "Review the translation settings and try again.",
                comment: "Generic AI settings validation"
            )
        }
        showAlert(
            message: NSLocalizedString("Invalid AI translation settings", comment: "AI settings validation title"),
            information: information
        )
    }

    private func showAlert(
        message: String,
        information: String,
        style: NSAlert.Style = .warning
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = information
        alert.alertStyle = style
        alert.beginSheetModal(for: view.window!)
    }

    private func fieldLabel(_ value: String) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.alignment = .right
        return label
    }

    private func wrappingLabel(_ value: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: value)
        label.maximumNumberOfLines = 0
        return label
    }
}
