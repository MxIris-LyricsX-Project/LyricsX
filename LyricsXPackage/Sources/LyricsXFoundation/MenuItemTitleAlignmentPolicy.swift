import CoreGraphics
import Foundation

/// Where the text of a menu item's custom view has to start for it to line up
/// with the titles of the menu's standard items.
///
/// AppKit has no API for where a menu draws its titles, and the place moves
/// between releases: macOS 27 put every title 6 points further right in a menu
/// with a state column. `TitleAlignedMenuItemView` therefore measures a
/// standard item's title in the open menu. This policy picks which item it
/// measures, and holds the table the view falls back to when there is nothing
/// to measure. The AppKit layout behind the table is in
/// `Documentations/Internal/StatusMenuTitleAlignment.md`.
public enum MenuItemTitleAlignmentPolicy {
    /// What the policy reads from one item of a menu.
    public struct Item: Equatable, Sendable {
        public var title: String
        public var isSeparator: Bool
        /// A section header opens the section of the items after it.
        public var isSectionHeader: Bool
        public var isHidden: Bool
        /// An alternate stands in for the item before it only while a modifier
        /// key is down, so it is not on screen when the menu opens.
        public var isAlternate: Bool
        public var hasCustomView: Bool
        /// An image moves the item's own title right, so that title says
        /// nothing about where the other titles start.
        public var hasImage: Bool
        public var indentationLevel: Int
        /// Whether the item has a mark to show in the state column: a
        /// checkmark, a dash, or an image set for its current state.
        public var hasStateMark: Bool

        public init(
            title: String,
            isSeparator: Bool = false,
            isSectionHeader: Bool = false,
            isHidden: Bool = false,
            isAlternate: Bool = false,
            hasCustomView: Bool = false,
            hasImage: Bool = false,
            indentationLevel: Int = 0,
            hasStateMark: Bool = false
        ) {
            self.title = title
            self.isSeparator = isSeparator
            self.isSectionHeader = isSectionHeader
            self.isHidden = isHidden
            self.isAlternate = isAlternate
            self.hasCustomView = hasCustomView
            self.hasImage = hasImage
            self.indentationLevel = indentationLevel
            self.hasStateMark = hasStateMark
        }

        public static let separator = Item(title: "", isSeparator: true)
    }

    /// The index of the standard item whose title the custom view at
    /// `customItemIndex` lines its label up with, or `nil` when the menu has no
    /// such item.
    ///
    /// The nearest one in the view's own section comes first. AppKit moves the
    /// titles of a section's other items right when some of its items have
    /// images, and the view's label belongs with its section. Failing that,
    /// the nearest item in a section without images, where a title sits as
    /// far left as titles go.
    public static func referenceItemIndex(forCustomItemAt customItemIndex: Int, in items: [Item]) -> Int? {
        guard items.indices.contains(customItemIndex) else { return nil }
        let indentationLevel = items[customItemIndex].indentationLevel
        let candidateIndices = items.indices.filter { itemIndex in
            itemIndex != customItemIndex && isReferenceCandidate(items[itemIndex], indentationLevel: indentationLevel)
        }
        let ownSection = sectionRange(containing: customItemIndex, in: items)
        if let nearestInOwnSection = nearest(to: customItemIndex, among: candidateIndices.filter(ownSection.contains)) {
            return nearestInOwnSection
        }
        let candidatesInSectionsWithoutImages = candidateIndices.filter { candidateIndex in
            !items[sectionRange(containing: candidateIndex, in: items)].contains { $0.hasImage && !$0.isHidden }
        }
        return nearest(to: customItemIndex, among: candidatesInSectionsWithoutImages)
    }

    /// Whether the menu reserves a column for state marks, which moves every
    /// title right. AppKit counts alternates too, even while they are hidden.
    ///
    /// - Parameter menuShowsStateColumn: `NSMenu.showsStateColumn`; with it
    ///   off, no mark gets a column.
    public static func showsStateColumn(items: [Item], menuShowsStateColumn: Bool = true) -> Bool {
        guard menuShowsStateColumn else { return false }
        return items.contains { item in
            !item.isSeparator && (!item.isHidden || item.isAlternate) && item.hasStateMark
        }
    }

    /// The constant of the leading constraint that lines a text field label up
    /// with the titles of a regular-size menu, as the given release lays them
    /// out.
    ///
    /// The constraint places the label's alignment rect, 2 points inside its
    /// frame, while AppKit places a title's text field by its frame; so each
    /// value is 2 points more than where that release puts the title's frame.
    /// On macOS 26 and 27 a title's frame starts at 14 points without a state
    /// column; a state column adds the width of its marks and a gap before
    /// the title, which macOS 27 widened from 8 to 14 points. Through macOS 15
    /// the table keeps the values the app used before it measured.
    public static func fallbackLabelLeadingInset(
        showsStateColumn: Bool,
        operatingSystemVersion: OperatingSystemVersion
    ) -> CGFloat {
        let majorVersion = operatingSystemVersion.majorVersion
        guard showsStateColumn else { return majorVersion >= 26 ? 16 : 14 }
        return majorVersion >= 27 ? 30 : 24
    }

    private static func isReferenceCandidate(_ item: Item, indentationLevel: Int) -> Bool {
        !item.isSeparator
            && !item.isSectionHeader
            && !item.isHidden
            && !item.isAlternate
            && !item.hasCustomView
            && !item.hasImage
            && item.indentationLevel == indentationLevel
            && !item.title.isEmpty
    }

    /// The items around `itemIndex` up to the nearest separators. A section
    /// header opens a section of its own.
    private static func sectionRange(containing itemIndex: Int, in items: [Item]) -> Range<Int> {
        var lowerBound = itemIndex
        while lowerBound > items.startIndex,
              !items[lowerBound].isSectionHeader,
              !items[lowerBound - 1].isSeparator {
            lowerBound -= 1
        }
        var upperBound = itemIndex + 1
        while upperBound < items.endIndex,
              !items[upperBound].isSeparator,
              !items[upperBound].isSectionHeader {
            upperBound += 1
        }
        return lowerBound ..< upperBound
    }

    /// The candidate closest to `itemIndex`; of two as close, the one before it.
    private static func nearest(to itemIndex: Int, among candidateIndices: [Int]) -> Int? {
        candidateIndices.min { abs($0 - itemIndex) < abs($1 - itemIndex) }
    }
}
