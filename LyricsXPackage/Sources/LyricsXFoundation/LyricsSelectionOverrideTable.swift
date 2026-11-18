import Foundation

/// Remembers, per track, which local lyrics the user picked by hand: a file,
/// or the lyrics embedded in the track.
///
/// Automatic lookup has a fixed order: lyrics embedded in the audio file, then
/// lyrics sitting beside it — both only with "load lyrics beside the track"
/// on — then the saving directory. A candidate the user switched to gets
/// written into the saving directory — last in that order — so on the next
/// play an embedded or beside-track file would win and silently undo the
/// choice; and a pick of the embedded lyrics is never reached at all while
/// that switch is off. An entry here moves one source to the front of the
/// lookup order, for one track only, without touching any file the user owns.
///
/// Entries encode as `"<unix timestamp>\t<file path>"`, with `<embedded>` in
/// place of the path for the embedded lyrics. The timestamp is what makes the
/// table trimmable oldest-first; a bare path would leave no way to choose
/// which entry to drop once the table hits its ceiling.
public enum LyricsSelectionOverrideTable {
    /// Trimming kicks in above this many entries…
    public static let entryLimit = 300

    /// …and takes the table down to this many, so trimming is occasional
    /// rather than once per switch.
    public static let trimmedEntryCount = 200

    private static let fieldSeparator: Character = "\t"

    /// Stands in for a path when the pick is the lyrics embedded in the track.
    /// Every recorded path is absolute, so it can never be mistaken for one.
    private static let embeddedLyricsEntry = "<embedded>"

    /// The pick recorded for `trackId`, if any.
    public static func selection(forTrackId trackId: String, in table: [String: String]) -> LocalLyricsSource? {
        guard let entry = table[trackId] else {
            return nil
        }
        let value = decodeFilePath(from: entry)
        if value == embeddedLyricsEntry {
            return .embedded
        }
        return value.isEmpty ? nil : .file(URL(fileURLWithPath: value))
    }

    /// The path recorded for `trackId`; `nil` when the pick is the embedded
    /// lyrics rather than a file.
    public static func filePath(forTrackId trackId: String, in table: [String: String]) -> String? {
        guard case .file(let fileURL) = selection(forTrackId: trackId, in: table) else {
            return nil
        }
        return fileURL.path
    }

    /// The table after the user picked `pick` by hand for `trackId` — from
    /// the next-candidate shortcut, the search panel, an import or the Local
    /// Lyrics menu. Every hand pick has to come through here: an entry left
    /// over from an earlier pick outranks the whole lookup, so a later pick
    /// that skipped this would last exactly one play.
    ///
    /// `automaticLookupResult` is what the automatic lookup would settle on
    /// for the track without this table: the first local source it shows
    /// and does not search past, or `nil` when it would search. When that is
    /// the pick, the entry goes — the lookup arrives there on its own, so
    /// most users' tables stay empty. Anything else records the pick.
    public static func remembering(
        _ pick: LocalLyricsSource,
        forTrackId trackId: String,
        automaticLookupResult: LocalLyricsSource?,
        in table: [String: String],
        at date: Date
    ) -> [String: String] {
        if let automaticLookupResult, automaticLookupResult.isSameSource(as: pick) {
            return removing(trackId: trackId, from: table)
        }
        return recording(pick, forTrackId: trackId, in: table, at: date)
    }

    public static func recording(
        _ selection: LocalLyricsSource,
        forTrackId trackId: String,
        in table: [String: String],
        at date: Date
    ) -> [String: String] {
        switch selection {
        case .embedded:
            return recording(entryValue: embeddedLyricsEntry, forTrackId: trackId, in: table, at: date)
        case .file(let fileURL):
            return recording(entryValue: fileURL.path, forTrackId: trackId, in: table, at: date)
        }
    }

    public static func recording(
        filePath: String,
        forTrackId trackId: String,
        in table: [String: String],
        at date: Date
    ) -> [String: String] {
        recording(entryValue: filePath, forTrackId: trackId, in: table, at: date)
    }

    private static func recording(
        entryValue: String,
        forTrackId trackId: String,
        in table: [String: String],
        at date: Date
    ) -> [String: String] {
        var updatedTable = table
        updatedTable[trackId] = "\(date.timeIntervalSince1970)\(fieldSeparator)\(entryValue)"
        guard updatedTable.count > entryLimit else {
            return updatedTable
        }
        // Sort by recency, breaking ties on the track id so trimming is
        // deterministic rather than dependent on dictionary ordering.
        let survivingTrackIds = Set(
            updatedTable
                .sorted { leftEntry, rightEntry in
                    let leftTimestamp = decodeTimestamp(from: leftEntry.value)
                    let rightTimestamp = decodeTimestamp(from: rightEntry.value)
                    if leftTimestamp == rightTimestamp {
                        return leftEntry.key < rightEntry.key
                    }
                    return leftTimestamp > rightTimestamp
                }
                .prefix(trimmedEntryCount)
                .map(\.key)
        )
        return updatedTable.filter { survivingTrackIds.contains($0.key) }
    }

    public static func removing(trackId: String, from table: [String: String]) -> [String: String] {
        var updatedTable = table
        updatedTable.removeValue(forKey: trackId)
        return updatedTable
    }

    private static func decodeTimestamp(from entry: String) -> TimeInterval {
        guard let separatorIndex = entry.firstIndex(of: fieldSeparator) else {
            return 0
        }
        return TimeInterval(entry[entry.startIndex ..< separatorIndex]) ?? 0
    }

    private static func decodeFilePath(from entry: String) -> String {
        guard let separatorIndex = entry.firstIndex(of: fieldSeparator) else {
            // An entry written before the timestamp existed, or a hand-edited
            // preference: treat the whole value as the path rather than
            // dropping a selection the user made.
            return entry
        }
        return String(entry[entry.index(after: separatorIndex)...])
    }
}
