import AppKit
import Combine
import GenericID
import LyricsXFoundation
import MusicPlayer

let fontNameFallbackCountMax = 1
// 7 days. after this period of time since the app built, the app is not considered as "in review".
let masReviewPeriodLimit: TimeInterval = 60 * 60 * 24 * 7

// NOTE: to build your own product, you need to replace the team identifier to yours
// and do the same thing in LyricsXHelper
#if DEBUG
let lyricsXGroupIdentifier = "D5Q73692VW.group.dev.JH.LyricsX"
let lyricsXSharedSuiteName = "dev.JH.LyricsX.shared"
let lyricsXHelperIdentifier = "dev.JH.LyricsXHelper"
let lyricsXErrorDomain = "dev.JH.LyricsX"
#else
let lyricsXGroupIdentifier = "D5Q73692VW.group.com.JH.LyricsX"
let lyricsXSharedSuiteName = "com.JH.LyricsX.shared"
let lyricsXHelperIdentifier = "com.JH.LyricsXHelper"
let lyricsXErrorDomain = "com.JH.LyricsX"
#endif

let crowdinProjectURL = URL(string: "https://crowdin.com/project/lyricsx")!

let defaults = UserDefaults.standard
// Two distinct shared channels, deliberately kept separate:
//
// 1. `sharedDefaults` — shared between the app and the (non-sandboxed)
//    LyricsXHelper via a plain preferences suite at
//    ~/Library/Preferences/<suite>.plist. Deliberately NOT an App Group
//    container: a non-sandboxed process can't read App Group preferences
//    through cfprefsd ("kCFPreferencesAnyUser ... only allowed for System
//    Containers"); a plain suite works for both processes.
//
// 2. `lyricsXGroupIdentifier` — the App Group container shared with the
//    sandboxed LyricsXWidget extension (via WidgetDataStore). A sandboxed
//    extension can only share with the host app through an App Group, so the
//    widget channel must stay on the App Group even though the helper can't.
let groupDefaults = UserDefaults(suiteName: lyricsXGroupIdentifier)!
let sharedDefaults = UserDefaults(suiteName: lyricsXSharedSuiteName)!
let defaultNC = NotificationCenter.default
let workspaceNC = NSWorkspace.shared.notificationCenter
let selectedPlayer = MusicPlayers.Selected.shared

let isInSandbox = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
let isFromMacAppStore = (try? Bundle.main.appStoreReceiptURL?.checkResourceIsReachable()) == true

extension DispatchQueue {
    static let lyricsDisplay = DispatchQueue(label: "LyricsDisplay")
}

extension CAMediaTimingFunction {
    static let mystery = CAMediaTimingFunction(controlPoints: 0.2, 0.1, 0.2, 1)
    static let swiftOut = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.2, 1)
}

func log(_ message: @autoclosure () -> String, file: String = #file, line: UInt = #line) {
    let fileName = (file as NSString).lastPathComponent
    // Adding prefix to distinguish from ton of AppleEvent error log.
    NSLog("CustomLog:\(fileName):\(line): \(message())")
}

// MARK: - Identifier

extension NSUserInterfaceItemIdentifier {
//    static let WriteToiTunes = NSUserInterfaceItemIdentifier("MainMenu.WriteToiTunes")
//    static let SearchLyrics = NSUserInterfaceItemIdentifier("MainMenu.SearchLyrics")
//    static let LyricsMenu = NSUserInterfaceItemIdentifier("MainMenu.Lyrics")

    static let searchResultColumnTitle = NSUserInterfaceItemIdentifier("SearchResult.TableColumn.Title")
    static let searchResultColumnArtist = NSUserInterfaceItemIdentifier("SearchResult.TableColumn.Artist")
    static let searchResultColumnSource = NSUserInterfaceItemIdentifier("SearchResult.TableColumn.Source")
    static let searchResultColumnQuality = NSUserInterfaceItemIdentifier("SearchResult.TableColumn.Quality")
}

extension NSStoryboard.SceneIdentifier {
    static let desktopLyricsWindow = NSStoryboard.SceneIdentifier("DesktopLyricsWindow")
    static let lyricsHUDAccessory = NSStoryboard.SceneIdentifier("LyricsHUDAccessory")
}

// MARK: - User Defaults

extension UserDefaults.DefaultsKeys {
    static let notifiedUpdateVersion = Key<String?>("NotifiedUpdateVersion")
    // Opt-in to Sparkle's "beta" channel. When true, the updater accepts
    // appcast items tagged <sparkle:channel>beta</sparkle:channel> in addition
    // to untagged (stable) items. When false, only untagged items are eligible.
    static let receiveBetaUpdates = Key<Bool>("ReceiveBetaUpdates")
    static let noSearchingTrackIds = Key<[String]>("NoSearchingTrackIds")
    static let noSearchingAlbumNames = Key<[String]>("NoSearchingAlbumNames")

    // Menu
    static let desktopLyricsEnabled = Key<Bool>("DesktopLyricsEnabled")
    static let menuBarLyricsEnabled = Key<Bool>("MenuBarLyricsEnabled")
    static let touchBarLyricsEnabled = Key<Bool>("TouchBarLyricsEnabled")
    static let menuBarPlaybackControlsEnabled = Key<Bool>("MenuBarPlaybackControlsEnabled")

    // General
    static let preferredPlayerIndex = Key<Int>("PreferredPlayerIndex")
    static let launchAndQuitWithPlayer = Key<Bool>("LaunchAndQuitWithPlayer")

    static let lyricsSavingPathPopUpIndex = Key<Int>("LyricsSavingPathPopUpIndex")
    static let lyricsCustomSavingPathBookmark = Key<Data?>("LyricsCustomSavingPathBookmark")
    static let loadLyricsBesideTrack = Key<Bool>("LoadLyricsBesideTrack")
    static let writeBackToLyricsBesideTrack = Key<Bool>("WriteBackToLyricsBesideTrack")
    /// Skip the lyrics LyricsX saved for itself and search afresh every time.
    /// Only that library is skipped — embedded lyrics, files sitting beside the
    /// track and hand-picked selections are the user's, not a cache.
    static let ignoreCachedLyricsLibrary = Key<Bool>("IgnoreCachedLyricsLibrary")
    /// Track id -> the lyrics file the user picked by hand, encoded by
    /// `LyricsSelectionOverrideTable`. Consulted before every automatic lookup
    /// so a manual pick is not undone by an embedded or beside-track file.
    static let lyricsSelectionOverrides = Key<[String: String]>("LyricsSelectionOverrides")

    static let selectedLanguage = Key<String?>("SelectedLanguage")

    static let strictSearchEnabled = Key<Bool>("StrictSearchEnabled")
    static let stripSearchTitleBracketsEnabled = Key<Bool>("StripSearchTitleBracketsEnabled")
    static let preferBilingualLyrics = Key<Bool>("PreferBilingualLyrics")
    static let chineseConversionIndex = Key<Int>("ChineseConversionIndex")

    static let combinedMenubarLyrics = Key<Bool>("CombinedMenubarLyrics")

    static let hideLyricsWhenMousePassingBy = Key<Bool>("HideLyricsWhenMousePassingBy")
    static let disableLyricsWhenPaused = Key<Bool>("DisableLyricsWhenPaused")
    static let disableLyricsWhenSreenShot = Key<Bool>("DisableLyricsWhenSreenShot")

    static let hideMenuBarItems = Key<Bool>("HideMenuBarItems")

    // Display
    static let desktopLyricsOneLineMode = Key<Bool>("DesktopLyricsOneLineMode")
    static let desktopLyricsVerticalMode = Key<Bool>("DesktopLyricsVerticalMode")
    static let desktopLyricsDraggable = Key<Bool>("DesktopLyricsDraggable")

    static let desktopLyricsXPositionFactor = Key<CGFloat>("DesktopLyricsXPositionFactor")
    static let desktopLyricsYPositionFactor = Key<CGFloat>("DesktopLyricsYPositionFactor")

    static let desktopLyricsEnableFurigana = Key<Bool>("DesktopLyricsEnableFurigana")
    static let desktopLyricsUseSourceKana = Key<Bool>("DesktopLyricsUseSourceKana")
    static let desktopLyricsEnableRomajin = Key<Bool>("DesktopLyricsEnableRomajin")

    static let desktopLyricsFontName = Key<String>("DesktopLyricsFontName")
    static let desktopLyricsFontSize = Key<Int>("DesktopLyricsFontSize")
    static let desktopLyricsFontNameFallback = Key<[String]>("DesktopLyricsFontNameFallback")

    static let desktopLyricsColor = Key<NSColor>("DesktopLyricsColor", transformer: .keyedArchive)
    static let desktopLyricsProgressColor = Key<NSColor>("DesktopLyricsProgressColor", transformer: .keyedArchive)
    static let desktopLyricsShadowColor = Key<NSColor>("DesktopLyricsShadowColor", transformer: .keyedArchive)
    static let desktopLyricsBackgroundColor = Key<NSColor>("DesktopLyricsBackgroundColor", transformer: .keyedArchive)

    static let lyricsWindowFontName = Key<String>("LyricsWindowFontName")
    static let lyricsWindowFontSize = Key<Int>("LyricsWindowFontSize")
    static let lyricsWindowFontNameFallback = Key<[String]>("LyricsWindowFontNameFallback")

    static let lyricsWindowTextColor = Key<NSColor>("LyricsWindowTextColor", transformer: .keyedArchive)
    static let lyricsWindowHighlightColor = Key<NSColor>("LyricsWindowHighlightColor", transformer: .keyedArchive)

    // Shortcut
    static let shortcutToggleMenuBarLyrics = Key<String>("ShortcutToggleMenuBarLyrics")
    static let shortcutToggleKaraokeLyrics = Key<String>("ShortcutToggleKaraokeLyrics")
    static let shortcutShowLyricsWindow = Key<String>("ShortcutShowLyricsWindow")
    static let shortcutOffsetIncrease = Key<String>("ShortcutOffsetIncrease")
    static let shortcutOffsetDecrease = Key<String>("ShortcutOffsetDecrease")
    static let shortcutWriteToiTunes = Key<String>("ShortcutWriteToiTunes")
    static let shortcutSearchLyrics = Key<String>("ShortcutSearchLyrics")
    static let shortcutWrongLyrics = Key<String>("ShortcutWrongLyrics")
    static let shortcutNextLyricsCandidate = Key<String>("ShortcutNextLyricsCandidate")
    static let shortcutTogglePreferences = Key<String>("ShortcutTogglePreferences")

    // Filter
    static let lyricsFilterEnabled = Key<Bool>("LyricsFilterEnabled")
    static let lyricsSmartFilterEnabled = Key<Bool>("LyricsSmartFilterEnabled")
    static let lyricsFilterKeys = Key<[String]>("LyricsFilterKeys")

    // Lab
    static let useSystemWideNowPlaying = Key<Bool>("UseSystemWideNowPlaying")
    static let systemWideNowPlayingAppList = Key<[String]>("SystemWideNowPlayingAppList")

    static let writeiTunesWithTranslation = Key<Bool>("WriteiTunesWithTranslation")
    static let writeToiTunesAutomatically = Key<Bool>("WriteToiTunesAutomatically")
    static let writeiTunesConvertToPlainLRC = Key<Bool>("WriteiTunesConvertToPlainLRC")

    static let globalLyricsOffset = Key<Int>("GlobalLyricsOffset")

    static let musixmatchToken = Key<String?>("MusixmatchToken")

    //
    static let isInMASReview = Key<Bool?>("isInMASReview")

    static let launchHelperTime = Key<Date?>("launchHelperTime")

    static let appleLanguages = Key<[String]>("AppleLanguages")

    static let isShowLyricsHUD = Key<Bool>("isShowLyricsHUD")

    static let useAppleMusicLyricsWindow = Key<Bool>("UseAppleMusicLyricsWindow")
    static let appleMusicLyricsBackgroundMode = Key<Int>("AppleMusicLyricsBackgroundMode")
    static let appleMusicLyricsWindowPinned = Key<Bool>("AppleMusicLyricsWindowPinned")

    // Source Priority
    /// Superseded by `lyricsSourceOrderingMode`, which `UserDefaultsMigrator`
    /// seeds from it once. Kept readable so downgrading to an older build still
    /// finds the user's setting.
    static let lyricsSourcePriorityEnabled = Key<Bool>("LyricsSourcePriorityEnabled")
    /// A `LyricsSourceOrderingMode` raw value.
    static let lyricsSourceOrderingMode = Key<Int>("LyricsSourceOrderingMode")
    static let lyricsSourcePriorityOrder = Key<[String]>("LyricsSourcePriorityOrder")
    static let lyricsPriorityWindow = Key<Double>("LyricsPriorityWindow")

    // Artwork-similarity reranking: when on, candidates whose cover art looks
    // like the currently playing track's artwork get a quality bonus, so the
    // right version surfaces above same-title peers from other artists.
    static let artworkSimilarityBoostEnabled = Key<Bool>("ArtworkSimilarityBoostEnabled")

    // The Apple Music-style panel stretches the cover to roughly 1400 pixels in
    // full screen, well past the thumbnail a player publishes. When on, a
    // higher-resolution copy of the same cover is looked up on the network and
    // swapped in — see `HighResolutionArtworkService`.
    static let highResolutionPanelArtworkEnabled = Key<Bool>("HighResolutionPanelArtworkEnabled")

    // Apple Music Route B — recover a track's native-script name via the
    // Apple Music catalog so the third-party providers can match it.
    static let appleMusicNameRecoveryEnabled = Key<Bool>("AppleMusicNameRecoveryEnabled")

    // Apple Music Route A — official syllable-lyrics, fetched via the
    // amp-api `music.api.music()` from a `WKWebView` signed in with the
    // user's `media-user-token`. The token is pasted by the user (it
    // cannot be obtained programmatically without MusicKit Capability +
    // user consent, which Route A's endpoint does not honor).
    //
    // When empty, the Apple Music provider is not registered.
    static let appleMusicMediaUserToken = Key<String?>("AppleMusicMediaUserToken")

    // Storefront override (2-letter country code, e.g. "cn", "us", "jp").
    // When empty, auto-detected via `/v1/me/storefront`.
    static let appleMusicStorefront = Key<String?>("AppleMusicStorefront")

    // Language override for TTML translations (e.g. "zh-Hans", "ja-JP").
    // When empty, uses `Locale.preferredLanguages[0]`.
    static let appleMusicLanguage = Key<String?>("AppleMusicLanguage")
}

// MARK: - Lyrics Priority

private let artworkMatchBonusKey = Lyrics.Metadata.Key("LyricsX.ArtworkMatchBonus")
private let arrivedAfterPriorityWindowKey = Lyrics.Metadata.Key("LyricsX.ArrivedAfterPriorityWindow")

extension Lyrics {
    var artworkMatchBonus: Double {
        get { (metadata.data[artworkMatchBonusKey] as? Double) ?? 0 }
        set { metadata.data[artworkMatchBonusKey] = newValue }
    }

    /// Set on results that reached us after the priority window closed. They
    /// are perfectly good candidates — the user can switch onto them by hand —
    /// but they must never take the screen on their own, because by then the
    /// user has been reading the displayed lyrics for seconds.
    ///
    /// Carried on the lyrics rather than passed as an argument because the
    /// artwork-similarity score lands asynchronously, long after the arrival
    /// that would have supplied such an argument.
    var arrivedAfterPriorityWindow: Bool {
        get { (metadata.data[arrivedAfterPriorityWindowKey] as? Bool) ?? false }
        set { metadata.data[arrivedAfterPriorityWindowKey] = newValue }
    }
}

var lyricsSourceOrderingMode: LyricsSourceOrderingMode {
    LyricsSourceOrderingMode(storedRawValue: defaults[.lyricsSourceOrderingMode])
}

func lyricsHasHigherPriority(_ new: Lyrics, over existing: Lyrics) -> Bool {
    let mode = lyricsSourceOrderingMode
    // Resolving a source index means lowercasing the whole preference list, so
    // skip it in the one mode that never looks at it. Equal indices make every
    // source-based test fall through to quality, which is what that mode wants.
    let newSourceIndex: Int
    let existingSourceIndex: Int
    if mode.usesSourcePriorityOrder {
        let normalizedOrder = (defaults[.lyricsSourcePriorityOrder] ?? []).map { $0.lowercased() }
        newSourceIndex = sourcePriorityIndex(of: new, in: normalizedOrder)
        existingSourceIndex = sourcePriorityIndex(of: existing, in: normalizedOrder)
    } else {
        newSourceIndex = LyricsSourceOrderingPolicy.unlistedSourceIndex
        existingSourceIndex = LyricsSourceOrderingPolicy.unlistedSourceIndex
    }

    return LyricsSourceOrderingPolicy.hasHigherPriority(
        candidateQuality: effectiveQuality(new),
        candidateSourceIndex: newSourceIndex,
        comparedToQuality: effectiveQuality(existing),
        comparedToSourceIndex: existingSourceIndex,
        mode: mode
    )
}

private func sourcePriorityIndex(of lyrics: Lyrics, in normalizedOrder: [String]) -> Int {
    let source = (lyrics.metadata.service ?? "").lowercased()
    return normalizedOrder.firstIndex(of: source) ?? LyricsSourceOrderingPolicy.unlistedSourceIndex
}

// Internal rather than private because the search panel shows this number in
// its Score column, and it has to show the same one the ordering compares.
func effectiveQuality(_ lyrics: Lyrics) -> Double {
    // Normalise here rather than leaning on the policy's own guard: NaN would
    // poison the sum, and the policy would then discard the artwork bonus along
    // with it.
    let quality = lyrics.quality.isFinite ? lyrics.quality : 0
    return quality + effectiveArtworkBonus(lyrics)
}

func effectiveArtworkBonus(_ lyrics: Lyrics) -> Double {
    guard defaults[.artworkSimilarityBoostEnabled] else { return 0 }
    return lyrics.artworkMatchBonus
}

extension CGFloat: @retroactive DefaultConstructible {}
