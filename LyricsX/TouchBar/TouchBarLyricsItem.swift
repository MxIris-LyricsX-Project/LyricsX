import AppKit
import Combine
import LyricsXFoundation
import OpenCC

class TouchBarLyricsItem: NSCustomTouchBarItem {
    private var lyricsTextField = KaraokeLabel(labelWithString: "")

    @objc dynamic var progressColor = #colorLiteral(red: 0, green: 1, blue: 0.8333333333, alpha: 1)

    private var cancelBag = Set<AnyCancellable>()

    override init(identifier: NSTouchBarItem.Identifier) {
        super.init(identifier: identifier)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    func commonInit() {
        view = lyricsTextField
        customizationLabel = "Lyrics"
        AppController.shared.$currentLyrics
            .combineLatest(AppController.shared.$currentLineIndex)
            .receive(on: DispatchQueue.lyricsDisplay)
            .invoke(TouchBarLyricsItem.handleLyricsDisplay, weaklyOn: self)
            .store(in: &cancelBag)
    }

    private func handleLyricsDisplay(event: (lyrics: Lyrics?, index: Int?)) {
        guard let lyrics = event.lyrics,
              let index = event.index else {
            DispatchQueue.main.async {
                self.lyricsTextField.stringValue = ""
                self.lyricsTextField.removeProgressAnimation()
            }
            return
        }
        let line = lyrics.lines[index]
        var lyricsContent = line.content
        if let converter = ChineseConverter.shared,
           lyrics.metadata.language?.hasPrefix("zh") == true {
            lyricsContent = converter.convert(lyricsContent)
        }
        let playbackState = selectedPlayer.playbackState
        let trackDuration = selectedPlayer.currentTrack?.duration
        let timeDelay = lyrics.adjustedTimeDelay
        let position = playbackState.lyricsDisplayTime(trackDuration: trackDuration)
        DispatchQueue.main.async {
            self.lyricsTextField.stringValue = lyricsContent
            if let timetag = line.attachments.timetag {
                var progress = timetag.tags.map { ($0.time + line.position - timeDelay - position, $0.index) }
                if let duration = timetag.duration, duration > 0 {
                    progress.append((duration + line.position - timeDelay - position, line.content.count))
                }
                self.lyricsTextField.setProgressAnimation(color: self.progressColor, progress: progress)
                if !playbackState.isPlaying {
                    self.lyricsTextField.pauseProgressAnimation()
                }
            }
        }
    }
}
