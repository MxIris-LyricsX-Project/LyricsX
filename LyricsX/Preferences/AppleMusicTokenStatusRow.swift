import AppKit
import LyricsXFoundation

/// The row under the Apple Music token field in the Lab pane: where the
/// token check stands, and a button that checks again.
///
/// Users who pasted a `media-user-token` had no way to tell whether Apple
/// Music accepted it (issue #223). The text keeps "Apple Music lyrics" in
/// every state, because the token turns on Apple Music lyrics and nothing
/// else — not the MusicKit name recovery above it.
extension StatusMessageRowView {
    static func makeAppleMusicTokenStatusRow() -> StatusMessageRowView {
        let row = StatusMessageRowView(buttonTitle: NSLocalizedString(
            "Check Again",
            comment: "Button under the Apple Music token field in the Lab pane that checks the token with Apple Music again."
        ))
        row.setAccessibilityLabel(NSLocalizedString(
            "Apple Music token status",
            comment: "Accessibility label of the row under the Apple Music token field in the Lab pane that says whether Apple Music accepted the token."
        ))
        row.show(.noToken)
        return row
    }

    func show(_ check: AppleMusicTokenCheck) {
        switch check {
        case .noToken:
            show(.none, message: NSLocalizedString(
                "Paste a token to turn on Apple Music lyrics.",
                comment: "Under the Apple Music token field in the Lab pane while it is empty."
            ), showsButton: false)
        case .checking:
            show(.progress, message: NSLocalizedString(
                "Checking token…",
                comment: "Under the Apple Music token field in the Lab pane while Apple Music is being asked whether it accepts the token."
            ), showsButton: false)
        case .finished(.authorized(let storefront)):
            let message = String(
                format: NSLocalizedString(
                    "Valid. Apple Music lyrics are on (region: %@).",
                    comment: "Under the Apple Music token field in the Lab pane when Apple Music accepted the token. The argument is the region of the Apple Music account, such as Japan."
                ),
                AppleMusicTokenCheck.regionName(forStorefront: storefront)
            )
            show(.symbol(name: "checkmark.circle.fill", tintColor: .systemGreen), message: message, showsButton: true)
        case .finished(.denied):
            show(.symbol(name: "xmark.circle.fill", tintColor: .systemRed), message: NSLocalizedString(
                "Apple Music rejected this token. Copy it again from music.apple.com while signed in.",
                comment: "Under the Apple Music token field in the Lab pane when Apple Music refused the token."
            ), showsButton: true)
        case .finished(.couldNotDetermine(let reason)):
            let message = NSLocalizedString(
                "Couldn't check the token. Apple Music lyrics stay off until a check succeeds.",
                comment: "Under the Apple Music token field in the Lab pane when Apple Music could not be asked, for example without a network connection."
            )
            show(
                .symbol(name: "exclamationmark.triangle.fill", tintColor: .systemOrange),
                message: message,
                toolTip: message + "\n\n" + reason,
                showsButton: true
            )
        }
    }
}
