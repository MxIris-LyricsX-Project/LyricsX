import Foundation

extension AppleMusicLyrics {
    /// The master switch for everything the panel logs and signposts, split
    /// into groups so one part of the panel can be watched without the others
    /// flooding the stream.
    ///
    /// Every `@Loggable` / `@Signpostable` type in this module passes one of
    /// the group flags below as its `isEnabled:` argument. Nothing is on by
    /// default; the groups are read once, at first use, from either of:
    ///
    /// - the environment variable `LYRICSX_PANEL_DIAGNOSTICS` (handy on an
    ///   Xcode scheme), or
    /// - the user-defaults key `AppleMusicLyricsDiagnosticsEnabled`
    ///   (`defaults write dev.JH.LyricsX AppleMusicLyricsDiagnosticsEnabled -string lyrics,karaoke`
    ///   for a running Debug build, `com.JH.LyricsX` for Release).
    ///
    /// The value is either a switch for everything (`1`, `true`, `yes`, `on`,
    /// `all`, or a boolean default) or a comma-separated list of group names:
    ///
    /// - `lyrics`: the display-link cadence, line layout, line changes and the
    ///   cascade. Subsystem `com.JH.LyricsX.AppleMusicLyricsPanel.Lyrics`.
    /// - `karaoke`: the in-line motion — every line's word table, every word's
    ///   emphasis decision, every syllable lift, every glyph return, resyncs
    ///   and resets. Same subsystem, category `InlineKaraoke`; one line per
    ///   event, so it is verbose by design.
    /// - `backdrop`: the artwork backdrop renderer and its frame timings.
    ///   Subsystem `com.JH.LyricsX.AppleMusicLyricsPanel.Backdrop`.
    ///
    /// The per-frame stage signposts have a second, finer switch of their own,
    /// `LYRICSX_DETAILED_FRAME_SIGNPOSTS`; it only has an effect while the
    /// `lyrics` group is on.
    enum PanelDiagnostics {
        struct Groups: OptionSet, Equatable, Sendable {
            let rawValue: Int

            static let lyrics = Groups(rawValue: 1 << 0)
            static let karaoke = Groups(rawValue: 1 << 1)
            static let backdrop = Groups(rawValue: 1 << 2)
            static let all: Groups = [.lyrics, .karaoke, .backdrop]

            /// The spelling each group answers to in the switch value.
            static let namedGroups: [(name: String, group: Groups)] = [
                ("lyrics", .lyrics),
                ("karaoke", .karaoke),
                ("backdrop", .backdrop),
            ]
        }

        static let environmentKey = "LYRICSX_PANEL_DIAGNOSTICS"
        static let userDefaultsKey = "AppleMusicLyricsDiagnosticsEnabled"

        static let enabledGroups: Groups = resolveEnabledGroups()
        /// Whether any group at all is on.
        static let isEnabled: Bool = !enabledGroups.isEmpty
        static let isLyricsEnabled: Bool = enabledGroups.contains(.lyrics)
        static let isKaraokeEnabled: Bool = enabledGroups.contains(.karaoke)
        static let isBackdropEnabled: Bool = enabledGroups.contains(.backdrop)

        static func resolveIsEnabled(
            environment: [String: String] = ProcessInfo.processInfo.environment,
            userDefaults: UserDefaults = .standard
        ) -> Bool {
            !resolveEnabledGroups(environment: environment, userDefaults: userDefaults).isEmpty
        }

        /// The environment wins when it is set at all; otherwise the defaults
        /// key, which may still be the boolean the switch started out as.
        static func resolveEnabledGroups(
            environment: [String: String] = ProcessInfo.processInfo.environment,
            userDefaults: UserDefaults = .standard
        ) -> Groups {
            if let environmentValue = environment[environmentKey],
               !environmentValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return parseGroups(environmentValue)
            }
            switch userDefaults.object(forKey: userDefaultsKey) {
            case let storedString as String:
                return parseGroups(storedString)
            case let storedNumber as NSNumber:
                return storedNumber.boolValue ? .all : []
            default:
                return []
            }
        }

        /// `1` / `true` / `yes` / `on` / `all` switch everything on, `0` / `false`
        /// / `no` / `off` everything off; anything else is read as a list of
        /// group names separated by commas or whitespace, unknown names ignored.
        static func parseGroups(_ value: String) -> Groups {
            let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch normalizedValue {
            case "1",
                 "true",
                 "yes",
                 "on",
                 "all":
                return .all
            case "",
                 "0",
                 "false",
                 "no",
                 "off",
                 "none":
                return []
            default:
                break
            }
            let separators = CharacterSet(charactersIn: ",;").union(.whitespacesAndNewlines)
            var groups: Groups = []
            for token in normalizedValue.components(separatedBy: separators) where !token.isEmpty {
                if let match = Groups.namedGroups.first(where: { $0.name == token }) {
                    groups.insert(match.group)
                }
            }
            return groups
        }
    }
}
