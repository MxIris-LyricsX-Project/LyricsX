import Foundation
import Testing
@testable import LyricsXFoundation

// The status menu's lyrics offset row is a custom view, so AppKit leaves its
// label to the app. The label used to sit at a fixed 24 points whenever the
// menu had a state column — right for macOS 26, 6 points short of where
// macOS 27 starts titles — and at 14 points otherwise. The view now measures a
// standard item's title in the open menu; these tests pin down which item,
// and the table it falls back to when there is none.

private typealias Item = MenuItemTitleAlignmentPolicy.Item

private func customRow() -> Item {
    Item(title: "Lyrics Offset", hasCustomView: true)
}

@Test
func aCustomRowLinesUpWithAStandardItemOfItsOwnSection() {
    let items = [
        Item(title: "Enable Menu Bar Lyrics", hasStateMark: true),
        Item(title: "Show Lyrics Window"),
        .separator,
        customRow(),
        Item(title: "Search Lyrics…"),
        Item(title: "Lyrics"),
    ]

    #expect(MenuItemTitleAlignmentPolicy.referenceItemIndex(forCustomItemAt: 3, in: items) == 4)
}

@Test
func itemsWhoseTitlesStartElsewhereAreNeverTheReference() {
    // Every item but the last is nearer to the custom row, and none of them
    // shows a title where the row's label belongs.
    let items = [
        customRow(),
        Item(title: "Hidden", isHidden: true),
        Item(title: "Alternate", isAlternate: true),
        Item(title: "Another Custom Row", hasCustomView: true),
        Item(title: "Preferences…", hasImage: true),
        Item(title: "Indented", indentationLevel: 1),
        Item(title: ""),
        Item(title: "Plain"),
    ]

    #expect(MenuItemTitleAlignmentPolicy.referenceItemIndex(forCustomItemAt: 0, in: items) == 7)
}

@Test
func aSectionHeaderClosesTheCustomRowsSection() {
    // The item after the header is nearer, but it belongs to another section.
    let items = [
        Item(title: "Before"),
        Item(title: "Hidden", isHidden: true),
        Item(title: "Also Hidden", isHidden: true),
        customRow(),
        Item(title: "Header", isSectionHeader: true),
        Item(title: "After the Header"),
    ]

    #expect(MenuItemTitleAlignmentPolicy.referenceItemIndex(forCustomItemAt: 3, in: items) == 0)
}

@Test
func aRowAloneInItsSectionLinesUpWithTheNearestSectionWithoutImages() {
    // The second section's plain item is nearer, but the image beside it moves
    // its title right.
    let items = [
        Item(title: "Plain"),
        .separator,
        Item(title: "Preferences…", hasImage: true),
        Item(title: "Moved Right by the Image Beside It"),
        .separator,
        customRow(),
        .separator,
    ]

    #expect(MenuItemTitleAlignmentPolicy.referenceItemIndex(forCustomItemAt: 5, in: items) == 0)
}

@Test
func aMenuWithNothingToMeasureHasNoReference() {
    let items = [
        customRow(),
        .separator,
        Item(title: "Preferences…", hasImage: true),
    ]

    #expect(MenuItemTitleAlignmentPolicy.referenceItemIndex(forCustomItemAt: 0, in: items) == nil)
}

@Test
func anItemWithAStateMarkGivesTheMenuAStateColumn() {
    let items = [
        Item(title: "Enable Menu Bar Lyrics", hasStateMark: true),
        customRow(),
    ]

    #expect(MenuItemTitleAlignmentPolicy.showsStateColumn(items: items))
}

@Test
func aMenuWithoutStateMarksHasNoStateColumn() {
    let items = [
        Item(title: "Enable Menu Bar Lyrics"),
        customRow(),
    ]

    #expect(!MenuItemTitleAlignmentPolicy.showsStateColumn(items: items))
}

@Test
func aHiddenItemsMarkTakesNoColumn() {
    let items = [
        Item(title: "Hidden", isHidden: true, hasStateMark: true),
        customRow(),
    ]

    #expect(!MenuItemTitleAlignmentPolicy.showsStateColumn(items: items))
}

@Test
func aHiddenAlternatesMarkStillTakesTheColumn() {
    // AppKit sizes the column for an alternate before the user ever holds the
    // modifier that shows it.
    let items = [
        Item(title: "Alternate", isHidden: true, isAlternate: true, hasStateMark: true),
        customRow(),
    ]

    #expect(MenuItemTitleAlignmentPolicy.showsStateColumn(items: items))
}

@Test
func aMenuWithItsStateColumnTurnedOffHasNone() {
    let items = [
        Item(title: "Enable Menu Bar Lyrics", hasStateMark: true),
        customRow(),
    ]

    #expect(!MenuItemTitleAlignmentPolicy.showsStateColumn(items: items, menuShowsStateColumn: false))
}

struct FallbackInsetCase: Sendable, CustomTestStringConvertible {
    var showsStateColumn: Bool
    var majorVersion: Int
    var labelLeadingInset: CGFloat

    var testDescription: String {
        "\(showsStateColumn ? "state column" : "no state column") on macOS \(majorVersion)"
    }
}

/// Each inset is 2 points more than where the release puts a title's text field,
/// because the constraint places the label's alignment rect. The macOS 26 and 27
/// values come from AppKit's menu layout and are checked against a real menu by
/// StatusMenuTitleAlignmentProbes; through macOS 15 the table keeps the values
/// the app had before. The old fixed values were 2 points short without a state
/// column on macOS 26, and 6 points short with one on macOS 27.
@Test(arguments: [
    FallbackInsetCase(showsStateColumn: false, majorVersion: 15, labelLeadingInset: 14),
    FallbackInsetCase(showsStateColumn: false, majorVersion: 26, labelLeadingInset: 16),
    FallbackInsetCase(showsStateColumn: false, majorVersion: 27, labelLeadingInset: 16),
    FallbackInsetCase(showsStateColumn: true, majorVersion: 15, labelLeadingInset: 24),
    FallbackInsetCase(showsStateColumn: true, majorVersion: 26, labelLeadingInset: 24),
    FallbackInsetCase(showsStateColumn: true, majorVersion: 27, labelLeadingInset: 30),
    FallbackInsetCase(showsStateColumn: true, majorVersion: 28, labelLeadingInset: 30),
])
func theFallbackTablePlacesTheLabelWhereEachReleaseStartsTitles(_ fallbackCase: FallbackInsetCase) {
    let operatingSystemVersion = OperatingSystemVersion(majorVersion: fallbackCase.majorVersion, minorVersion: 0, patchVersion: 0)

    let inset = MenuItemTitleAlignmentPolicy.fallbackLabelLeadingInset(
        showsStateColumn: fallbackCase.showsStateColumn,
        operatingSystemVersion: operatingSystemVersion
    )

    #expect(inset == fallbackCase.labelLeadingInset)
}
