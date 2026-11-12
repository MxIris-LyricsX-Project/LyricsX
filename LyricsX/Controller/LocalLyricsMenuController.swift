import AppKit
import LyricsXFoundation
import MusicPlayer

/// The status menu's Local Lyrics submenu: the lyrics embedded in the track,
/// the `.lrcx` and `.lrc` beside it and LyricsX's own copy, whichever exist.
///
/// The sources are read off the main thread each time the status menu opens,
/// and the submenu is built from the last read in `menuNeedsUpdate`. Which
/// one is checked is worked out from the lyrics on screen, so nothing here
/// has to follow what the lookup, a search or a translation puts there.
final class LocalLyricsMenuController: NSObject, NSMenuDelegate {
    private let submenu = NSMenu(title: NSLocalizedString("Local Lyrics", comment: "Local lyrics submenu title"))
    private let readQueue = DispatchQueue(label: "LocalLyricsMenu", qos: .userInitiated)

    /// The last read, and the track it was made for.
    private var choices: [AppController.LocalLyricsChoice] = []
    private var choicesTrack: MusicTrack?
    /// Counts reads, so one that a later read overtook is dropped.
    private var readGeneration = 0
    private var isReading = false

    init(statusBarMenu: NSMenu) {
        super.init()
        submenu.delegate = self
        guard let searchItem = statusBarMenu.item(withTag: 201) else {
            return
        }
        let submenuItem = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        submenuItem.submenu = submenu
        let index = statusBarMenu.index(of: searchItem) + 1
        statusBarMenu.insertItem(.separator(), at: index)
        statusBarMenu.insertItem(submenuItem, at: index + 1)
        statusBarMenu.insertItem(.separator(), at: index + 2)
    }

    /// Reads the current track's sources again. Called as the status menu
    /// opens, so a file added or removed since the last look shows up.
    func refresh() {
        guard let track = selectedPlayer.currentTrack else {
            choices = []
            choicesTrack = nil
            isReading = false
            return
        }
        if choicesTrack?.id != track.id {
            choices = []
            choicesTrack = track
        }
        readGeneration += 1
        let generation = readGeneration
        isReading = true
        readQueue.async { [weak self] in
            let choices = AppController.shared.localLyricsChoices(for: track)
            DispatchQueue.main.async {
                guard let self, generation == self.readGeneration else { return }
                self.isReading = false
                guard selectedPlayer.currentTrack?.id == track.id else { return }
                self.choices = choices
                self.choicesTrack = track
                // The submenu may already be open on the loading row.
                self.menuNeedsUpdate(self.submenu)
            }
        }
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let currentTrack = selectedPlayer.currentTrack
        let choices = choicesTrack?.id == currentTrack?.id ? choices : []
        guard !choices.isEmpty else {
            let title = isReading
                ? NSLocalizedString("Loading Local Lyrics…", comment: "Local lyrics menu loading status")
                : NSLocalizedString("No Local Lyrics Available", comment: "Local lyrics menu empty status")
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }
        let onScreenLyrics = performOnLyricsDisplayQueue { AppController.shared.currentLyrics }
        let checkedSource = onScreenLyrics.flatMap {
            LocalLyricsSource.onScreen(
                localURL: $0.metadata.localURL,
                service: $0.metadata.service,
                isUserPicked: $0.isUserPicked,
                among: choices.map(\.source)
            )
        }
        for (index, choice) in choices.enumerated() {
            let item = NSMenuItem(title: title(of: choice), action: #selector(selectLocalLyrics(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = choice.source == checkedSource ? .on : .off
            if case .file(let fileURL) = choice.source {
                item.toolTip = fileURL.path
            }
            menu.addItem(item)
        }
    }

    private func title(of choice: AppController.LocalLyricsChoice) -> String {
        switch choice.source {
        case .embedded:
            return NSLocalizedString("Embedded Lyrics", comment: "Local lyrics menu option")
        case .file(let fileURL):
            return choice.isLibraryFile ? "LyricsX" : fileURL.lastPathComponent
        }
    }

    @objc private func selectLocalLyrics(_ sender: NSMenuItem) {
        guard let track = choicesTrack, choices.indices.contains(sender.tag) else {
            return
        }
        AppController.shared.applyLocalLyrics(choices[sender.tag], for: track)
    }
}
