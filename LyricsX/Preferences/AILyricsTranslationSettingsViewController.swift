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
/// Neither dimension is guessed at. The width is what the screen can take, the
/// label column is as wide as the longest label actually measures, and the
/// height is the form's own fitting size. A sheet cannot be resized by the
/// user, so a number written here that does not match reality is a number that
/// clips: a help label laid out at its unwrapped length is what pushed the last
/// version past the edge of the screen.
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
    /// Built as a wrapping label, not a plain one: `maximumNumberOfLines = 0`
    /// on its own leaves the cell clipping, and a validation message cut off
    /// mid-sentence is exactly the thing this sheet was built to show.
    private lazy var problemLabel = NSTextField(wrappingLabelWithString: "")

    /// Last endpoint origin the API-key placeholder was resolved against, and
    /// what that resolution found. Keeps the probe to one Keychain read per
    /// host instead of one per keystroke while the endpoint field is edited.
    private var lastProbedOrigin: String?
    private var lastProbedOriginHasKey = false

    /// The scroller's height, held so the validation row can grow the sheet
    /// when it appears — the sheet is sized before that row has any text.
    private var scrollerHeightConstraint: NSLayoutConstraint?

    /// How much height the validation row has already been given, so a second
    /// message grows the sheet by the difference rather than by its full
    /// height again.
    private var appliedProblemGrowth: CGFloat = 0

    private static let rowSpacing: CGFloat = 14
    private static let contentInset: CGFloat = 20
    private static let labelSpacing: CGFloat = 10
    private static let buttonGap: CGFloat = 12

    /// The width the form would like, and the room left around it for the
    /// screen. Whichever is smaller wins.
    private static let preferredWidth: CGFloat = 620
    private static let screenMargin: CGFloat = 80
    private static let screenVerticalMargin: CGFloat = 160

    private static var sheetWidth: CGFloat {
        let available = (NSScreen.main?.visibleFrame.width ?? 1_200) - screenMargin
        return min(preferredWidth, available)
    }

    // MARK: - Presentation

    override func loadView() {
        endpointField.stringValue = defaults[.aiLyricsTranslationEndpoint].isEmpty
            ? AILyricsTranslationPolicy.defaultEndpoint
            : defaults[.aiLyricsTranslationEndpoint]

        modelField.stringValue = defaults[.aiLyricsTranslationModel].isEmpty
            ? AILyricsTranslationPolicy.defaultModel
            : defaults[.aiLyricsTranslationModel]

        targetLanguageField.stringValue = defaults[.aiLyricsTranslationTargetLanguage].isEmpty
            ? AILyricsTranslationPolicy.defaultTargetLanguage
            : defaults[.aiLyricsTranslationTargetLanguage]

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

        // Measured, not assumed: the labels are localized, so the column they
        // sit in is as wide as the longest one actually is in this language.
        let titles = [
            NSLocalizedString("Endpoint", comment: "AI lyrics translation endpoint setting."),
            NSLocalizedString("Model", comment: "AI lyrics translation model setting."),
            NSLocalizedString("Target language", comment: "AI lyrics translation target language setting."),
            NSLocalizedString("API key", comment: "AI lyrics translation API-key setting."),
            NSLocalizedString("Prompt", comment: "AI lyrics translation prompt setting."),
        ]
        let labelColumnWidth = Self.widestLabelWidth(titles)

        let rows = NSStackView(views: [
            makeIndentedRow(
                makeWrappingLabel(NSLocalizedString(
                    "Eligible lyric lines are sent to this endpoint for translation. The provider may charge for requests, and may keep what it receives.",
                    comment: "Privacy and cost notice for AI lyrics translation."
                )),
                labelColumnWidth: labelColumnWidth
            ),
            makeFieldRow(
                title: titles[0],
                labelColumnWidth: labelColumnWidth,
                control: endpointField,
                help: NSLocalizedString(
                    "The chat-completions URL that receives the lines. HTTPS is required, except for a loopback address such as http://localhost.",
                    comment: "Help text under the AI translation endpoint setting."
                )
            ),
            makeFieldRow(
                title: titles[1],
                labelColumnWidth: labelColumnWidth,
                control: modelField,
                help: NSLocalizedString(
                    "The model name this endpoint expects, for example gpt-4o-mini.",
                    comment: "Help text under the AI translation model setting."
                )
            ),
            makeFieldRow(
                title: titles[2],
                labelColumnWidth: labelColumnWidth,
                control: targetLanguageField,
                help: NSLocalizedString(
                    "A language tag such as zh-Hans, zh-Hant or ja. Lines already in this language are not sent.",
                    comment: "Help text under the AI translation target language setting."
                )
            ),
            makeFieldRow(
                title: titles[3],
                labelColumnWidth: labelColumnWidth,
                control: apiKeyField,
                help: NSLocalizedString(
                    "Kept in the Keychain and bound to this endpoint's host, so changing the host means saving the key again.",
                    comment: "Help text under the AI translation API-key setting."
                ),
                accessory: removeKeyButton
            ),
            makePromptRow(title: titles[4], labelColumnWidth: labelColumnWidth),
            // Indented like everything else, so the message is read as
            // belonging to the field it names rather than to the window.
            makeIndentedRow(problemLabel, labelColumnWidth: labelColumnWidth),
        ])
        rows.orientation = .vertical
        // Every row is the stack's width, so each row's field column resolves
        // to the same width and the text inside wraps to it rather than
        // deciding the sheet's width by being long.
        rows.alignment = .width
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
        buttons.spacing = Self.buttonGap
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
        // Visible whenever there is anything to scroll, rather than only while
        // the user is already scrolling — otherwise a form that runs past the
        // bottom of the sheet gives no sign that there is more of it.
        scroller.autohidesScrollers = false
        // Overlay, so the bar it just made permanent floats over the content
        // instead of taking width from the clip view. A legacy scroller would
        // narrow the document and re-wrap every help label.
        scroller.scrollerStyle = .overlay
        scroller.documentView = documentView
        scroller.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(scroller)
        root.addSubview(buttons)

        // The scroller's height is the one thing that cannot come from the
        // content, so it starts empty and is filled in once the form has been
        // measured at its real width.
        let scrollerHeight = scroller.heightAnchor.constraint(equalToConstant: 0)
        scrollerHeightConstraint = scrollerHeight

        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: documentView.topAnchor, constant: Self.contentInset),
            rows.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: Self.contentInset),
            rows.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -Self.contentInset),
            rows.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -Self.contentInset),

            documentView.widthAnchor.constraint(equalTo: scroller.contentView.widthAnchor),

            scroller.topAnchor.constraint(equalTo: root.topAnchor),
            scroller.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroller.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollerHeight,

            buttons.topAnchor.constraint(equalTo: scroller.bottomAnchor, constant: Self.buttonGap),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.contentInset),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.contentInset),

            root.widthAnchor.constraint(equalToConstant: Self.sheetWidth),
        ])

        // Measure at the width it will actually be shown at, then take the
        // height from what came back rather than from a running total.
        root.layoutSubtreeIfNeeded()
        let contentHeight = rows.fittingSize.height + Self.contentInset * 2
        let screenLimitedHeight = (NSScreen.main?.visibleFrame.height ?? 900) - Self.screenVerticalMargin
        scrollerHeight.constant = min(contentHeight, screenLimitedHeight)
        root.layoutSubtreeIfNeeded()

        preferredContentSize = root.fittingSize
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

    private static func widestLabelWidth(_ titles: [String]) -> CGFloat {
        return titles.reduce(0) { width, title in
            max(width, NSTextField(labelWithString: title).intrinsicContentSize.width)
        }
    }

    /// A row that belongs to the form rather than to the window: indented past
    /// the label column so it lines up with the fields, instead of starting at
    /// the sheet's edge with everything else stepped in.
    private func makeIndentedRow(_ content: NSView, labelColumnWidth: CGFloat) -> NSStackView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(equalToConstant: labelColumnWidth).isActive = true

        content.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [spacer, content])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = Self.labelSpacing
        return row
    }

    private func makeWrappingLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        // The column decides the width; this label takes what it is given and
        // wraps. Left to its own intrinsic width it would be one unbroken line
        // and set the sheet's width from its own length.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func makeFieldRow(
        title: String,
        labelColumnWidth: CGFloat,
        control: NSView,
        help: String,
        accessory: NSView? = nil
    ) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: labelColumnWidth).isActive = true
        label.setContentHuggingPriority(.required, for: .horizontal)

        var columnViews: [NSView] = [control]
        if let accessory {
            // The destructive action sits under its field rather than beside
            // it, so the field column is the same width on every row.
            let accessoryRow = NSStackView(views: [accessory])
            accessoryRow.orientation = .horizontal
            accessoryRow.alignment = .leading
            columnViews.append(accessoryRow)
        }
        columnViews.append(makeWrappingLabel(help))

        let column = NSStackView(views: columnViews)
        column.orientation = .vertical
        column.alignment = .width
        column.spacing = 3

        let row = NSStackView(views: [label, column])
        row.orientation = .horizontal
        // Baseline, not top: the label is plain text against a bezeled field
        // whose text sits a few points below its edge, and top-alignment leaves
        // every label floating above the value it names.
        row.alignment = .firstBaseline
        row.spacing = Self.labelSpacing
        return row
    }

    private func makePromptRow(title: String, labelColumnWidth: CGFloat) -> NSStackView {
        let scroller = NSScrollView()
        scroller.borderType = .bezelBorder
        scroller.hasVerticalScroller = true
        scroller.documentView = promptTextView
        scroller.translatesAutoresizingMaskIntoConstraints = false
        scroller.heightAnchor.constraint(equalToConstant: 130).isActive = true

        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: labelColumnWidth).isActive = true
        label.setContentHuggingPriority(.required, for: .horizontal)

        let column = NSStackView(views: [
            scroller,
            makeWrappingLabel(NSLocalizedString(
                "$targetLanguage is replaced with the target language's name before the request is sent.",
                comment: "Help text under the AI translation prompt setting."
            )),
        ])
        column.orientation = .vertical
        column.alignment = .width
        column.spacing = 3

        let row = NSStackView(views: [label, column])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = Self.labelSpacing
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
                prompt: promptTextView.string
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
        problemLabel.stringValue = problem
        problemLabel.isHidden = false
        // The sheet was sized while this row was collapsed, so it has to grow by
        // the row it just revealed. Grown by what it needs *now* rather than by
        // what the first message needed: a later one can wrap to more lines, and
        // the shortfall would land below the fold of a scroller that draws no
        // scrollbar — a rejected Save that looks like nothing happened. The
        // growth is capped at the screen, where the scroller takes over.
        view.layoutSubtreeIfNeeded()
        let required = problemLabel.fittingSize.height + Self.rowSpacing
        let additional = required - appliedProblemGrowth
        guard additional > 0 else { return }
        let available = (NSScreen.main?.visibleFrame.height ?? 900) - Self.screenVerticalMargin
        let growth = min(additional, max(0, available - (scrollerHeightConstraint?.constant ?? 0)))
        appliedProblemGrowth += growth
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
