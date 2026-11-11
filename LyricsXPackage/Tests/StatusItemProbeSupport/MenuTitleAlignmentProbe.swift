import AppKit
import LyricsXFoundation

/// What `MenuTitleAlignmentProbe` saw in one open menu.
package struct MenuTitleAlignmentReport: Codable, Sendable {
    package var menuCase: MenuTitleAlignmentCase
    /// `TitleAlignedMenuItemView.labelPlacement`: `measured`, `fallback` or
    /// `unplaced`.
    package var labelPlacement: String
    /// The title the view measured, when it measured one.
    package var referenceTitle: String?
    /// The constant the view gave its label's leading constraint.
    package var labelLeadingInset: Double
    /// Where the custom row's text starts, in points from the left edge of the
    /// menu's content: the label's frame there, plus where its own rendering
    /// first shows a glyph.
    package var labelTextStart: Double?
    /// Where the titles of the menu's plain items start, found the same way.
    package var titleTextStarts: [String: Double]
    /// What kept the probe from measuring, if anything did.
    package var problem: String?

    package init(menuCase: MenuTitleAlignmentCase, problem: String?) {
        self.menuCase = menuCase
        self.labelPlacement = "unplaced"
        self.labelLeadingInset = 0
        self.titleTextStarts = [:]
        self.problem = problem
    }
}

/// Opens a real menu with a `TitleAlignedMenuItemView` row, and finds where
/// the row's text and the plain titles' texts start: each text field's frame
/// after AppKit laid the menu out, plus the first column its own rendering
/// puts a glyph in. None of that is the arithmetic the view places its label
/// with, which is what the probe checks. Each field renders by itself because
/// in the whole menu a row the pointer rests on is highlighted, and the
/// highlight's edge reads like text.
///
/// Every text starts with the same letter, so the comparison does not depend
/// on the shapes of different glyphs.
@MainActor
package enum MenuTitleAlignmentProbe {
    static let labelText = "Hello offset:"
    static let plainTitles = ["Hello plain", "Hello after", "Hello submenu"]

    /// Opens the menu, measures it half a second later, closes it and returns
    /// what it saw. Blocks while the menu is open.
    package static func run(_ menuCase: MenuTitleAlignmentCase) -> MenuTitleAlignmentReport {
        let session = MenuTitleAlignmentSession(menuCase: menuCase)
        return session.run()
    }
}

@MainActor
private final class MenuTitleAlignmentSession {
    private let menuCase: MenuTitleAlignmentCase
    private let menu = NSMenu()
    private let alignedView = TitleAlignedMenuItemView(frame: NSRect(x: 0, y: 0, width: 248, height: 26))
    private var report: MenuTitleAlignmentReport

    init(menuCase: MenuTitleAlignmentCase) {
        self.menuCase = menuCase
        self.report = MenuTitleAlignmentReport(menuCase: menuCase, problem: "the menu never opened")
        buildMenu()
    }

    func run() -> MenuTitleAlignmentReport {
        let measuringTimer = Timer(timeInterval: 0.5, repeats: false) { [self] _ in
            MainActor.assumeIsolated {
                self.measure()
                self.menu.cancelTracking()
            }
        }
        // `.common` includes the event-tracking mode the open menu runs in.
        RunLoop.main.add(measuringTimer, forMode: .common)
        menu.popUp(positioning: nil, at: Self.locationAwayFromThePointer(), in: nil)
        measuringTimer.invalidate()
        return report
    }

    /// The menu of LyricsX's status item in miniature: a checkable item, the
    /// custom row in a section of plain items, a submenu, and an item with an
    /// image in a section of its own.
    private func buildMenu() {
        menu.autoenablesItems = false

        let checkableItem = NSMenuItem(title: "Hello checked", action: nil, keyEquivalent: "")
        checkableItem.state = menuCase.showsStateColumn ? .on : .off
        menu.addItem(checkableItem)
        menu.addItem(NSMenuItem(title: MenuTitleAlignmentProbe.plainTitles[0], action: nil, keyEquivalent: ""))
        menu.addItem(.separator())

        let label = NSTextField(labelWithString: MenuTitleAlignmentProbe.labelText)
        label.translatesAutoresizingMaskIntoConstraints = false
        alignedView.autoresizingMask = [.width]
        alignedView.addSubview(label)
        // 21 is the storyboard's constant, which the view has to move.
        let labelLeadingConstraint = label.leadingAnchor.constraint(equalTo: alignedView.leadingAnchor, constant: 21)
        NSLayoutConstraint.activate([
            labelLeadingConstraint,
            label.centerYAnchor.constraint(equalTo: alignedView.centerYAnchor),
        ])
        alignedView.label = label
        alignedView.labelLeadingConstraint = labelLeadingConstraint
        alignedView.measuresMenuTitles = menuCase.measuresMenuTitles
        let customItem = NSMenuItem()
        customItem.view = alignedView
        menu.addItem(customItem)

        menu.addItem(NSMenuItem(title: MenuTitleAlignmentProbe.plainTitles[1], action: nil, keyEquivalent: ""))
        let submenuItem = NSMenuItem(title: MenuTitleAlignmentProbe.plainTitles[2], action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(NSMenuItem(title: "Hello inside", action: nil, keyEquivalent: ""))
        submenuItem.submenu = submenu
        menu.addItem(submenuItem)
        menu.addItem(.separator())

        let imageItem = NSMenuItem(title: "Hello image", action: nil, keyEquivalent: "")
        imageItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(imageItem)
    }

    private func measure() {
        guard let window = alignedView.window, let contentView = window.contentView else {
            report.problem = "the custom row is not in a window"
            return
        }
        switch alignedView.labelPlacement {
        case .unplaced:
            report.labelPlacement = "unplaced"
        case .measured(let referenceTitle):
            report.labelPlacement = "measured"
            report.referenceTitle = referenceTitle
        case .fallback:
            report.labelPlacement = "fallback"
        }
        report.labelLeadingInset = Double(alignedView.labelLeadingConstraint?.constant ?? 0)

        guard let label = alignedView.label else {
            report.problem = "the custom row lost its label"
            return
        }
        report.labelTextStart = Self.textStart(of: label, in: contentView).map(Double.init)
        for title in MenuTitleAlignmentProbe.plainTitles {
            guard let titleField = Self.textField(showing: title, in: contentView) else {
                report.problem = "no text field shows \"\(title)\" in the menu's window"
                return
            }
            report.titleTextStarts[title] = Self.textStart(of: titleField, in: contentView).map(Double.init)
        }
        report.problem = nil
    }

    /// Where a text field's first glyph starts, in points from the left edge
    /// of `contentView`: its frame there, plus the first column of its own
    /// rendering that is not transparent.
    private static func textStart(of textField: NSTextField, in contentView: NSView) -> CGFloat? {
        guard let bitmap = textField.bitmapImageRepForCachingDisplay(in: textField.bounds) else { return nil }
        textField.cacheDisplay(in: textField.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / textField.bounds.width
        for column in 0 ..< bitmap.pixelsWide {
            for row in 0 ..< bitmap.pixelsHigh where (bitmap.colorAt(x: column, y: row)?.alphaComponent ?? 0) > 0.25 {
                let glyphStart = NSPoint(x: textField.bounds.minX + CGFloat(column) / scale, y: textField.bounds.midY)
                return contentView.convert(glyphStart, from: textField).x
            }
        }
        return nil
    }

    private static func textField(showing title: String, in view: NSView) -> NSTextField? {
        for subview in view.subviews {
            if let textField = subview as? NSTextField, textField.stringValue == title {
                return textField
            }
            if let textField = textField(showing: title, in: subview) {
                return textField
            }
        }
        return nil
    }

    /// A screen point whose menu would not open under the pointer, where a
    /// click the user happens to make would pick an item and close the menu
    /// before the probe has measured it.
    private static func locationAwayFromThePointer() -> NSPoint {
        let pointerLocation = NSEvent.mouseLocation
        let screenFrame = (NSScreen.screens.first { $0.frame.contains(pointerLocation) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = pointerLocation.x < screenFrame.midX ? screenFrame.maxX - 420 : screenFrame.minX + 120
        let y = pointerLocation.y < screenFrame.midY ? screenFrame.maxY - 80 : screenFrame.minY + 420
        return NSPoint(x: x, y: y)
    }
}
