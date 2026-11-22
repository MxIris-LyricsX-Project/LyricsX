import AppKit
import Testing
@testable import LyricsXFoundation

// The row under the Apple Music token field in the Lab pane. Its first
// version took the message's width from its own last layout pass and fed it
// back as the wrapping width, so the message's width and its line breaks kept
// changing each other: opening the Lab pane in Chinese raised AppKit's
// "more Update Constraints in Window passes than there are views in the
// window" exception. Headless — the row is laid out in a plain view.

private let rowWidth: CGFloat = 338
private let longMessage = "Apple Music rejected this token. Copy it again from music.apple.com while signed in."
private let longChineseMessage = "Apple Music 拒绝了这个 token。请登录 music.apple.com 后重新复制。"
private let shortMessage = "Checking token…"

@MainActor
private func makeRow(message: String, indicator: StatusMessageRowView.Indicator, showsButton: Bool) -> (container: NSView, row: StatusMessageRowView) {
    let row = StatusMessageRowView(buttonTitle: "Check Again")
    row.show(indicator, message: message, showsButton: showsButton)
    row.translatesAutoresizingMaskIntoConstraints = false
    let container = NSView(frame: NSRect(x: 0, y: 0, width: rowWidth, height: 200))
    container.addSubview(row)
    NSLayoutConstraint.activate([
        row.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        row.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        row.topAnchor.constraint(equalTo: container.topAnchor),
    ])
    return (container, row)
}

/// Lays `view` out until nothing in it asks for another pass, and returns how
/// many passes that took — or `limit` when it never settles.
@MainActor
private func layoutPassesUntilSettled(_ view: NSView, limit: Int = 20) -> Int {
    func needsAnotherPass(_ view: NSView) -> Bool {
        view.needsLayout || view.needsUpdateConstraints || view.subviews.contains(where: needsAnotherPass)
    }
    for pass in 1...limit {
        view.layoutSubtreeIfNeeded()
        if !needsAnotherPass(view) { return pass }
    }
    return limit
}

/// `nil` shows the spinner.
@MainActor
@Test(arguments: [
    (longMessage, "xmark.circle.fill" as String?, true),
    (longChineseMessage, "xmark.circle.fill" as String?, true),
    (shortMessage, nil as String?, false),
])
func theRowSettlesAfterOneLayout(message: String, symbolName: String?, showsButton: Bool) {
    let indicator: StatusMessageRowView.Indicator = symbolName.map { .symbol(name: $0, tintColor: .systemRed) } ?? .progress
    let (container, _) = makeRow(message: message, indicator: indicator, showsButton: showsButton)
    #expect(layoutPassesUntilSettled(container) <= 2, "the message's width and its wrapping keep changing each other")
}

@MainActor
@Test
func aMessageTooLongForOneLineTakesTwo() {
    let (shortContainer, shortRow) = makeRow(message: shortMessage, indicator: .none, showsButton: true)
    let (longContainer, longRow) = makeRow(message: longMessage, indicator: .none, showsButton: true)
    _ = layoutPassesUntilSettled(shortContainer)
    _ = layoutPassesUntilSettled(longContainer)
    #expect(longRow.frame.height > shortRow.frame.height)
    #expect(longRow.frame.width == rowWidth)
}

@MainActor
@Test
func aMessageOfManyLinesShowsTwo() {
    let (twoLineContainer, twoLineRow) = makeRow(message: longMessage, indicator: .none, showsButton: true)
    let (manyLineContainer, manyLineRow) = makeRow(
        message: Array(repeating: longMessage, count: 3).joined(separator: " "),
        indicator: .none,
        showsButton: true
    )
    _ = layoutPassesUntilSettled(twoLineContainer)
    _ = layoutPassesUntilSettled(manyLineContainer)
    #expect(manyLineRow.frame.height == twoLineRow.frame.height)
}
