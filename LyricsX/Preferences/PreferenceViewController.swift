import Cocoa

class PreferenceTabViewController: NSTabViewController {
    /// The toolbar symbol for each tab, in the storyboard's tab order.
    private static let toolbarSymbolNames = [
        "gearshape", // General
        "textformat", // Display
        "keyboard", // Shortcut
        "line.3.horizontal.decrease", // Filter
        "flask", // Lab
        "list.bullet", // Source
    ]

    override func viewDidLoad() {
        super.viewDidLoad()
        applyToolbarSymbols()
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        resizeWindowToFitSelectedTabViewItem()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        resizeWindowToFitSelectedTabViewItem()
    }

    /// Replaces the storyboard's toolbar images with SF Symbols. The old set
    /// mixed 10.x-era colour icons with hand-drawn PDFs, which reads as foreign
    /// next to a modern toolbar.
    ///
    /// `flask` only became a system symbol in SF Symbols 5 (macOS 14), so it
    /// also ships as an exported symbol set in the asset catalog to cover this
    /// project's macOS 12 floor. Trying the system catalog first keeps the tab
    /// in step with whatever Apple currently ships and lets the bundled copy
    /// take over only where there is none.
    ///
    /// The bundled copy is loaded by plain name rather than through
    /// `NSImage(symbolName:variableValue:)`. That initialiser searches the same
    /// main-bundle catalog and does not consult the system one, so its only
    /// addition here is the variable value — which a fixed symbol ignores — in
    /// exchange for a macOS 13 availability guard.
    private func applyToolbarSymbols() {
        for (tabViewItem, symbolName) in zip(tabViewItems, Self.toolbarSymbolNames) {
            let symbolImage = NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: tabViewItem.label
            ) ?? NSImage(named: symbolName)
            guard let symbolImage else { continue }
            // Left without a symbol configuration on purpose: the toolbar
            // applies its own, which is what keeps these sized like every other
            // toolbar in the system.
            tabViewItem.image = symbolImage.pinnedToLatinScript
        }
    }

    /// `NSTabViewController` leaves the window size to Auto Layout, and Auto
    /// Layout only moves it when the selected pane pins itself to a single
    /// size. A pane whose content can stretch — a table view inside a scroll
    /// view, a grid view, a nested tab view — is satisfied by whatever size the
    /// previously selected pane left behind, because the window's own "stay
    /// put" constraint outranks anything the pane merely allows. The visible
    /// symptom is a tab that opens at a different height depending on which tab
    /// you came from.
    ///
    /// Sizing the window from the selected pane's fitting size makes each tab's
    /// size depend only on that tab.
    private func resizeWindowToFitSelectedTabViewItem() {
        guard let window = view.window,
              children.indices.contains(selectedTabViewItemIndex)
        else { return }

        // Measure the pane itself rather than this controller's own view: the
        // Display pane nests another NSTabView, and asking the outer view for
        // its fitting size reports the size it currently has instead of the one
        // its content needs, which would just preserve the stale window size.
        let paneView = children[selectedTabViewItemIndex].view
        paneView.layoutSubtreeIfNeeded()

        let fittingContentSize = paneView.fittingSize
        guard fittingContentSize.width > 0, fittingContentSize.height > 0 else { return }

        var targetFrame = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: fittingContentSize)
        )
        guard targetFrame.size != window.frame.size else { return }

        // Grow and shrink downwards so the title bar stays where the user left it.
        targetFrame.origin.x = window.frame.origin.x
        targetFrame.origin.y = window.frame.maxY - targetFrame.height
        window.setFrame(targetFrame, display: true)
    }
}

class PreferenceViewController: NSViewController {}

private extension NSImage {
    /// The same symbol with its script variant pinned to Latin.
    ///
    /// Several SF Symbols ship per-script variants, and AppKit substitutes them
    /// from the app's localization: `textformat` draws as 格式 rather than "Aa"
    /// once the app runs in Chinese. That substitution is right where a symbol
    /// stands in for text the reader is about to edit, but the preferences
    /// toolbar already spells each tab out in a label underneath, so the
    /// localized glyph only duplicates it — a tab reading 格式 above 显示.
    ///
    /// The availability guard costs nothing here. `withLocale(_:)` arrived in
    /// macOS 14, and `textformat`'s script variants only arrived in macOS 15,
    /// so the pin is in place on every version that can perform a substitution;
    /// below that the system has no variant to substitute in the first place
    /// and draws the Latin form regardless.
    var pinnedToLatinScript: NSImage {
        guard #available(macOS 14, *) else { return self }
        return withLocale(Locale(identifier: "en"))
    }
}
