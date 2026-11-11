import AppKit
import OSToolbox

/// The custom view of a menu item, with a label that lines up with the titles
/// of the menu's standard items.
///
/// AppKit draws nothing of an item that has a custom view, and has no API for
/// where it draws the other items' titles; the place moves between releases,
/// too — macOS 27 put titles 6 points further right in a menu with a state
/// column. So once the view is in an open menu, it finds the title of a
/// standard item beside it, which `MenuItemTitleAlignmentPolicy` picks, and
/// moves ``label`` so that both texts start at the same x. When there is
/// nothing to measure, the policy's table places the label instead.
///
/// Pin the label's leading edge to the view's with
/// ``labelLeadingConstraint``: the view owns that constraint's constant.
@Loggable(subsystem: "com.JH.LyricsX.diagnostics", category: "TitleAlignedMenuItemView")
public final class TitleAlignedMenuItemView: NSView {
    /// How the view last placed its label.
    public enum LabelPlacement: Equatable, Sendable {
        /// The view has not been laid out in a menu yet.
        case unplaced
        /// Lined up with the title of the standard item with this title,
        /// measured in the open menu.
        case measured(referenceTitle: String)
        /// Placed from `MenuItemTitleAlignmentPolicy`'s table, with nothing to
        /// measure.
        case fallback
    }

    /// The label whose text lines up with the menu's titles.
    @IBOutlet public var label: NSTextField?

    /// The constraint between the label's leading edge and the view's.
    @IBOutlet public var labelLeadingConstraint: NSLayoutConstraint?

    /// Whether the view measures the titles of the open menu. Turned off, it
    /// always places the label from the table, which is how the alignment
    /// probe checks the table against the running release.
    public var measuresMenuTitles = true {
        didSet { needsLayout = true }
    }

    public private(set) var labelPlacement: LabelPlacement = .unplaced

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The menu's window lays out after it takes the view, and that pass is
        // the first one that can see the other items.
        if window != nil {
            needsLayout = true
        }
    }

    public override func layout() {
        placeLabel()
        super.layout()
    }

    private func placeLabel() {
        guard let label, let labelLeadingConstraint,
              let menuItem = enclosingMenuItem, let menu = menuItem.menu else { return }
        let items = menu.items.map(Self.policyItem(for:))
        let placement: LabelPlacement
        let leadingInset: CGFloat
        if measuresMenuTitles, let measurement = measuredLeadingInset(of: label, for: menuItem, in: menu, items: items) {
            placement = .measured(referenceTitle: measurement.referenceTitle)
            leadingInset = measurement.leadingInset
        } else {
            placement = .fallback
            leadingInset = MenuItemTitleAlignmentPolicy.fallbackLabelLeadingInset(
                showsStateColumn: MenuItemTitleAlignmentPolicy.showsStateColumn(
                    items: items,
                    menuShowsStateColumn: menu.showsStateColumn
                ),
                operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersion
            )
            // Outside a window there is nothing to measure yet; inside one this
            // is the sign that AppKit changed how it builds its menus.
            if measuresMenuTitles, window != nil, labelPlacement != .fallback {
                #log(.info, "Found no menu title to line up with; placing the label at \(Double(leadingInset), privacy: .public) points from the fallback table")
            }
        }
        labelPlacement = placement
        if abs(labelLeadingConstraint.constant - leadingInset) > 0.01 {
            labelLeadingConstraint.constant = leadingInset
        }
    }

    /// The constant that starts the label's text where the reference item's
    /// title starts, or `nil` when the open menu has nothing to measure.
    private func measuredLeadingInset(
        of label: NSTextField,
        for menuItem: NSMenuItem,
        in menu: NSMenu,
        items: [MenuItemTitleAlignmentPolicy.Item]
    ) -> (leadingInset: CGFloat, referenceTitle: String)? {
        // Right to left the label's leading edge is its right one; no
        // localization needs that yet, so the table handles it.
        guard let window, let contentView = window.contentView,
              userInterfaceLayoutDirection == .leftToRight,
              let customItemIndex = menu.items.firstIndex(where: { $0 === menuItem }),
              let referenceIndex = MenuItemTitleAlignmentPolicy.referenceItemIndex(forCustomItemAt: customItemIndex, in: items) else {
            return nil
        }
        let referenceTitle = menu.items[referenceIndex].title
        guard let titleField = titleField(showing: referenceTitle, in: contentView) else { return nil }
        // That item's view may come later in this layout pass.
        titleField.superview?.layoutSubtreeIfNeeded()
        let titleTextMinX = convert(Self.textRect(of: titleField), from: titleField).minX
        let labelTextOffset = Self.textRect(of: label).minX - label.bounds.minX
        // The constraint places the label's alignment rect, which a text field
        // insets from its frame; AppKit places the titles by their frames.
        let labelAlignmentInset = label.alignmentRect(forFrame: label.frame).minX - label.frame.minX
        let backingScale = window.backingScaleFactor
        let leadingInset = ((titleTextMinX - labelTextOffset + labelAlignmentInset) * backingScale).rounded() / backingScale
        return (leadingInset, referenceTitle)
    }

    /// The text field showing `title` in the menu's window, outside this view.
    private func titleField(showing title: String, in view: NSView) -> NSTextField? {
        for subview in view.subviews where subview !== self {
            if let textField = subview as? NSTextField, textField.stringValue == title {
                return textField
            }
            if let textField = titleField(showing: title, in: subview) {
                return textField
            }
        }
        return nil
    }

    /// Where a text field draws its text, in its own coordinates.
    private static func textRect(of textField: NSTextField) -> NSRect {
        textField.cell?.titleRect(forBounds: textField.bounds) ?? textField.bounds
    }

    private static func policyItem(for menuItem: NSMenuItem) -> MenuItemTitleAlignmentPolicy.Item {
        let isSectionHeader: Bool
        if #available(macOS 14, *) {
            isSectionHeader = menuItem.isSectionHeader
        } else {
            isSectionHeader = false
        }
        return MenuItemTitleAlignmentPolicy.Item(
            title: menuItem.title,
            isSeparator: menuItem.isSeparatorItem,
            isSectionHeader: isSectionHeader,
            isHidden: menuItem.isHidden,
            isAlternate: menuItem.isAlternate,
            hasCustomView: menuItem.view != nil,
            hasImage: menuItem.image != nil,
            indentationLevel: menuItem.indentationLevel,
            // On and mixed always have a mark; off only when the item has an
            // image for it.
            hasStateMark: menuItem.state != .off || menuItem.offStateImage != nil
        )
    }
}
