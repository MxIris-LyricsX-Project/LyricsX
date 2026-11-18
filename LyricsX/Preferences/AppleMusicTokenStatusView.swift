import AppKit
import LyricsXFoundation

/// The row under the Apple Music token field in the Lab pane: where the
/// token check stands, in a symbol and a line or two of text, and a button
/// that checks again.
///
/// Users who pasted a `media-user-token` had no way to tell whether Apple
/// Music accepted it (issue #223). The text keeps "Apple Music lyrics" in
/// every state, because the token turns on Apple Music lyrics and nothing
/// else — not the MusicKit name recovery above it.
final class AppleMusicTokenStatusView: NSView {
    /// Runs when the user clicks "Check Again".
    var checkAgainHandler: (() -> Void)?

    private let symbolView = NSImageView()
    private let progressIndicator = NSProgressIndicator()
    private let messageField = NSTextField(wrappingLabelWithString: "")
    private let checkAgainButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: NSFont.smallSystemFontSize + 1, weight: .regular)
        symbolView.setContentHuggingPriority(.required, for: .horizontal)

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        messageField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        messageField.textColor = .secondaryLabelColor
        messageField.maximumNumberOfLines = 2
        messageField.cell?.truncatesLastVisibleLine = true
        messageField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        messageField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        checkAgainButton.title = NSLocalizedString(
            "Check Again",
            comment: "Button under the Apple Music token field in the Lab pane that checks the token with Apple Music again."
        )
        checkAgainButton.bezelStyle = .rounded
        checkAgainButton.controlSize = .small
        checkAgainButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        checkAgainButton.target = self
        checkAgainButton.action = #selector(checkAgain(_:))
        checkAgainButton.setContentHuggingPriority(.required, for: .horizontal)
        checkAgainButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stackView = NSStackView(views: [symbolView, progressIndicator, messageField, checkAgainButton])
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 6
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
            symbolView.widthAnchor.constraint(equalToConstant: 16),
            symbolView.heightAnchor.constraint(equalToConstant: 16),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(NSLocalizedString(
            "Apple Music token status",
            comment: "Accessibility label of the row under the Apple Music token field in the Lab pane that says whether Apple Music accepted the token."
        ))

        show(.noToken)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AppleMusicTokenStatusView is built in code.")
    }

    override func layout() {
        super.layout()
        // A wrapping label measures its height for the width it was given
        // last; give it the width the stack view settled on.
        if messageField.preferredMaxLayoutWidth != messageField.frame.width {
            messageField.preferredMaxLayoutWidth = messageField.frame.width
            messageField.invalidateIntrinsicContentSize()
        }
    }

    func show(_ check: AppleMusicTokenCheck) {
        let message: String
        var toolTip: String?
        switch check {
        case .noToken:
            showSymbol(nil)
            message = NSLocalizedString(
                "Paste a token to turn on Apple Music lyrics.",
                comment: "Under the Apple Music token field in the Lab pane while it is empty."
            )
        case .checking:
            showSymbol(nil)
            message = NSLocalizedString(
                "Checking token…",
                comment: "Under the Apple Music token field in the Lab pane while Apple Music is being asked whether it accepts the token."
            )
        case .finished(.authorized(let storefront)):
            showSymbol("checkmark.circle.fill", tintColor: .systemGreen)
            message = String(
                format: NSLocalizedString(
                    "Valid. Apple Music lyrics are on (region: %@).",
                    comment: "Under the Apple Music token field in the Lab pane when Apple Music accepted the token. The argument is the region of the Apple Music account, such as Japan."
                ),
                AppleMusicTokenCheck.regionName(forStorefront: storefront)
            )
        case .finished(.denied):
            showSymbol("xmark.circle.fill", tintColor: .systemRed)
            message = NSLocalizedString(
                "Apple Music rejected this token. Copy it again from music.apple.com while signed in.",
                comment: "Under the Apple Music token field in the Lab pane when Apple Music refused the token."
            )
        case .finished(.couldNotDetermine(let reason)):
            showSymbol("exclamationmark.triangle.fill", tintColor: .systemOrange)
            message = NSLocalizedString(
                "Couldn't check the token. Apple Music lyrics stay off until a check succeeds.",
                comment: "Under the Apple Music token field in the Lab pane when Apple Music could not be asked, for example without a network connection."
            )
            toolTip = message + "\n\n" + reason
        }

        if check == .checking {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }
        messageField.stringValue = message
        messageField.toolTip = toolTip ?? message
        setAccessibilityValue(message)

        switch check {
        case .noToken, .checking:
            checkAgainButton.isHidden = true
        case .finished:
            checkAgainButton.isHidden = false
        }
    }

    private func showSymbol(_ symbolName: String?, tintColor: NSColor? = nil) {
        guard let symbolName else {
            symbolView.image = nil
            symbolView.isHidden = true
            return
        }
        symbolView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        symbolView.contentTintColor = tintColor
        symbolView.isHidden = false
    }

    @objc private func checkAgain(_ sender: NSButton) {
        checkAgainHandler?()
    }
}
