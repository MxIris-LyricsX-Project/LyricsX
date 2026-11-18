import AppKit

/// A row that reports where something stands: a symbol or a spinner, a
/// message of up to two lines, and a button that can sit beside it.
///
/// The Lab pane puts one under the Apple Music token field. The row knows
/// nothing about what it reports; the caller passes the words in, already
/// localized.
public final class StatusMessageRowView: NSView {
    /// What sits before the message.
    public enum Indicator: Hashable {
        case none
        /// A small spinner, for something still running.
        case progress
        /// An SF Symbol in a colour.
        case symbol(name: String, tintColor: NSColor)
    }

    /// Runs when the user clicks the button.
    public var buttonHandler: (() -> Void)?

    private let symbolView = NSImageView()
    private let progressIndicator = NSProgressIndicator()
    private let messageField = WidthFollowingLabel(wrappingLabelWithString: "")
    private let button = NSButton()

    public init(buttonTitle: String) {
        super.init(frame: .zero)

        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: NSFont.smallSystemFontSize + 1, weight: .regular)
        symbolView.setContentHuggingPriority(.required, for: .horizontal)

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.setContentHuggingPriority(.required, for: .horizontal)

        messageField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        messageField.textColor = .secondaryLabelColor
        messageField.maximumNumberOfLines = 2
        messageField.cell?.truncatesLastVisibleLine = true
        messageField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        button.title = buttonTitle
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.target = self
        button.action = #selector(buttonClicked(_:))
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stackView = NSStackView(views: [symbolView, progressIndicator, messageField, button])
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        // The message takes whatever width the symbol and the button leave.
        stackView.distribution = .fill
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

        show(.none, message: "", showsButton: false)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("StatusMessageRowView is built in code.")
    }

    /// Shows `message` after `indicator`. The tooltip is `toolTip`, or the
    /// message itself, so a message cut short at two lines can still be read.
    public func show(_ indicator: Indicator, message: String, toolTip: String? = nil, showsButton: Bool) {
        switch indicator {
        case .none:
            symbolView.image = nil
            symbolView.isHidden = true
            progressIndicator.stopAnimation(nil)
        case .progress:
            symbolView.image = nil
            symbolView.isHidden = true
            progressIndicator.startAnimation(nil)
        case .symbol(let name, let tintColor):
            symbolView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            symbolView.contentTintColor = tintColor
            symbolView.isHidden = false
            progressIndicator.stopAnimation(nil)
        }
        messageField.stringValue = message
        messageField.toolTip = toolTip ?? message
        setAccessibilityValue(message)
        button.isHidden = !showsButton
    }

    @objc private func buttonClicked(_ sender: NSButton) {
        buttonHandler?()
    }
}

/// A wrapping label whose height follows the width its container gives it.
///
/// It reports no width of its own, so the container alone decides how wide
/// it is, and a new width only ever changes its height. Feeding the width
/// back as `preferredMaxLayoutWidth` from `layout()` instead let the width
/// and the line breaks keep changing each other, and AppKit gave up on the
/// window's constraints with an exception.
private final class WidthFollowingLabel: NSTextField {
    override var intrinsicContentSize: NSSize {
        guard let cell else { return super.intrinsicContentSize }
        let bounds = NSRect(x: 0, y: 0, width: bounds.width, height: .greatestFiniteMagnitude)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(cell.cellSize(forBounds: bounds).height))
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged {
            invalidateIntrinsicContentSize()
        }
    }
}
