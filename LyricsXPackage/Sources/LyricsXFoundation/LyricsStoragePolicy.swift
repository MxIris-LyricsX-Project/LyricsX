import Foundation

public enum LyricsSavingLocation: Int, Sendable {
    case lyricsXDirectory = 0
    case customDirectory = 1

    /// The saving-path pop-up carries a separator and an "Other…" row on top of
    /// the two real choices, so the bound preference reaches 2 and 3 — picking
    /// "Other…" leaves it at 3, because the open-panel completion re-selects the
    /// user-path row programmatically and that does not write back through the
    /// binding. Reads treat every non-zero index as the custom directory, so
    /// writes must do the same or the two disagree and saved lyrics are never
    /// found again.
    public init(popUpIndex: Int) {
        self = popUpIndex == LyricsSavingLocation.lyricsXDirectory.rawValue
            ? .lyricsXDirectory
            : .customDirectory
    }
}

public struct LyricsStorageDestination: Equatable, Sendable {
    public let fileURL: URL
    public let securityScopedDirectoryURL: URL?

    public init(fileURL: URL, securityScopedDirectoryURL: URL?) {
        self.fileURL = fileURL
        self.securityScopedDirectoryURL = securityScopedDirectoryURL
    }
}

public enum LyricsStoragePolicy {
    public static let lyricsFileExtension = "lrcx"

    public static func contains(_ fileURL: URL, in directoryURL: URL) -> Bool {
        let directoryComponents = directoryURL.standardizedFileURL.pathComponents
        let fileComponents = fileURL.standardizedFileURL.pathComponents
        guard fileComponents.count > directoryComponents.count else {
            return false
        }
        return zip(directoryComponents, fileComponents).allSatisfy { directory, file in
            directory == file
        }
    }

    /// Files LyricsX itself manages live in the default or custom lyrics library.
    /// Lyrics loaded from beside a track are treated as user-owned unless the
    /// caller explicitly allows writing them back.
    public static func isManagedLibraryFile(
        _ fileURL: URL,
        defaultDirectoryURL: URL,
        customDirectoryURL: URL?
    ) -> Bool {
        if contains(fileURL, in: defaultDirectoryURL) {
            return true
        }
        if let customDirectoryURL, contains(fileURL, in: customDirectoryURL) {
            return true
        }
        return false
    }

    /// The file to delete when the user rejects the lyrics on screen with
    /// "Wrong Lyrics" or "Disable Lyrics for Entire Album": LyricsX's own copy
    /// in the library, and nothing else. A file beside the track is the
    /// user's — hand-made or bought — and a verdict on the lyrics must not
    /// destroy it.
    public static func fileToRemoveWhenRejected(
        localURL: URL?,
        defaultDirectoryURL: URL,
        customDirectoryURL: URL?
    ) -> URL? {
        guard let localURL,
              isManagedLibraryFile(
                  localURL,
                  defaultDirectoryURL: defaultDirectoryURL,
                  customDirectoryURL: customDirectoryURL
              ) else {
            return nil
        }
        return localURL
    }

    /// Whether rejecting the lyrics on screen with "Wrong Lyrics" or "Disable
    /// Lyrics for Entire Album" clears the track's lyrics in Music, where
    /// automatic writing may have put them.
    ///
    /// Only LyricsX's own text goes, as with `fileToRemoveWhenRejected`: Music
    /// has to hold, line for line, one of `contentsLyricsXWrote`. Anything else
    /// there — lyrics the user typed in or that came embedded in the file, or
    /// LyricsX's text the user has since corrected — is the user's, and a
    /// verdict on the lyrics on screen must not destroy it.
    ///
    /// Line breaks, the blank lines between lines and the whitespace around
    /// each are left out of the comparison, so a write Music stored with other
    /// line endings still counts as LyricsX's.
    public static func clearsLyricsInMusicWhenRejected(
        lyricsInMusic: String?,
        contentsLyricsXWrote: [String]
    ) -> Bool {
        guard let lyricsInMusic else {
            return false
        }
        let linesInMusic = comparableLines(of: lyricsInMusic)
        guard !linesInMusic.isEmpty else {
            return false
        }
        return contentsLyricsXWrote.contains { comparableLines(of: $0) == linesInMusic }
    }

    private static func comparableLines(of text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public static func persistDestination(
        localURL: URL?,
        allowUnmanagedLocalWriteBack: Bool,
        defaultDirectoryURL: URL,
        customDirectoryURL: URL?,
        libraryDestination: LyricsStorageDestination?
    ) -> LyricsStorageDestination? {
        if let localURL {
            let isManaged = isManagedLibraryFile(
                localURL,
                defaultDirectoryURL: defaultDirectoryURL,
                customDirectoryURL: customDirectoryURL
            )
            // Inside the library, only an existing LRCX file is rewritten in
            // place. A plain `.lrc` there is re-searched on every load, so
            // overwriting it would keep the track searching forever, because
            // the `.lrcx` that ends that loop never gets produced — write that
            // file beside it instead. Outside the library the opt-in means
            // "update the file the user pointed us at", so its own extension
            // is kept.
            let writesBackInPlace = isManaged
                ? localURL.pathExtension.lowercased() == Self.lyricsFileExtension
                : allowUnmanagedLocalWriteBack
            if writesBackInPlace {
                let securityScopedDirectoryURL: URL?
                if let customDirectoryURL, contains(localURL, in: customDirectoryURL) {
                    securityScopedDirectoryURL = customDirectoryURL
                } else {
                    securityScopedDirectoryURL = nil
                }
                return LyricsStorageDestination(
                    fileURL: localURL,
                    securityScopedDirectoryURL: securityScopedDirectoryURL
                )
            }
        }
        return libraryDestination
    }

    /// Whether persisting lyrics that were loaded from `localURL` writes back
    /// to that very file, instead of producing a copy elsewhere.
    ///
    /// The edit entry point asks before writing: it then hands the file to an
    /// external editor, and a write that landed elsewhere would leave the user
    /// editing a copy that the lookup order never reaches.
    public static func rewritesFileInPlace(
        localURL: URL,
        allowUnmanagedLocalWriteBack: Bool,
        defaultDirectoryURL: URL,
        customDirectoryURL: URL?
    ) -> Bool {
        persistDestination(
            localURL: localURL,
            allowUnmanagedLocalWriteBack: allowUnmanagedLocalWriteBack,
            defaultDirectoryURL: defaultDirectoryURL,
            customDirectoryURL: customDirectoryURL,
            libraryDestination: nil
        )?.fileURL == localURL
    }

    public static func destination(
        locationRawValue: Int,
        title: String?,
        artist: String?,
        defaultDirectoryURL: URL,
        customDirectoryURL: URL?
    ) -> LyricsStorageDestination? {
        let location = LyricsSavingLocation(popUpIndex: locationRawValue)

        let directoryURL: URL
        let securityScopedDirectoryURL: URL?
        if location == .customDirectory, let customDirectoryURL {
            directoryURL = customDirectoryURL
            securityScopedDirectoryURL = customDirectoryURL
        } else {
            directoryURL = defaultDirectoryURL
            securityScopedDirectoryURL = nil
        }

        guard let baseName = libraryFileBaseName(title: title, artist: artist) else {
            return nil
        }
        return LyricsStorageDestination(
            fileURL: directoryURL
                .appendingPathComponent(baseName)
                .appendingPathExtension(lyricsFileExtension),
            securityScopedDirectoryURL: securityScopedDirectoryURL
        )
    }

    public static func libraryFileBaseName(title: String?, artist: String?) -> String? {
        guard let title = sanitizedPathComponent(title),
              let artist = sanitizedPathComponent(artist) else {
            return nil
        }
        return "\(title) - \(artist)"
    }

    public static func libraryFileBaseNameCandidates(title: String?, artist: String?) -> [String] {
        var candidates: [String] = []
        if let canonicalName = libraryFileBaseName(title: title, artist: artist) {
            candidates.append(canonicalName)
        }

        // Releases before the shared storage policy did not trim metadata before
        // constructing a file name. Keep that spelling as a read-only fallback so
        // existing libraries remain discoverable after the canonicalization fix.
        if let title, let artist {
            let legacyTitle = title.replacingOccurrences(of: "/", with: ":")
            let legacyArtist = artist.replacingOccurrences(of: "/", with: ":")
            let legacyName = "\(legacyTitle) - \(legacyArtist)"
            if !candidates.contains(legacyName) {
                candidates.append(legacyName)
            }
        }
        return candidates
    }

    /// Creates the file an editor is about to be pointed at, and returns it.
    ///
    /// `initialContents` is written only when the file is created here. An
    /// existing file is returned untouched — it holds lyrics the user already
    /// has, and seeding over them would be data loss.
    public static func prepareEmptyFile(
        at destination: LyricsStorageDestination,
        initialContents: String = "",
        fileManager: FileManager = .default
    ) throws -> URL {
        let securityURL = destination.securityScopedDirectoryURL
        if let securityURL,
           !securityURL.startAccessingSecurityScopedResource() {
            throw CocoaError(.fileWriteNoPermission)
        }
        defer {
            securityURL?.stopAccessingSecurityScopedResource()
        }

        let fileURL = destination.fileURL
        let directoryURL = fileURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
        } else {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }

        isDirectory = false
        if fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) {
            guard !isDirectory.boolValue else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            return fileURL
        }

        try Data(initialContents.utf8).write(to: fileURL, options: .atomic)
        return fileURL
    }

    private static func sanitizedPathComponent(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let sanitized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: ":")
        return sanitized.isEmpty ? nil : sanitized
    }
}
