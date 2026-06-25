import AppKit

// Not actual polyfills. Despite the `obsoleted` mark, these implementation in
// fact shadows the system provided methods.

// MARK: - 10.12

extension NSTextField {
    @available(macOS, obsoleted: 10.12)
    convenience init(labelWithString stringValue: String) {
        self.init()
        self.stringValue = stringValue
        isEditable = false
        isSelectable = false
        textColor = .labelColor
        backgroundColor = .controlColor
        drawsBackground = false
        isBezeled = false
        alignment = .natural
        font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: controlSize))
        lineBreakMode = .byClipping
        cell?.isScrollable = true
        cell?.wraps = false
    }
}

extension NSAnimationContext {
    @available(macOS, obsoleted: 10.12)
    class func runAnimationGroup(_ changes: (NSAnimationContext) -> Void) {
        runAnimationGroup(changes, completionHandler: nil)
    }
}

// MARK: - 10.13

extension NSStoryboard {
    @available(macOS, obsoleted: 10.13)
    class var main: NSStoryboard? {
        guard let mainStoryboardName = Bundle.main.infoDictionary?["NSMainStoryboardFile"] as? String else {
            return nil
        }
        return NSStoryboard(name: NSStoryboard.Name(mainStoryboardName), bundle: .main)
    }
}

// MARK: - 13.0

extension Task where Success == Never, Failure == Never {
    /// Back-deployable seconds-based sleep that mirrors the macOS 13+
    /// `Task.sleep(for:)` ergonomics while delegating to the older
    /// `Task.sleep(nanoseconds:)` so it works on macOS 11/12.
    static func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64((seconds * 1_000_000_000).rounded()))
    }
}
