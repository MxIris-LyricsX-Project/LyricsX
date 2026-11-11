import AppKit

/// `MenuBarMarqueeLabel`'s cell: an `NSTextFieldCell` set up the way
/// `MLMarqueeLabel`'s `-initWithFrame:` sets up its text field, so the label
/// draws exactly what MarqueeLabel drew.
///
/// Every setting lives here rather than in the label. `init(textCell:)` is one
/// of NSTextFieldCell's two designated initializers, so it runs however
/// `NSControl` creates the cell from `cellClass`.
@available(macOS 26, *)
final class MenuBarMarqueeLabelCell: NSTextFieldCell {
    override init(textCell string: String) {
        super.init(textCell: string)
        // What MLMarqueeLabel sets, property by property.
        isBordered = false
        isEditable = false
        isSelectable = false
        alignment = .left
        lineBreakMode = .byTruncatingTail
        font = .systemFont(ofSize: 14)
        backgroundColor = .clear
        textColor = .labelColor
        // What `NSTextField(frame:)` leaves its cell with underneath: no
        // bezel, and a background that is drawn — in the clear colour above.
        isBezeled = false
        drawsBackground = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
