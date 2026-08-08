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
            if isManaged || allowUnmanagedLocalWriteBack {
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

    public static func prepareEmptyFile(
        at destination: LyricsStorageDestination,
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

        try Data().write(to: fileURL, options: .atomic)
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
