import AppKit
import LyricsXFoundation
import SwiftUI
import Translation

/// Asks the system to download the languages a pair needs, through the
/// system's own confirmation sheet on the window `hostingView` sits in.
///
/// The session system translation runs in the background cannot do this:
/// one made with `init(installedSource:target:)` reports
/// `canRequestDownloads == false` and fails with `notInstalled`. The only
/// public way to put up the download prompt is a SwiftUI view's
/// `translationTask`, whose session the framework attaches to that view's
/// window — so this keeps an invisible SwiftUI view in the pane and hands it
/// the pair to prepare.
@available(macOS 26.0, *)
@MainActor
final class SystemTranslationLanguageDownloader {
    /// Must be in the window the prompt should appear on, or the task never
    /// runs. It draws nothing.
    let hostingView: NSView

    private let model = SystemTranslationLanguageDownloadModel()

    init() {
        let hostingView = NSHostingView(rootView: SystemTranslationLanguageDownloadView(model: model))
        // Sized by its frame alone: the hosted view has nothing to show, and
        // the default sizing options would add constraints that fight the
        // autoresizing mask of a view the pane places by hand.
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        self.hostingView = hostingView
    }

    /// Prompts for `pair`'s languages and calls `completion` once they are
    /// installed (`nil`) or the prompt failed or was dismissed (the error).
    func requestDownload(of pair: SystemTranslationLanguagePair, completion: @escaping (Error?) -> Void) {
        model.completion = completion
        let source = Locale.Language(identifier: pair.sourceLanguage)
        let target = Locale.Language(identifier: pair.targetLanguage)
        if model.configuration?.source == source, model.configuration?.target == target {
            // The same pair again, after a prompt that was dismissed: the task
            // only reruns for a configuration that changed, and invalidating
            // is how a configuration changes without changing its languages.
            model.configuration?.invalidate()
        } else if #available(macOS 26.4, *) {
            // The strategy translation runs with, so the prompt offers the
            // models that strategy uses.
            model.configuration = TranslationSession.Configuration(
                source: source,
                target: target,
                preferredStrategy: .highFidelity
            )
        } else {
            model.configuration = TranslationSession.Configuration(source: source, target: target)
        }
    }
}

@available(macOS 26.0, *)
@MainActor
@Observable
private final class SystemTranslationLanguageDownloadModel {
    var configuration: TranslationSession.Configuration?

    @ObservationIgnored
    var completion: ((Error?) -> Void)?

    func finish(with error: Error?) {
        let completion = completion
        self.completion = nil
        completion?(error)
    }
}

@available(macOS 26.0, *)
private struct SystemTranslationLanguageDownloadView: View {
    let model: SystemTranslationLanguageDownloadModel

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(model.configuration) { session in
                do {
                    // Puts up the system's prompt when either language is
                    // missing, and returns at once when both are installed.
                    try await session.prepareTranslation()
                    model.finish(with: nil)
                } catch {
                    model.finish(with: error)
                }
            }
    }
}
