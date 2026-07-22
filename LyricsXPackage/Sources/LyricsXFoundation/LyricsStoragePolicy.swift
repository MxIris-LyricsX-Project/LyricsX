import Foundation

public enum LyricsSavingLocation: Int, Sendable {
    case lyricsXDirectory = 0
    case customDirectory = 1
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

    public static func destination(
        locationRawValue: Int,
        title: String?,
        artist: String?,
        defaultDirectoryURL: URL,
        customDirectoryURL: URL?
    ) -> LyricsStorageDestination? {
        let location = LyricsSavingLocation(rawValue: locationRawValue) ?? .lyricsXDirectory

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
                .appendingPathExtension("lrcx"),
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
