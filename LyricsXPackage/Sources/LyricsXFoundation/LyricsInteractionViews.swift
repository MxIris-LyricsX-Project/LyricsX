import AppKit

open class LyricsInteractionTextView: NSTextView {
    public var doubleClickHandler: ((NSEvent) -> Void)?
    public var contextMenuProvider: ((NSEvent) -> NSMenu?)?

    override open func mouseUp(with event: NSEvent) {
        guard event.clickCount == 2, let doubleClickHandler else {
            super.mouseUp(with: event)
            return
        }
        doubleClickHandler(event)
    }

    override open func menu(for event: NSEvent) -> NSMenu? {
        return contextMenuProvider?(event) ?? super.menu(for: event)
    }
}

open class LyricsContextMenuTextField: NSTextField {
    public var contextMenuProvider: ((NSEvent) -> NSMenu?)?

    override open func menu(for event: NSEvent) -> NSMenu? {
        return contextMenuProvider?(event) ?? super.menu(for: event)
    }
}
