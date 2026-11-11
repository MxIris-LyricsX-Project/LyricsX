import Foundation

/// Synchronous player operations. The app runs these on its dedicated Music I/O queue.
public enum MusicLyricsOperation {
    public enum Result: Equatable {
        case skipped
        case unverified
        case verified(String)

        public var verifiedText: String? {
            if case .verified(let text) = self { return text }
            return nil
        }
    }

    public static func write(
        _ content: String,
        overwrite: Bool,
        read: () -> String?,
        beforeWrite: () -> Bool,
        write: (String) -> Void
    ) -> Result {
        if !overwrite, read()?.isEmpty == false { return .skipped }
        guard beforeWrite() else { return .skipped }
        write(content)
        guard let actual = read(), LyricsStoragePolicy.lyricsInMusicMatchesWrittenContent(actual, written: content) else {
            return .unverified
        }
        return .verified(actual)
    }
}
