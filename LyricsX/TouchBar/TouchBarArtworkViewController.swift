import AppKit
import Combine
import MusicPlayer

class TouchBarArtworkViewController: NSViewController {
    let artworkView = NSImageView()

    private var cancelBag = Set<AnyCancellable>()

    override func loadView() {
        view = artworkView
    }

    override func viewDidLoad() {
        selectedPlayer.currentTrackWillChange
            .signal()
            .receive(on: DispatchQueue.main)
            .invoke(TouchBarArtworkViewController.updateArtworkImage, weaklyOn: self)
            .store(in: &cancelBag)
        updateArtworkImage()
    }

    func updateArtworkImage() {
        if let image = selectedPlayer.currentTrack?.artwork ?? selectedPlayer.name?.icon {
            let size = CGSize(width: 30, height: 30)
            artworkView.image = NSImage(size: size, flipped: false) { rect in
                image.draw(in: rect)
                return true
            }
        } else {
            // TODO: Placeholder
            artworkView.image = nil
        }
    }
}
