import AppKit
import Combine
import GenericID
import MusicPlayer

class LyricsHUDViewController: NSViewController, NSWindowDelegate, ScrollLyricsViewDelegate, DragNDropDelegate {
    @IBOutlet var dragNDropView: DragNDropView!
    @IBOutlet var lyricsScrollView: ScrollLyricsView!
    @IBOutlet var noLyricsLabel: LyricsPlaceholderTextField!

    @IBOutlet var lyricsScrollViewTopMargin: NSLayoutConstraint!
    @IBOutlet var lyricsScrollViewLeftMargin: NSLayoutConstraint!

    @objc dynamic var isTracking = true {
        didSet {
            if !oldValue, isTracking {
                displayLyrics()
            }
        }
    }

    private var isWillTerminate = false

    private var cancelBag = Set<AnyCancellable>()

    override func awakeFromNib() {
        super.awakeFromNib()

        view.window?.do {
            $0.title = "Lyrics Window"
            $0.titlebarAppearsTransparent = true
//            $0.titleVisibility = .hidden
            $0.styleMask.insert(.borderless)
            $0.delegate = self
        }
        // swiftlint:disable:next force_cast
        let accessory = NSStoryboard.main!.instantiateController(withIdentifier: .lyricsHUDAccessory) as! NSTitlebarAccessoryViewController
        accessory.layoutAttribute = .right
        view.window?.addTitlebarAccessoryViewController(accessory)

        dragNDropView.dragDelegate = self
        lyricsScrollView.delegate = self
        noLyricsLabel.contextMenuProvider = { [weak self] _ in
            self?.lyricsViewContextMenu()
        }
        lyricsScrollView.setupTextContents(lyrics: AppController.shared.currentLyrics)

        lyricsScrollView.bind(\.fontName, withDefaultName: .lyricsWindowFontName)
        lyricsScrollView.bind(\.fontSize, withUnmatchedDefaultName: .lyricsWindowFontSize)
        lyricsScrollView.bind(\.textColor, withDefaultName: .lyricsWindowTextColor)
        lyricsScrollView.bind(\.highlightColor, withDefaultName: .lyricsWindowHighlightColor)

        observeDefaults(key: .lyricsWindowFontSize, options: [.new, .initial]) { [unowned self] _, change in
            let fontSize = CGFloat(change.newValue)
            self.lyricsScrollViewTopMargin.constant = fontSize
            self.lyricsScrollViewLeftMargin.constant = fontSize
            self.displayLyrics(animation: false)
        }

        AppController.shared.$currentLyrics
            .signal()
            .receive(on: DispatchQueue.main)
            .invoke(LyricsHUDViewController.lyricsChanged, weaklyOn: self)
            .store(in: &cancelBag)
        AppController.shared.$currentLineIndex
            .receive(on: DispatchQueue.main)
            .sink { [unowned self] _ in
                self.displayLyrics()
            }.store(in: &cancelBag)

        observeNotification(
            name: NSScrollView.willStartLiveScrollNotification,
            object: lyricsScrollView,
            queue: .main
        ) { [unowned self] _ in self.isTracking = false }
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillTerminate(_:)), name: NSApplication.willTerminateNotification, object: nil)
    }

    override func viewWillAppear() {
        noLyricsLabel.isHidden = AppController.shared.currentLyrics != nil
        updateBackgroundContextMenu()
        displayLyrics(animation: false)
    }

    // MARK: - Handler

    private func lyricsChanged() {
        DispatchQueue.main.async {
            let newLyrics = AppController.shared.currentLyrics
            self.lyricsScrollView.setupTextContents(lyrics: newLyrics)
            self.noLyricsLabel.isHidden = newLyrics != nil
            self.updateBackgroundContextMenu()
            self.displayLyrics(animation: false)
        }
    }

    private func updateBackgroundContextMenu() {
        dragNDropView.menu = lyricsViewContextMenu()
    }

    private func displayLyrics(animation: Bool = true) {
        var pos = selectedPlayer.playbackTime
        pos += AppController.shared.currentLyrics?.adjustedTimeDelay ?? 0
        lyricsScrollView.highlight(position: pos)
        guard isTracking else {
            return
        }
        if animation {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.allowsImplicitAnimation = true
                context.timingFunction = .swiftOut
                self.lyricsScrollView.scroll(position: pos)
            }
        } else {
            lyricsScrollView.scroll(position: pos)
        }
    }

    // MARK: ScrollLyricsViewDelegate

    func doubleClickLyricsLine(at position: TimeInterval) {
        let pos = position - (AppController.shared.currentLyrics?.adjustedTimeDelay ?? 0)
        selectedPlayer.playbackTime = pos
        isTracking = true
    }

    func lyricsViewContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            return menu
        }

        let searchItem = menu.addItem(
            withTitle: NSLocalizedString("Search", comment: "Lyrics window context menu"),
            action: #selector(AppDelegate.searchLyrics(_:)),
            keyEquivalent: ""
        )
        searchItem.target = appDelegate
        searchItem.isEnabled = selectedPlayer.currentTrack != nil
        if #available(macOS 11.0, *) {
            searchItem.image = NSImage(
                systemSymbolName: "magnifyingglass",
                accessibilityDescription: searchItem.title
            )
        }

        let editItem = menu.addItem(
            withTitle: NSLocalizedString("Edit", comment: "Lyrics window context menu"),
            action: #selector(AppDelegate.editCurrentLyrics(_:)),
            keyEquivalent: ""
        )
        editItem.target = appDelegate
        editItem.isEnabled = appDelegate.canEditCurrentLyrics
        if #available(macOS 11.0, *) {
            editItem.image = NSImage(
                systemSymbolName: "pencil",
                accessibilityDescription: editItem.title
            )
        }
        if AppController.shared.currentLyrics != nil, !editItem.isEnabled {
            editItem.toolTip = NSLocalizedString(
                "Embedded lyrics cannot be edited.",
                comment: "Disabled Edit menu explanation"
            )
        }

        return menu
    }

    func scrollWheelDidStartScroll() {
        isTracking = false
    }

    func scrollWheelDidEndScroll() {}

    // MARK: NSWindowDelegate

    func windowDidResize(_ notification: Notification) {
        DispatchQueue.main.async {
            self.displayLyrics(animation: false)
        }
    }

    // MARK: DragNDropDelegate

    func dragFinished(content: String) {
        do {
            try AppController.shared.importLyrics(content)
        } catch {
            let alert = NSAlert(error: error)
            alert.beginSheetModal(for: view.window!)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard !isWillTerminate else { return }
        defaults[.isShowLyricsHUD] = false
    }

    @objc func applicationWillTerminate(_ notification: Notification) {
        isWillTerminate = true
    }
}

class LyricsHUDAccessoryViewController: NSTitlebarAccessoryViewController {
    @IBAction func lockAction(_ sender: NSButton) {
        if sender.state == .on {
            view.window?.level = .modalPanel
        } else {
            view.window?.level = .normal
        }
    }
}
