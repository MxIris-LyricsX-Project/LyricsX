import AppKit
import LyricsXFoundation
import MusicPlayer
import Regex

extension MusicPlayerName {
    init?(index: Int) {
        switch index {
        case 0: self = .appleMusic
        case 1: self = .spotify
        case 2: self = .vox
        case 3: self = .audirvana
        case 4: self = .swinsian
        default: return nil
        }
    }

    var icon: NSImage {
        switch self {
        case .appleMusic: return #imageLiteral(resourceName: "iTunes_icon")
        case .spotify: return #imageLiteral(resourceName: "spotify_icon")
        case .vox: return #imageLiteral(resourceName: "vox_icon")
        case .audirvana: return #imageLiteral(resourceName: "audirvana_icon")
        case .swinsian: return #imageLiteral(resourceName: "swinsian_icon")
        }
    }
}

extension MusicTrack {
    var lyrics: String? {
        guard let originalTrack = originalTrack,
              originalTrack.responds(to: Selector(("lyrics"))) else {
            return nil
        }
        return originalTrack.value(forKey: "lyrics") as? String
    }

    func setLyrics(_ lyrics: String) {
        guard let originalTrack = originalTrack,
              originalTrack.responds(to: Selector(("setLyrics:"))) else {
            return
        }
        originalTrack.setValue(lyrics, forKey: "lyrics")
    }

    var localFileURL: URL? {
        if let url = fileURL {
            return url
        }
        guard let originalTrack = originalTrack,
              originalTrack.responds(to: Selector(("location"))) else {
            return nil
        }
        return originalTrack.value(forKey: "location") as? URL
    }
}

extension NSFont {
    convenience init?(name fontName: String, size fontSize: CGFloat, fallback fallbackNames: [String]) {
        let cascadeList = fallbackNames.compactMap {
            NSFontDescriptor(name: $0, size: fontSize)
                .matchingFontDescriptor(withMandatoryKeys: [.name, .size])
        }
        let descriptor = NSFontDescriptor(fontAttributes: [.name: fontName, .cascadeList: cascadeList])
        self.init(descriptor: descriptor, size: fontSize)
    }
}

extension UserDefaults {
    var desktopLyricsFont: NSFont {
        return NSFont(
            name: self[.desktopLyricsFontName],
            size: CGFloat(self[.desktopLyricsFontSize]),
            fallback: self[.desktopLyricsFontNameFallback]
        )
            ?? NSFont.systemFont(ofSize: CGFloat(self[.desktopLyricsFontSize]))
    }

    var lyricsWindowFont: NSFont {
        return NSFont(
            name: defaults[.lyricsWindowFontName],
            size: CGFloat(defaults[.lyricsWindowFontSize])
        )
            ?? NSFont.labelFont(ofSize: CGFloat(defaults[.desktopLyricsFontSize]))
    }
}

extension UserDefaults {
    var lyricsDefaultSavingDirectory: URL {
        let userPath = String(cString: getpwuid(getuid()).pointee.pw_dir)
        return URL(fileURLWithPath: userPath).appendingPathComponent("Music/LyricsX")
    }

    func lyricsSavingPath() -> (URL, security: Bool) {
        if self[.lyricsSavingPathPopUpIndex] != 0, let path = lyricsCustomSavingPath {
            return (path, true)
        } else {
            return (lyricsDefaultSavingDirectory, false)
        }
    }

    func lyricsSavingDestination(
        title: String?,
        artist: String?
    ) -> LyricsStorageDestination? {
        return LyricsStoragePolicy.destination(
            locationRawValue: self[.lyricsSavingPathPopUpIndex],
            title: title,
            artist: artist,
            defaultDirectoryURL: lyricsDefaultSavingDirectory,
            customDirectoryURL: lyricsCustomSavingPath
        )
    }

    func lyricsSecurityScopedDirectory(containing fileURL: URL) -> URL? {
        guard let directoryURL = lyricsCustomSavingPath,
              LyricsStoragePolicy.contains(fileURL, in: directoryURL) else {
            return nil
        }
        return directoryURL
    }

    var lyricsCustomSavingPath: URL? {
        get {
            guard let data = self[.lyricsCustomSavingPathBookmark] else {
                return nil
            }
            var bookmarkDataIsStale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: [.withSecurityScope],
                    bookmarkDataIsStale: &bookmarkDataIsStale
                )
                guard bookmarkDataIsStale == false else {
                    return nil
                }
                return url
            } catch {
                log(error.localizedDescription)
                return nil
            }
        }
        set {
            self[.lyricsCustomSavingPathBookmark] = try? newValue?.bookmarkData(options: [.withSecurityScope])
        }
    }
}

extension Lyrics {
    func associateWithTrack(_ track: MusicTrack) {
        metadata.title = track.title
        metadata.artist = track.artist
    }

    var fileName: String? {
        guard let baseName = LyricsStoragePolicy.libraryFileBaseName(
            title: metadata.title,
            artist: metadata.artist
        ) else {
            return nil
        }
        return "\(baseName).lrcx"
    }

    @discardableResult
    func persist() -> Bool {
        guard let destination = LyricsStoragePolicy.persistDestination(
            localURL: metadata.localURL,
            allowUnmanagedLocalWriteBack: defaults[.writeBackToLyricsBesideTrack],
            defaultDirectoryURL: defaults.lyricsDefaultSavingDirectory,
            customDirectoryURL: defaults.lyricsCustomSavingPath,
            libraryDestination: defaults.lyricsSavingDestination(
                title: metadata.title,
                artist: metadata.artist
            )
        ) else {
            return false
        }

        let securityURL = destination.securityScopedDirectoryURL
        if let securityURL {
            guard securityURL.startAccessingSecurityScopedResource() else {
                return false
            }
        }
        defer {
            if let securityURL {
                securityURL.stopAccessingSecurityScopedResource()
            }
        }

        let fileURL = destination.fileURL
        let directoryURL = fileURL.deletingLastPathComponent()
        let fileManager = FileManager.default

        do {
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDir) {
                guard isDir.boolValue else {
                    return false
                }
            } else {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
            }

            try Data(description.utf8).write(to: fileURL, options: .atomic)
            metadata.localURL = fileURL
            metadata.needsPersist = false
            return true
        } catch {
            log(error.localizedDescription)
            return false
        }
    }
}

extension NSPredicate {
    fileprivate static var lyricsPredicate: NSPredicate {
        _ = NSPredicate.observer
        return _lyricsPredicate
    }

    private static var _lyricsPredicate: NSPredicate!

    private static let observer = defaults.observe(.lyricsFilterKeys, options: [.new, .initial]) { _, change in
        let predicates = change.newValue.compactMap { (key: String) -> NSPredicate? in
            let isRegex = key.hasPrefix("/")
            let pattern = isRegex ? String(key.dropFirst()) : key
            let options: NSRegularExpression.Options = isRegex ? [] : [.ignoreMetacharacters]
            guard let regex = try? Regex(pattern, options: options) else { return nil }
            return NSPredicate { object, _ in
                guard let object = object as? LyricsLine else { return false }
                return !regex.isMatch(object.content)
            }
        }
        _lyricsPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
    }
}

extension Lyrics {
    func filtrate() {
        filtrate(isIncluded: NSPredicate.lyricsPredicate)
    }
}

extension Lyrics {
    var adjustedOffset: Int {
        return offset + defaults[.globalLyricsOffset]
    }

    var adjustedTimeDelay: TimeInterval {
        return TimeInterval(adjustedOffset) / 1000
    }
}

extension NSImage {
    func scaled(to size: NSSize) -> NSImage {
        return NSImage(size: size, flipped: false) { rect in
            let srcRect = NSRect(origin: .zero, size: self.size)
            self.draw(in: rect, from: srcRect, operation: .copy, fraction: 1)
            return true
        }
    }
}
