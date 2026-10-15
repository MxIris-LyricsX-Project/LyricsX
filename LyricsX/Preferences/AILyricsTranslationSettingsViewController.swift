import AppKit
import LyricsXFoundation

/// The AI translation settings form, presented as a sheet.
///
/// A sheet rather than an `NSAlert` accessory view: this is five fields and a
/// destructive action, and it needs somewhere to put a line of help under each
/// one and a place to say *which* field is wrong. An alert gives neither — it
/// would have to close itself and report the failure somewhere else, which is
/// what it used to do.
///
/// Every control and every help label gets an explicit width. A sheet cannot be
/// resized by the user, so the width has to be decided here: left to their
/// intrinsic size, the help labels lay out on one unbroken line and push the
/// sheet past the edge of the screen. `preferredMaxLayoutWidth` alone does not
/// prevent that — it only takes effect once the label already has a width.
final class AILyricsTranslationSettingsViewController: NSViewController {
    /// Called once the fields validate, the key is stored and the preferences
    /// are written. `shouldTest` is true for the Save and Test button.
    var onSave: ((AILyricsTranslationConfiguration, Bool) -> Void)?

    private let endpointField = NSTextField()
    private let modelField = NSTextField()
    private let targetLanguageField = NSTextField()
    private let apiKeyField = NSSecureTextField()
    private let removeKeyButton = NSButton()
    private let promptTextView = NSTextView()
    private let problemLabel = NSTextField(labelWithString: "")

    /// Last endpoint origin the API-key placeholder was resolved against, and
    /// what that resolution found. Keeps the probe to one Keychain read per
    /// host instead of one per keystroke while the endpoint field is edited.
    private var lastProbedOrigin: String?
    private var lastProbedOriginHasKey = false

    /// The scroller's fixed height. Held so the validation row can grow the
    /// sheet when it appears — the sheet is sized before that row has any text.
    private var scrollerHeightConstraint: NSLayoutConstraint?

    private static let labelColumnWidth: CGFloat = 130
    private static let rowSpacing: CGFloat = 14
    private static let contentInset: CGFloat = 20

    /// The widest the sheet is allowed to get, narrowed further when the screen
    /// cannot take it. A sheet wider than its window is simply clipped, and a
    /// sheet cannot be resized by the user, so there is no floor here: a
    /// minimum width would be the one thing that can still overflow.
    private static var sheetWidth: CGFloat {
        let available = (NSScreen.main?.visibleFrame.width ?? 1_200) - 80
        return min(620, available)
    }

    private static var columnWidth: CGFloat {
        sheetWidth - contentInset * 2 - labelColumnWidth - 10
    }

    // MARK: - Presentation

    override func loadView() {
        let endpointValue = defaults[.aiLyricsTranslationEndpoint]
        endpointField.stringValue = endpointValue.isEmpty
            ? AILyricsTranslationPolicy.defaultEndpoint
            : endpointValue

        let modelValue = defaults[.aiLyricsTranslationModel]
        modelField.stringValue = modelValue.isEmpty
            ? AILyricsTranslationPolicy.defaultModel
            : modelValue

        let targetLanguageValue = defaults[.aiLyricsTranslationTargetLanguage]
        targetLanguageField.stringValue = targetLanguageValue.isEmpty
            ? AILyricsTranslationPolicy.defaultTargetLanguage
            : targetLanguageValue

        promptTextView.string = AILyricsTranslationPolicy.resolvedPrompt(
            defaults[.aiLyricsTranslationPrompt]
        )
        promptTextView.isRichText = false
        promptTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)

        removeKeyButton.title = NSLocalizedString(
            "Remove saved key",
            comment: "Button that deletes the stored AI translation API key from the Keychain."
        )
        removeKeyButton.bezelStyle = .rounded
        removeKeyButton.target = self
        removeKeyButton.action = #selector(removeStoredAPIKey)
        removeKeyButton.controlSize = .small
        removeKeyButton.font = .systemFont(ofSize: 11)

        problemLabel.textColor = .systemRed
        problemLabel.font = .systemFont(ofSize: 11)
        problemLabel.isHidden = true
        problemLabel.lineBreakMode = .byWordWrapping
        problemLabel.maximumNumberOfLines = 0
        problemLabel.translatesAutoresizingMaskIntoConstraints = false
        problemLabel.widthAnchor.constraint(equalToConstant: Self.columnWidth).isActive = true

        let rows = NSStackView(views: [
            makeNoteRow(NSLocalizedString(
                "Eligible lyric lines are sent to this endpoint for translation. The provider may charge for requests, and may keep what it receives.",
                comment: "Privacy and cost notice for AI lyrics translation."
            )),
            makeFieldRow(
                title: NSLocalizedString(
                    "Endpoint",
                    comment: "AI lyrics translation endpoint setting."
                ),
                control: endpointField,
                help: NSLocalizedString(
                    "The chat-completions URL that receives the lines. HTTPS is required, except for a loopback address such as http://localhost.",
                    comment: "Help text under the AI translation endpoint setting."
                )
            ),
            makeFieldRow(
                title: NSLocalizedString("Model", comment: "AI lyrics translation model setting."),
                control: modelField,
                help: NSLocalizedString(
                    "The model name this endpoint expects, for example gpt-4o-mini.",
                    comment: "Help text under the AI translation model setting."
                )
            ),
            makeFieldRow(
                title: NSLocalizedString(
                    "Target language",
                    comment: "AI lyrics translation target language setting."
                ),
                control: targetLanguageField,
                help: NSLocalizedString(
                    "A language tag such as zh-Hans, zh-Hant or ja. Lines already in this language are not sent.",
                    comment: "Help text under the AI translation target language setting."
                )
            ),
            makeFieldRow(
                title: NSLocalizedString("API key", comment: "AI lyrics translation API-key setting."),
                control: apiKeyField,
                help: NSLocalizedString(
                    "Kept in the Keychain and bound to this endpoint's host, so changing the host means saving the key again.",
                    comment: "Help text under the AI translation API-key setting."
                ),
                accessory: removeKeyButton
            ),
            makePromptRow(),
            problemLabel
        ])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = Self.rowSpacing
        rows.translatesAutoresizingMaskIntoConstraints = false

        let buttons = NSStackView(views: [
            makeButton(
                NSLocalizedString("Cancel", comment: "Cancel AI lyrics translation settings."),
                action: #selector(cancel)
            ),
            makeButton(
                NSLocalizedString("Save and Test", comment: "Save settings and test the AI lyrics translation endpoint."),
                action: #selector(saveAndTest)
            ),
            makeButton(
                NSLocalizedString("Save", comment: "Save AI lyrics translation settings."),
                action: #selector(save)
            ),
        ])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        buttons.translatesAutoresizingMaskIntoConstraints = false

        view = makeRoot(rows: rows, buttons: buttons)

        // A key is bound to its endpoint's origin, so "leave blank" only means
        // "keep the saved key" while the endpoint names a host that has one.
        // Recomputed as the endpoint is edited, since promising a keep the save
        // path will not honour sends the user hunting for a blank field while
        // the real cause is that their key belongs to the host they moved off.
        lastProbedOrigin = nil
        updateAPIKeyPlaceholder()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(endpointChanged),
            name: NSControl.textDidChangeNotification,
            object: endpointField
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Content above a fixed button row, inside a scroller so a short screen
    /// scrolls rather than clipping the bottom of the form.
    private func makeRoot(rows: NSStackView, buttons: NSStackView) -> NSView {
        let documentView = FlippedDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(rows)

        let scroller = NSScrollView()
        scroller.hasVerticalScroller = true
        scroller.drawsBackground = false
        // Overlay scrollers take no width from the clip view, so the form keeps
        // exactly the column width it was measured at. A legacy scroller would
        // narrow the document and squeeze every row and its help text.
        scroller.scrollerStyle = .overlay
        scroller.documentView = documentView
        scroller.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(scroller)
        root.addSubview(buttons)

        let maxContentHeight = (NSScreen.main?.visibleFrame.height ?? 900) - 160
        let contentHeight = rows.fittingSize.height + Self.contentInset * 2
        let visibleContentHeight = min(contentHeight, maxContentHeight)
        let buttonRowHeight = buttons.fittingSize.height
        let scrollerHeight = scroller.heightAnchor.constraint(equalToConstant: visibleContentHeight)
        scrollerHeightConstraint = scrollerHeight

        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: documentView.topAnchor, constant: Self.contentInset),
            rows.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: Self.contentInset),
            rows.trailingAnchor.constraint(lessThanOrEqualTo: documentView.trailingAnchor, constant: -Self.contentInset),
            rows.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -Self.contentInset),

            documentView.widthAnchor.constraint(equalTo: scroller.contentView.widthAnchor),

            scroller.topAnchor.constraint(equalTo: root.topAnchor),
            scroller.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroller.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollerHeight,

            buttons.topAnchor.constraint(equalTo: scroller.bottomAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.contentInset),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.contentInset),

            root.widthAnchor.constraint(equalToConstant: Self.sheetWidth),
        ])

        // Exactly what the constraint chain needs: the scroller, the gap above
        // the buttons, the button row itself, and the bottom inset. Counting a
        // stand-in for the buttons leaves the chain 4pt short and Auto Layout
        // breaks a required constraint on every presentation.
        preferredContentSize = NSSize(
            width: Self.sheetWidth,
            height: visibleContentHeight + 12 + buttonRowHeight + Self.contentInset
        )
        return root
    }

    /// A document view that reports `isFlipped`, so a form taller than the
    /// scroller opens on its first row. With a non-flipped document, AppKit
    /// leaves the clip view at coordinate zero — the bottom of the content —
    /// and the sheet would open showing its last fields.
    private final class FlippedDocumentView: NSView {
        override var isFlipped: Bool {
            true
        }
    }

    // MARK: - Building blocks

    private func makeWrappingLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: Self.columnWidth).isActive = true
        return label
    }

    /// A paragraph that belongs to the form rather than to the window: it is
    /// indented past the label column so it lines up with the fields, instead
    /// of starting at the sheet's edge with everything else stepped in.
    private func makeNoteRow(_ text: String) -> NSStackView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(equalToConstant: Self.labelColumnWidth).isActive = true

        let row = NSStackView(views: [spacer, makeWrappingLabel(text)])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 10
        return row
    }

    private func makeFieldRow(
        title: String,
        control: NSView,
        help: String,
        accessory: NSView? = nil
    ) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: Self.labelColumnWidth).isActive = true
        label.setContentHuggingPriority(.required, for: .horizontal)

        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalToConstant: Self.columnWidth).isActive = true

        // The destructive action sits under its field rather than beside it:
        // one column of fixed width, so nothing here can widen the sheet.
        var columnViews: [NSView] = [control]
        if let accessory {
            accessory.translatesAutoresizingMaskIntoConstraints = false
            let accessoryRow = NSStackView(views: [accessory])
            accessoryRow.orientation = .horizontal
            accessoryRow.alignment = .leading
            columnViews.append(accessoryRow)
        }
        columnViews.append(makeWrappingLabel(help))

        let column = NSStackView(views: columnViews)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 3

        let row = NSStackView(views: [label, column])
        row.orientation = .horizontal
        // Baseline, not top: the label is plain text against a bezeled field
        // whose text sits a few points below its edge, and top-alignment leaves
        // every label floating above the value it names.
        row.alignment = .firstBaseline
        row.spacing = 10
        return row
    }

    private func makePromptRow() -> NSStackView {
        let scroller = NSScrollView()
        scroller.borderType = .bezelBorder
        scroller.hasVerticalScroller = true
        scroller.documentView = promptTextView
        scroller.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroller.widthAnchor.constraint(equalToConstant: Self.columnWidth),
            scroller.heightAnchor.constraint(equalToConstant: 130),
        ])

        let label = NSTextField(labelWithString: NSLocalizedString(
            "Prompt",
            comment: "AI lyrics translation prompt setting."
        ))
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: Self.labelColumnWidth).isActive = true

        let column = NSStackView(views: [
            scroller,
            makeWrappingLabel(NSLocalizedString(
                "$targetLanguage is replaced with the target language's name before the request is sent.",
                comment: "Help text under the AI translation prompt setting."
            )),
        ])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 3

        let row = NSStackView(views: [label, column])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 10
        return row
    }

    private func makeButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    // MARK: - API key state

    @objc private func endpointChanged() {
        updateAPIKeyPlaceholder()
    }

    @objc private func removeStoredAPIKey() {
        do {
            try AILyricsTranslationCredentialStore.removeAPIKey()
        } catch {
            present(problem: NSLocalizedString(
                "The saved key could not be removed from the Keychain.",
                comment: "Error shown when the stored AI translation API key cannot be deleted."
            ))
            return
        }
        // The removal already happened, so the dialog must not also look as if
        // it is still holding a key.
        apiKeyField.stringValue = ""
        lastProbedOrigin = nil
        updateAPIKeyPlaceholder()
    }

    private func updateAPIKeyPlaceholder() {
        let endpointURL = URL(string: endpointField.stringValue)
        let origin = endpointURL.flatMap { AILyricsTranslationPolicy.endpointOrigin($0) }
        if origin != lastProbedOrigin {
            lastProbedOrigin = origin
            // One Keychain read per host, not one per keystroke.
            lastProbedOriginHasKey = origin == nil ? false : endpointURL.map {
                (try? AILyricsTranslationCredentialStore.hasAccessibleAPIKey(for: $0)) ?? false
            } ?? false
        }
        apiKeyField.placeholderString = lastProbedOriginHasKey
            ? NSLocalizedString(
                "Leave blank to keep the saved key",
                comment: "Placeholder for the secure AI translation API-key field when a key is already stored for this endpoint."
            )
            : NSLocalizedString(
                "API key",
                comment: "Placeholder for the secure AI translation API-key field when no key is stored for this endpoint yet."
            )
        removeKeyButton.isEnabled = lastProbedOriginHasKey
    }

    // MARK: - Actions

    @objc private func cancel() {
        dismiss(nil)
    }

    @objc private func save() {
        finish(shouldTest: false)
    }

    @objc private func saveAndTest() {
        finish(shouldTest: true)
    }

    private func finish(shouldTest: Bool) {
        let configuration: AILyricsTranslationConfiguration
        do {
            configuration = try AILyricsTranslationPolicy.configuration(
                endpoint: endpointField.stringValue,
                model: modelField.stringValue.isEmpty
                    ? AILyricsTranslationPolicy.defaultModel
                    : modelField.stringValue,
                targetLanguage: targetLanguageField.stringValue.isEmpty
                    ? AILyricsTranslationPolicy.defaultTargetLanguage
                    : targetLanguageField.stringValue,
                prompt: AILyricsTranslationPolicy.resolvedPrompt(promptTextView.string)
            )
        } catch {
            present(problem: Self.message(for: error))
            return
        }

        let newAPIKey = apiKeyField.stringValue
        if !newAPIKey.isEmpty {
            do {
                try AILyricsTranslationCredentialStore.store(apiKey: newAPIKey, for: configuration.endpoint)
            } catch {
                present(problem: NSLocalizedString(
                    "The API key could not be stored in the Keychain.",
                    comment: "Error shown when a new AI translation API key cannot be saved."
                ))
                return
            }
        }

        defaults[.aiLyricsTranslationEndpoint] = configuration.endpoint.absoluteString
        defaults[.aiLyricsTranslationModel] = configuration.model
        defaults[.aiLyricsTranslationTargetLanguage] = configuration.targetLanguage
        // Stored empty while it is still the default. Writing the default text
        // verbatim would freeze today's wording in the database, and a later
        // improvement to it would then reach only users who had never opened
        // this sheet.
        defaults[.aiLyricsTranslationPrompt] = AILyricsTranslationPolicy.resolvedPrompt(promptTextView.string)
            == AILyricsTranslationPolicy.defaultPrompt
            ? ""
            : promptTextView.string

        onSave?(configuration, shouldTest)
        dismiss(nil)
    }

    private func present(problem: String) {
        let wasHidden = problemLabel.isHidden
        problemLabel.stringValue = problem
        problemLabel.isHidden = false
        guard wasHidden else { return }
        // The sheet was sized while this row was collapsed, so it has to grow by
        // the row it just revealed. Without that the message the sheet exists to
        // show is laid out past the bottom edge of the window. The growth is
        // capped at the screen: once the form is taller than it can be, the
        // scroller is already showing and the row is reachable by scrolling.
        view.layoutSubtreeIfNeeded()
        let screenLimitedHeight = (NSScreen.main?.visibleFrame.height ?? 900) - 160
        let allowedGrowth = max(0, screenLimitedHeight - (scrollerHeightConstraint?.constant ?? 0))
        let growth = min(problemLabel.fittingSize.height + Self.rowSpacing, allowedGrowth)
        scrollerHeightConstraint?.constant += growth
        preferredContentSize = NSSize(
            width: preferredContentSize.width,
            height: preferredContentSize.height + growth
        )
    }

    private static func message(for error: Error) -> String {
        guard let error = error as? AILyricsTranslationError else {
            return NSLocalizedString(
                "These settings could not be used.",
                comment: "Generic error for invalid AI translation settings."
            )
        }
        switch error {
        case .invalidEndpoint:
            return NSLocalizedString(
                "The endpoint is not a valid URL.",
                comment: "Error shown when the AI translation endpoint is malformed."
            )
        case .insecureEndpoint:
            return NSLocalizedString(
                "Use HTTPS, or a loopback address such as http://localhost.",
                comment: "Error shown when the AI translation endpoint is plaintext and not loopback."
            )
        case .missingModel:
            return NSLocalizedString(
                "Enter a model name.",
                comment: "Error shown when no AI translation model is given."
            )
        case .missingTargetLanguage, .invalidTargetLanguage:
            return NSLocalizedString(
                "Enter a language tag such as zh-Hans or ja.",
                comment: "Error shown when the AI translation target language is not a valid language tag."
            )
        case .configurationTooLarge:
            return NSLocalizedString(
                "One of these values is too long.",
                comment: "Error shown when an AI translation setting exceeds its size limit."
            )
        case .lyricsTooLarge, .invalidResponse:
            return NSLocalizedString(
                "These settings could not be used.",
                comment: "Generic error for invalid AI translation settings."
            )
        }
    }
}
